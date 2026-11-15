// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/HireLock.sol";

contract HireLockTest is Test {
    HireLock public lock;

    address public client = address(0xC11E);
    address public freelancer = address(0xF3EE);
    address public arbiter = address(0xA881);
    address public stranger = address(0x7777);

    uint256 public constant ESCROW = 0.01 ether;
    uint256 public constant DEADLINE = 1_800_000_000; // far future
    uint256 public constant REVIEW = 3600; // 1 hour review window
    bytes32 public constant WORK_HASH = keccak256("painted-living-room-proof");

    function setUp() public {
        lock = new HireLock();
        vm.deal(client, 10 ether);
        vm.deal(freelancer, 1 ether);
        vm.deal(arbiter, 1 ether);
        vm.deal(stranger, 1 ether);
    }

    function _createJob() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = lock.createJob{value: ESCROW}(
            freelancer,
            arbiter,
            DEADLINE,
            REVIEW,
            "Paint the living room - demo job"
        );
    }

    function _startJob(uint256 jobId) internal {
        vm.prank(freelancer);
        lock.startJob(jobId);
    }

    function _submitWork(uint256 jobId) internal {
        vm.prank(freelancer);
        lock.submitWork(jobId, WORK_HASH);
    }

    // ---- Happy path: create -> start -> submit -> confirmRelease -> withdraw ----
    function testHappyPath() public {
        uint256 jobId = _createJob();
        assertEq(lock.jobCount(), 1);
        assertEq(address(lock).balance, ESCROW);

        _startJob(jobId);
        _submitWork(jobId);

        uint256 before = freelancer.balance;
        vm.prank(client);
        lock.confirmRelease(jobId);
        assertEq(lock.pendingWithdrawals(freelancer), ESCROW);

        vm.prank(freelancer);
        lock.withdraw();
        assertEq(freelancer.balance, before + ESCROW);
        assertEq(lock.pendingWithdrawals(freelancer), 0);
        assertEq(address(lock).balance, 0);
    }

    // ---- getJob returns the full 21-field record ----
    function testGetJobFields() public {
        uint256 jobId = _createJob();
        HireLock.Job memory job = lock.getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.freelancer, freelancer);
        assertEq(job.amount, ESCROW);
        assertEq(job.arbiter, arbiter);
        assertEq(job.deadline, DEADLINE);
        assertEq(job.duration, REVIEW);
        assertEq(job.status, 0); // Created
        assertEq(job.title, "Paint the living room - demo job");
        // public getter returns the same record (21 fields)
        (
            address c,
            address f,
            uint256 amt,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint8 stat,
            ,
        ) = lock.jobs(jobId);
        assertEq(c, client);
        assertEq(f, freelancer);
        assertEq(amt, ESCROW);
        assertEq(stat, 0);
    }

    // ---- Dispute -> arbiter releases to freelancer ----
    function testDisputeReleaseToFreelancer() public {
        uint256 jobId = _createJob();
        _startJob(jobId);
        _submitWork(jobId);

        vm.prank(client);
        lock.raiseDispute(jobId, keccak256("work not good enough"));
        assertEq(lock.getJob(jobId).status, 5); // Disputed

        vm.prank(arbiter);
        lock.resolveDispute(jobId, true);
        assertEq(lock.pendingWithdrawals(freelancer), ESCROW);

        uint256 before = freelancer.balance;
        vm.prank(freelancer);
        lock.withdraw();
        assertEq(freelancer.balance, before + ESCROW);
    }

    // ---- Dispute -> arbiter refunds the client ----
    function testDisputeRefundToClient() public {
        uint256 jobId = _createJob();
        _startJob(jobId);
        _submitWork(jobId);

        vm.prank(freelancer);
        lock.raiseDispute(jobId, keccak256("client ghosted me"));

        vm.prank(arbiter);
        lock.resolveDispute(jobId, false);
        assertEq(lock.pendingWithdrawals(client), ESCROW);

        uint256 before = client.balance;
        vm.prank(client);
        lock.withdraw();
        assertEq(client.balance, before + ESCROW);
    }

    // ---- cancelBeforeStart refunds the client ----
    function testCancelBeforeStart() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        lock.cancelBeforeStart(jobId);
        assertEq(lock.getJob(jobId).status, 4); // Cancelled
        assertEq(lock.pendingWithdrawals(client), ESCROW);

        uint256 before = client.balance;
        vm.prank(client);
        lock.withdraw();
        assertEq(client.balance, before + ESCROW);
    }

    // ---- cancelBeforeStart reverts once started ----
    function testCancelBeforeStartRevertsAfterStart() public {
        uint256 jobId = _createJob();
        _startJob(jobId);
        vm.prank(client);
        vm.expectRevert(HireLock.InvalidStatus.selector);
        lock.cancelBeforeStart(jobId);
    }

    // ---- refundAfterDeadline refunds the client past the deadline ----
    function testRefundAfterDeadline() public {
        uint256 jobId = _createJob();
        vm.warp(DEADLINE + 1);
        vm.prank(client);
        lock.refundAfterDeadline(jobId);
        assertEq(lock.getJob(jobId).status, 4);
        assertEq(lock.pendingWithdrawals(client), ESCROW);
    }

    // ---- refundAfterDeadline reverts before the deadline ----
    function testRefundAfterDeadlineRevertsEarly() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        vm.expectRevert(HireLock.TooEarly.selector);
        lock.refundAfterDeadline(jobId);
    }

    // ---- autoRelease pays the freelancer once the review window passes ----
    function testAutoRelease() public {
        uint256 jobId = _createJob();
        _startJob(jobId);
        _submitWork(jobId);
        // inside the review window: too early
        vm.prank(stranger);
        vm.expectRevert(HireLock.TooEarly.selector);
        lock.autoRelease(jobId);
        // past the review window: anyone can trigger it
        vm.warp(block.timestamp + REVIEW + 1);
        vm.prank(stranger);
        lock.autoRelease(jobId);
        assertEq(lock.pendingWithdrawals(freelancer), ESCROW);
    }

    // ---- confirmCompletion: both parties confirm, then it releases ----
    function testConfirmCompletionDual() public {
        uint256 jobId = _createJob();
        _startJob(jobId);
        _submitWork(jobId);

        vm.prank(freelancer);
        lock.confirmCompletion(jobId);
        assertEq(lock.pendingWithdrawals(freelancer), 0); // not yet, one side only

        vm.prank(client);
        lock.confirmCompletion(jobId);
        assertEq(lock.pendingWithdrawals(freelancer), ESCROW);
    }

    // ---- Access control ----
    function testOnlyFreelancerCanStart() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        vm.expectRevert(HireLock.NotFreelancer.selector);
        lock.startJob(jobId);
    }

    function testOnlyClientCanConfirmRelease() public {
        uint256 jobId = _createJob();
        _startJob(jobId);
        _submitWork(jobId);
        vm.prank(freelancer);
        vm.expectRevert(HireLock.NotClient.selector);
        lock.confirmRelease(jobId);
    }

    function testOnlyArbiterCanResolve() public {
        uint256 jobId = _createJob();
        _startJob(jobId);
        vm.prank(client);
        lock.raiseDispute(jobId, bytes32("x"));
        vm.prank(client);
        vm.expectRevert(HireLock.NotArbiter.selector);
        lock.resolveDispute(jobId, true);
    }

    function testCreateRequiresValue() public {
        vm.prank(client);
        vm.expectRevert(HireLock.ZeroAmount.selector);
        lock.createJob(freelancer, arbiter, DEADLINE, REVIEW, "free job");
    }

    function testWithdrawEmptyReverts() public {
        vm.prank(stranger);
        vm.expectRevert(HireLock.ZeroAmount.selector);
        lock.withdraw();
    }

    function testCannotStartTwice() public {
        uint256 jobId = _createJob();
        _startJob(jobId);
        vm.prank(freelancer);
        vm.expectRevert(HireLock.InvalidStatus.selector);
        lock.startJob(jobId);
    }
}
