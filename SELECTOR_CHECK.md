# Selector Check — HireLock rebuild vs live contract

Live contract: **Arbitrum Sepolia `0x3B6E7aD423ffc3118F031cBD4226deC870eB14Aa`**
Rebuild: `src/HireLock.sol` (Solidity 0.8.24, Foundry 1.9.0)
Checked: 15 Nov 2026. Method: compile with `forge build`, extract function
selectors from the artifact ABI, compare against the 15 selectors read from
the live bytecode dispatcher (Heimdall disassembly) and confirmed via
`4byte.directory` + live transaction calldata.

## Result: 12 / 15 selectors match exactly

| Live selector | Rebuild signature | Match |
|---|---|---|
| `0x180aedf3` | `jobs(uint256)` | ✅ |
| `0x34b25ee2` | `resolveDispute(uint256,bool)` | ✅ |
| `0x3ccfd60b` | `withdraw()` | ✅ |
| `0x459b860e` | `autoRelease(uint256)` | ✅ |
| `0x4c5d8a0f` | `jobCount()` | ✅ |
| `0x636bf26d` | `raiseDispute(uint256,bytes32)` | ✅ |
| `0x6fbc4e57` | `cancelBeforeStart(uint256)` | ✅ |
| `0x879397c4` | `createJob(address,address,uint256,uint256,string)` | ✅ |
| `0xba6bc66e` | `confirmRelease(uint256)` | ✅ |
| `0xbf22c457` | `getJob(uint256)` | ✅ |
| `0xe1255294` | `startJob(uint256)` | ✅ |
| `0xf3f43703` | `pendingWithdrawals(address)` | ✅ |

The rebuild exposes exactly 15 functions — the same count as the live
contract, no extras.

## Unmatched: 3 live selectors whose names are unrecoverable

These three selectors are **not registered in 4byte.directory** and did not
match any of ~1.000 candidate signatures brute-forced with `cast sig` /
keccak (verb×noun combinations, `Job`/`Gig`/`Task`/`Escrow`/`Order` nouns,
`BeforeStart`/`AfterDeadline`/`AfterReview` suffixes, `(uint256)`,
`(uint256,bytes32)`, `(uint256,uint256)` arg shapes). Their **semantics are
proven** from the disassembled bodies + live transactions; only the exact
original names are unknown. The rebuild uses the semantic names below, so
these three selectors differ from live (documented, not hidden).

| Live selector | Proven semantics | Rebuild name (selector) |
|---|---|---|
| `0xa118c41a` | `(uint256,bytes32)` — freelancer submits the work content-hash. Proven by tx `0x1926f5…` (jobId=1 + hash `b277dbea…`). | `submitWork(uint256,bytes32)` → `0x0a9eeded` |
| `0xcc9f3c51` | `(uint256)` — client only, status must be Created, `block.timestamp >= deadline`, then the release helper runs (refund path). | `refundAfterDeadline(uint256)` → `0xc5f6346d` |
| `0x027570e0` | `(uint256)` — client **and** freelancer each set one confirmation bit in the packed slot-12 word; when both bits are set the release helper runs. Emits event `0x4d842fb2…`. | `confirmCompletion(uint256)` → `0x94aeb613` |

## Event topics (verified by keccak)

| Event | Signature used | Live topic | Match |
|---|---|---|---|
| `PaymentReleased` | `PaymentReleased(uint256,address,uint256)` | `21d71db5…` | ✅ |
| `Withdrawn` | `Withdrawn(address,uint256)` | `7084f547…` | ✅ |
| `JobStarted` | `JobStarted(uint256,address)` | `4b73dcf0…` | ✅ |
| `JobCreated` | — (exact live signature not determined) | `992d4304…` | ❓ |
| `WorkSubmitted` | — (exact live signature not determined) | `1c685ee7…` | ❓ |
| `DisputeRaised` | `DisputeRaised(uint256,address,bytes32)` | `77054bb8…` | ❓ (not verified — live topic is the raw hash) |

`JobCreated` / `WorkSubmitted` / `DisputeRaised` topics are recorded from the
live chain; the rebuild's event signatures for them are sensible but their
topics were not matched to live (several candidate signatures tried, none hit).

## Error selectors (verified by keccak)

| Error | Live selector | Match |
|---|---|---|
| `TooEarly()` | `0x085de625` | ✅ |
| `ZeroAmount()` | `0x1f2a2005` | ✅ |

## How the 12 were proven

- `createJob`, `startJob`, `submitWork`, `confirmRelease` — confirmed from
  live transaction calldata on job #1 (Sepolia).
- `jobs`, `getJob`, `jobCount`, `pendingWithdrawals`, `withdraw`,
  `resolveDispute`, `confirmRelease`, `startJob` — confirmed via
  `4byte.directory`.
- `raiseDispute`, `cancelBeforeStart`, `autoRelease` — found by brute-force
  `cast sig` / keccak over candidate names, then cross-checked against the
  disassembled bodies (caller checks, status checks, time checks).
- `jobs` / `getJob` return shape — confirmed by live `eth_call`:
  21 fields, same order and values as the rebuild's `Job` struct.

## Reproduce

```bash
forge build
python3 - <<'EOF'
import json
from Crypto.Hash import keccak
d = json.load(open('out/HireLock.sol/HireLock.json'))
for f in d['abi']:
    if f.get('type') == 'function':
        sig = f['name'] + '(' + ','.join(i['type'] for i in f.get('inputs', [])) + ')'
        k = keccak.new(digest_bits=256); k.update(sig.encode())
        print('0x' + k.hexdigest()[:8], sig)
EOF
```
