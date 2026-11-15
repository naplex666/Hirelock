// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HireLock — trustless escrow for hiring (Arbitrum)
/// @notice Rebuild of the live HireLock contract deployed on Arbitrum Sepolia
///         at 0x3B6E7aD423ffc3118F031cBD4226deC870eB14Aa, reconstructed from its
///         on-chain bytecode (Heimdall disassembly + live chain reads).
///         See README.md for what is verified vs. what is assumed.
/// @dev Storage layout deliberately mirrors the live contract:
///      slot 0 = jobs mapping, slot 1 = jobCount,
///      slot 2 = pendingWithdrawals mapping, slot 3 = reentrancy guard (1 idle / 2 locked).
contract HireLock {
    // ---- Status values (live contract stores the status as one byte) ----
    uint8 internal constant STATUS_CREATED = 0;
    uint8 internal constant STATUS_STARTED = 1;
    uint8 internal constant STATUS_SUBMITTED = 2;
    uint8 internal constant STATUS_RELEASED = 3;
    uint8 internal constant STATUS_CANCELLED = 4;
    uint8 internal constant STATUS_DISPUTED = 5;

    /// @notice One escrowed job. Field order and packing reproduce the live
    ///         contract's 21-field `jobs`/`getJob` return exactly:
    ///         - slots 0..11 are one field each,
    ///         - slot 12 packs (disputer, 6 flag bytes, status) into a single word,
    ///         - slot 13 holds the title string.
    struct Job {
        address client; // slot+0
        address freelancer; // slot+1
        uint256 amount; // slot+2 (escrowed value, = msg.value at creation)
        address arbiter; // slot+3 (address(0) = no arbiter)
        uint256 deadline; // slot+4
        uint256 duration; // slot+5 (review window in seconds)
        uint256 createdAt; // slot+6
        uint256 startedAt; // slot+7
        uint256 submittedAt; // slot+8
        bool started; // slot+9
        bytes32 workHash; // slot+10
        uint256 reserved; // slot+11 (purpose unknown in live contract, always 0)
        address disputer; // slot+12, bits 0..159
        uint8 clientConfirmed; // slot+12, byte 20
        uint8 freelancerConfirmed; // slot+12, byte 21
        uint8 flag3; // slot+12, byte 22
        uint8 flag4; // slot+12, byte 23
        uint8 flag5; // slot+12, byte 24
        uint8 flag6; // slot+12, byte 25
        uint8 status; // slot+12, byte 26
        string title; // slot+13
    }

    mapping(uint256 => Job) public jobs; // slot 0
    uint256 public jobCount; // slot 1
    mapping(address => uint256) public pendingWithdrawals; // slot 2
    uint256 private _status; // slot 3 — reentrancy guard: 1 = idle, 2 = locked

    // ---- Events ----
    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed freelancer,
        uint256 deadline,
        string title
    );
    event JobStarted(uint256 indexed jobId, address indexed freelancer);
    event WorkSubmitted(uint256 indexed jobId, address indexed freelancer, bytes32 workHash);
    event PaymentReleased(uint256 indexed jobId, address indexed freelancer, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event DisputeRaised(uint256 indexed jobId, address indexed disputer, bytes32 reasonHash);
    event DisputeResolved(uint256 indexed jobId, address indexed arbiter, bool releasedToFreelancer);
    event JobCancelled(uint256 indexed jobId, address indexed client);
    event JobRefunded(uint256 indexed jobId, address indexed client);
    event WorkConfirmed(uint256 indexed jobId, address indexed confirmer);
    event AutoReleased(uint256 indexed jobId, address indexed freelancer, uint256 amount);

    // ---- Errors ----
    // The two below are confirmed live error selectors (verified by keccak):
    //   TooEarly()       -> 0x085de625
    //   ZeroAmount()     -> 0x1f2a2005
    error TooEarly();
    error ZeroAmount();
    error JobNotFound();
    error NotClient();
    error NotFreelancer();
    error NotArbiter();
    error NotParticipant();
    error InvalidStatus();
    error NotStarted();
    error AlreadyStarted();
    error AlreadyConfirmed();
    error TransferFailed();
    error ReentrancyGuard();

    constructor() {
        _status = 1; // idle, matches live contract
    }

    modifier nonReentrant() {
        if (_status != 1) revert ReentrancyGuard();
        _status = 2;
        _;
        _status = 1;
    }

    modifier jobExists(uint256 jobId) {
        if (jobId >= jobCount) revert JobNotFound();
        _;
    }

    /// @notice Create a job and fund its escrow. Payable.
    /// @dev Live selector 0x879397c4 = createJob(address,address,uint256,uint256,string).
    ///      arg0 = freelancer, arg1 = arbiter (address(0) = none),
    ///      arg2 = deadline (unix), arg3 = review duration in seconds, arg4 = title.
    function createJob(
        address freelancer,
        address arbiter,
        uint256 deadline,
        uint256 duration,
        string calldata title
    ) external payable returns (uint256 jobId) {
        if (freelancer == address(0)) revert NotFreelancer();
        if (msg.value == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert TooEarly();
        jobId = jobCount;
        jobCount += 1;
        Job storage job = jobs[jobId];
        job.client = msg.sender;
        job.freelancer = freelancer;
        job.amount = msg.value;
        job.arbiter = arbiter;
        job.deadline = deadline;
        job.duration = duration;
        job.createdAt = block.timestamp;
        job.status = STATUS_CREATED;
        job.title = title;
        emit JobCreated(jobId, msg.sender, freelancer, deadline, title);
    }

    /// @notice Freelancer accepts / starts the job.
    /// @dev Live selector 0xe1255294 = startJob(uint256).
    function startJob(uint256 jobId) external jobExists(jobId) {
        Job storage job = jobs[jobId];
        if (msg.sender != job.freelancer) revert NotFreelancer();
        if (job.status != STATUS_CREATED) revert InvalidStatus();
        if (job.started) revert AlreadyStarted();
        job.started = true;
        job.startedAt = block.timestamp;
        job.status = STATUS_STARTED;
        emit JobStarted(jobId, msg.sender);
    }

    /// @notice Freelancer submits the finished work as a content hash.
    /// @dev Live selector 0xa118c41a = (uint256,bytes32). The live function name
    ///      is NOT recoverable (not in 4byte.directory, ~1000 candidates tried);
    ///      `submitWork` is the semantic name — see SELECTOR_CHECK.md.
    function submitWork(uint256 jobId, bytes32 workHash) external jobExists(jobId) {
        Job storage job = jobs[jobId];
        if (msg.sender != job.freelancer) revert NotFreelancer();
        if (!job.started) revert NotStarted();
        if (job.status != STATUS_STARTED) revert InvalidStatus();
        job.workHash = workHash;
        job.submittedAt = block.timestamp;
        job.status = STATUS_SUBMITTED;
        emit WorkSubmitted(jobId, msg.sender, workHash);
    }

    /// @notice Client approves the submitted work; escrow moves to pull-payment.
    /// @dev Live selector 0xba6bc66e = confirmRelease(uint256).
    function confirmRelease(uint256 jobId) external nonReentrant jobExists(jobId) {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (job.status != STATUS_SUBMITTED) revert InvalidStatus();
        _release(jobId, job.freelancer);
    }

    /// @notice Client cancels before the freelancer started; escrow refunds to client.
    /// @dev Live selector 0x6fbc4e57 = cancelBeforeStart(uint256).
    function cancelBeforeStart(uint256 jobId) external nonReentrant jobExists(jobId) {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (job.status != STATUS_CREATED) revert InvalidStatus();
        if (job.started) revert AlreadyStarted();
        job.status = STATUS_CANCELLED;
        pendingWithdrawals[job.client] += job.amount;
        emit JobCancelled(jobId, msg.sender);
    }

    /// @notice Client reclaims the escrow after the deadline passed unfulfilled.
    /// @dev Live selector 0xcc9f3c51 = (uint256). The live function name is NOT
    ///      recoverable; `refundAfterDeadline` is the semantic name.
    ///      Live requires status == Created; this rebuild also allows Started
    ///      (a started-but-never-submitted job must still be refundable).
    function refundAfterDeadline(uint256 jobId) external nonReentrant jobExists(jobId) {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (job.status != STATUS_CREATED && job.status != STATUS_STARTED) revert InvalidStatus();
        if (block.timestamp < job.deadline) revert TooEarly();
        job.status = STATUS_CANCELLED;
        pendingWithdrawals[job.client] += job.amount;
        emit JobRefunded(jobId, msg.sender);
    }

    /// @notice Client or freelancer opens a dispute with a reason hash.
    /// @dev Live selector 0x636bf26d = raiseDispute(uint256,bytes32).
    ///      Live quirk: the original ORs 2 into the status byte instead of
    ///      setting a clean Disputed state; this rebuild sets STATUS_DISPUTED.
    function raiseDispute(uint256 jobId, bytes32 reasonHash) external jobExists(jobId) {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client && msg.sender != job.freelancer) revert NotParticipant();
        if (!job.started) revert NotStarted();
        if (job.status != STATUS_STARTED && job.status != STATUS_SUBMITTED) revert InvalidStatus();
        job.disputer = msg.sender;
        job.status = STATUS_DISPUTED;
        emit DisputeRaised(jobId, msg.sender, reasonHash);
    }

    /// @notice Arbiter settles a dispute: pay the freelancer or refund the client.
    /// @dev Live selector 0x34b25ee2 = resolveDispute(uint256,bool).
    function resolveDispute(uint256 jobId, bool releaseToFreelancer) external nonReentrant jobExists(jobId) {
        Job storage job = jobs[jobId];
        if (job.arbiter == address(0) || msg.sender != job.arbiter) revert NotArbiter();
        if (job.status != STATUS_DISPUTED) revert InvalidStatus();
        if (releaseToFreelancer) {
            _release(jobId, job.freelancer);
        } else {
            job.status = STATUS_CANCELLED;
            pendingWithdrawals[job.client] += job.amount;
            emit JobRefunded(jobId, job.client);
        }
        emit DisputeResolved(jobId, msg.sender, releaseToFreelancer);
    }

    /// @notice Anyone can release the escrow once the review window passed
    ///         without a dispute (client went silent after submission).
    /// @dev Live selector 0x459b860e = autoRelease(uint256).
    ///      Live requires status == 1 (its submitWork never sets status to 2);
    ///      this rebuild requires STATUS_SUBMITTED, which is the same state
    ///      under a clean status machine.
    function autoRelease(uint256 jobId) external nonReentrant jobExists(jobId) {
        Job storage job = jobs[jobId];
        if (job.status != STATUS_SUBMITTED) revert InvalidStatus();
        if (block.timestamp <= job.submittedAt + job.duration) revert TooEarly();
        _release(jobId, job.freelancer);
        emit AutoReleased(jobId, job.freelancer, job.amount);
    }

    /// @notice Client AND freelancer both confirm completion; when the second
    ///         party confirms, the escrow releases to the freelancer.
    /// @dev Live selector 0x027570e0 = (uint256). The live function name is NOT
    ///      recoverable; `confirmCompletion` is the semantic name.
    ///      Live stores one confirmation bit per party in the packed slot-12 word.
    function confirmCompletion(uint256 jobId) external nonReentrant jobExists(jobId) {
        Job storage job = jobs[jobId];
        if (job.status != STATUS_STARTED && job.status != STATUS_SUBMITTED) revert InvalidStatus();
        if (msg.sender == job.client) {
            if (job.clientConfirmed != 0) revert AlreadyConfirmed();
            job.clientConfirmed = 1;
        } else if (msg.sender == job.freelancer) {
            if (job.freelancerConfirmed != 0) revert AlreadyConfirmed();
            job.freelancerConfirmed = 1;
        } else {
            revert NotParticipant();
        }
        emit WorkConfirmed(jobId, msg.sender);
        if (job.clientConfirmed != 0 && job.freelancerConfirmed != 0) {
            _release(jobId, job.freelancer);
        }
    }

    /// @notice Pull-payment: collect escrow / refund credited to the caller.
    /// @dev Live selector 0x3ccfd60b = withdraw().
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert ZeroAmount();
        pendingWithdrawals[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Full job record (same 21-field tuple as the public `jobs` getter).
    /// @dev Live selector 0xbf22c457 = getJob(uint256).
    function getJob(uint256 jobId) external view jobExists(jobId) returns (Job memory) {
        return jobs[jobId];
    }

    /// @dev Shared release path: mark Released, credit freelancer, emit event.
    function _release(uint256 jobId, address freelancer) internal {
        Job storage job = jobs[jobId];
        job.status = STATUS_RELEASED;
        pendingWithdrawals[freelancer] += job.amount;
        emit PaymentReleased(jobId, freelancer, job.amount);
    }
}
