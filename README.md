# HireLock — trustless escrow for hiring

HireLock is a minimal on-chain escrow for freelance work: a client locks
payment in the contract, the freelancer does the job, and the money is
released only when the work is confirmed — or refunded if it never happens.
No middleman, no custody beyond the contract itself.

Built for **Arbitrum Open House São Paulo** (buildathon 8–28 Feb 2027,
deadline 28 Feb 2027 23:59 BRT, track **Promising Products**).

## How it works

```
createJob (client, pays) ──► startJob (freelancer) ──► submitWork (freelancer)
        │                                                          │
        │  cancelBeforeStart (client, before start)                ▼
        │  refundAfterDeadline (client, past deadline)     confirmRelease (client)
        │                                                          │  OR
        └────────────────── refund ──────────────────►  autoRelease (anyone, after
                                                              review window)
                                                              │  OR
                                                     confirmCompletion (client
                                                              + freelancer)
                                                              ▼
                                                    withdraw (freelancer)
```

Disputes: either party calls `raiseDispute(jobId, reasonHash)`; the arbiter
(named at creation, `address(0)` = none) settles with
`resolveDispute(jobId, releaseToFreelancer)`. Funds are always paid out via
pull-payment (`pendingWithdrawals` + `withdraw()`), never pushed.

| Function | Who | When |
|---|---|---|
| `createJob(freelancer, arbiter, deadline, duration, title)` payable | client | anytime (funds the escrow) |
| `startJob(jobId)` | freelancer | status Created |
| `submitWork(jobId, workHash)` | freelancer | started |
| `confirmRelease(jobId)` | client | submitted |
| `autoRelease(jobId)` | anyone | submitted + review window passed |
| `confirmCompletion(jobId)` | client + freelancer | both must confirm |
| `cancelBeforeStart(jobId)` | client | not started yet |
| `refundAfterDeadline(jobId)` | client | past `deadline`, not submitted |
| `raiseDispute(jobId, reasonHash)` | client or freelancer | started / submitted |
| `resolveDispute(jobId, releaseToFreelancer)` | arbiter | disputed |
| `withdraw()` | anyone with credit | has a balance |

Status: `0 Created · 1 Started · 2 Submitted · 3 Released · 4 Cancelled · 5 Disputed`.

## Live contract (the original this rebuilds)

- **Arbitrum Sepolia:** [`0x3B6E7aD423ffc3118F031cBD4226deC870eB14Aa`](https://sepolia.arbiscan.io/address/0x3B6E7aD423ffc3118F031cBD4226deC870eB14Aa)
- Created 11 Nov 2026, tx `0x20d0c2ac…`. One demo job exists (#1,
  "Paint the living room - demo job", 0.01 ETH, completed: create → start →
  submit → confirmRelease).
- Source was **never verified** on Arbiscan and the original repo was lost,
  so this project reconstructs it from the on-chain bytecode (Heimdall
  disassembly + live `eth_call` reads). See `SELECTOR_CHECK.md`.

## Rebuild status — what is verified vs. assumed

**Verified (12/15 function selectors match the live contract byte-for-byte):**
`createJob`, `startJob`, `confirmRelease`, `cancelBeforeStart`,
`raiseDispute`, `resolveDispute`, `autoRelease`, `withdraw`, `jobs`,
`getJob`, `jobCount`, `pendingWithdrawals`. The `jobs`/`getJob` 21-field
return shape and the storage layout (slots 0–3, packed slot-12 word) were
confirmed against live chain data, and the `PaymentReleased` / `Withdrawn` /
`JobStarted` event topics match. All 16 Foundry tests pass.

**Assumed (3 function names unrecoverable):** the live names of
`0xa118c41a` (submit work), `0xcc9f3c51` (refund after deadline) and
`0x027570e0` (dual confirmation) are not in 4byte.directory and did not match
~1.000 brute-forced candidates. Their **behaviour is proven** from the
bytecode; the rebuild uses the semantic names `submitWork`,
`refundAfterDeadline`, `confirmCompletion` (selectors therefore differ — see
`SELECTOR_CHECK.md`).

**Deliberate fixes vs. the live contract (documented, not silent):**
- Live job #1's `amount` field reads `0` even though 0.01 ETH was escrowed
  (the original never stored `msg.value`); the rebuild stores
  `amount = msg.value`, so multi-job escrows actually work. The observable
  outcome for one job is identical (0.01 ETH released).
- Live `raiseDispute` ORs `2` into the status byte (can corrupt the status);
  the rebuild sets a clean `Disputed` state.
- Live `refundAfterDeadline` requires status `Created` only; the rebuild
  also allows `Started` (a started-but-never-submitted job must still be
  refundable).
- Live `autoRelease` requires status `1` (its `submitWork` never sets
  status to `2`); the rebuild requires `Submitted`, the same state under a
  clean status machine.
- Live timestamp fields in storage vs. getter return differ by a fixed
  offset (Nov 14 vs. Nov 11 values) — cause undetermined; the rebuild stores
  and returns plain `block.timestamp` values.

## Develop

```bash
forge build   # solc 0.8.24, via-IR (needed: the 21-field struct is stack-heavy)
forge test    # 16 tests, all passing
```

Deploy (Arbitrum Sepolia):

```bash
forge create src/HireLock.sol:HireLock \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key $PRIVATE_KEY
```

Then verify the source on Arbiscan (the original never was — do not repeat
that mistake) and paste the address into `frontend/app.js`.

## Frontend demo

`frontend/` is a single-page read-only demo (no build step, ethers.js from
CDN). Open `index.html`, it shows `jobCount` and the full job #1 record from
the live Sepolia contract. No wallet needed for reading.

## Repo layout

```
hirelock/
├── src/HireLock.sol        # the contract
├── test/HireLock.t.sol     # 16 Foundry tests
├── frontend/               # read-only demo (index.html + app.js)
├── SELECTOR_CHECK.md       # 12/15 selector proof + the 3 unknowns
├── README.md               # this file
├── foundry.toml
└── lib/forge-std/          # test dependency
```

Recon material (bytecode, disassembly, chain reads) lives in
`~/workspace/hirelock-recon/` and is not part of this repo.
