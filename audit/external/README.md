# audit/external/ — firm-skill mappings

**This is not an official audit.** None of the firms listed here reviewed, endorsed, or signed
these documents. Each file is the hook's own integration of that firm's PUBLISHED best practices
and skills into the test campaign — a check table plus the test that answers each row. The firms
are not parties to this work.

The executable suites live in [`test/external/`](../../test/external/). They compile and run
separately from the main suite (`./scripts/run-external.sh`, or `FOUNDRY_PROFILE=external forge
test --match-path 'test/external/**'`), on their own fixture (`ExtBase.sol`) with their own hostile
actors — a MAIN whose transfer hook rides the manager's unlock, a recipient and an engine that
observe or re-enter from inside the hook's frame, odd ERC20s (missing return, returns false,
fee-on-transfer, blocklist). Skills are read from GitHub (raw URLs in each firm doc); nothing is
vendored.

The pattern is borrowed from the Glue protocol's own `glue-v2-foundry` external layer, transposed
to the hook's surface: pot doors, LP program doors, the pump, the native report, the transient
guard and the PAYER window.

## Verdict legend

Every row of a firm's check table carries one of two verdicts. Neither means a contract was
changed — no firm check found a defect; the verdict says WHERE the proof lives:

| Verdict | Meaning |
| --- | --- |
| `ALREADY SAFE` | The property was already pinned by the main suite before the firm's checklist was imported. The last column names the main-suite test(s) that carry the proof (IDs resolve in [`audit/AUDIT.md` §6](../AUDIT.md#6-test-inventory)); the external test is the firm-shaped restatement and runs as a second, independent witness. |
| `NEW COVERAGE` | The firm's checklist prompted a test the main suite did not have in that shape. The external test is the only place this exact property is pinned. It passed first time — coverage was added, not a fix. |

The external layer is deliberately a RESTATEMENT layer: when an external assertion is weaker than
its main-suite twin, the twin is the proof of record. Every external assertion is nonetheless held
to the same bar — exact values or oracle-derived bounds (the pool's own `quoteSwapStep`, V4's own
`getAmount0Delta` / `getAmount1Delta`, the hook's published ledgers), typed reverts, event bodies —
so that a description never claims more than its body proves.

| Firm | Tests | Docs | Suite |
| --- | ---: | --- | --- |
| Trail of Bits | 14 | [`trail-of-bits.md`](trail-of-bits.md) | `ExtTOB` |
| Pashov Audit Group | 13 | [`pashov.md`](pashov.md) | `ExtPSH` |
| QuillShield | 12 | [`quillshield.md`](quillshield.md) | `ExtQS` |
| Panther | 10 | [`panther.md`](panther.md) | `ExtPAN` |

**49 tests, 0 failures**, against the same etched PoolManager and the same delegatecall topology
as the main suite.

```bash
./scripts/run-external.sh                         # every firm
./scripts/run-external.sh --match-contract ExtTOB # one firm
```

## One finding surfaced by the layer — fixed (library helper, not hook logic)

`PAN2` tried to predict the amounts an `addLiquidity` settles with the library's own
`GluedV4Core.getAmountsForLiquidity` and found it ~1% LOW on a full-range position: its
`getAmount0ForLiquidity` computed `L·Q96/sqrtUpper` FIRST (a two-digit integer at the max tick,
floored) and only then multiplied by `(sqrtUpper − sqrtLower)/sqrtLower`, where V4's
`getAmount0Delta` keeps `(L << 96)·(sqrtUpper − sqrtLower)/sqrtUpper` in 512 bits and divides last.

- **Impact here: none on chain.** The helper is not called anywhere in the hook or the linked
  library (the hook settles whatever the PoolManager's own delta says); the deployed bytecode does
  not contain it (`forge build --sizes` unchanged at 19,439 / 19,612 before and after).
- **Fix:** `getAmount0ForLiquidity` now IS V4's floor-form `getAmount0Delta`:
  `md512(L << 96, sqrtUpper − sqrtLower, sqrtUpper) / sqrtLower`. `getAmount1ForLiquidity` already
  matched `getAmount1Delta`.
- **Proof:** `PAN2` pins the settled amounts to V4's round-up formula recomputed from first
  principles, and asserts the helper is the floor form of the same value — never above the settled
  amount, never more than one wei under it, on both legs.
- **Sibling repo:** the same two-step implementation existed in `glue-v2-foundry/src/libs/GluedV4Core.sol`,
  where it **is** called by the engines (`GlueLP_UniV4`, `GlueLP_GlueHook`, `GlueHookPort`,
  `GlueLockerLP`, `GlueLP_UniV3` via `GluedV3Core`) — as a display leg and as the default 1% min-out
  floor on the currency0 leg of a removal (looser, never tighter; at full range the old intermediate
  is ~`L / 2^64`, zero for `L < ~1.8e19`). Fixed there with the same form in the library and both
  vendored test copies, pinned by `test/math/Glue-V4-LiquidityMath.t.sol` (LM1–LM6: fuzz against an
  independent oracle, exact integer floor, a real pool settling `helper` or `helper + 1`, the min-out
  floor real on a dust stake).
