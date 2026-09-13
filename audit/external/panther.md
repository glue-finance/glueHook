# Panther (move-auditor) — GlueHook mapping

**Firm:** [pantheraudits/move-auditor](https://github.com/pantheraudits/move-auditor)
**Suite:** `test/external/Ext-PAN.t.sol` (`ExtPAN`) — 10 tests
**Run:** `./scripts/run-external.sh --match-contract ExtPAN`

**This is not an official audit.** Panther did not review, endorse, or sign this document. It is
the hook's own integration of the firm's published best practices and skills into the test
campaign.

## Skill files read (GitHub raw, not installed)

- https://raw.githubusercontent.com/pantheraudits/move-auditor/main/README.md
- https://raw.githubusercontent.com/pantheraudits/move-auditor/main/defi/defi-slippage.md
- https://raw.githubusercontent.com/pantheraudits/move-auditor/main/defi/defi-math-precision.md

Applied (chain-agnostic DeFi vectors transposed to Solidity): the slippage family (DEFI-43/46/47/48,
DEFI-92) and the math-precision family (DEFI-35/36/37/38/39/41, DEFI-86). DEFI-44/45 (deadlines,
user-supplied slippage) are N/A: the hook exposes no user deadline or slippage parameter — every
pump is sized inside the carrying swap's own frame, against the pool's own step quote at that
instant. The Move-chain-specific vectors (SUI-*, APT-*) are N/A.

## Check-by-check verdict

Verdicts follow the legend in [`README.md`](README.md).

| Vector | Verdict | Test | Main-suite proof |
| --- | --- | --- | --- |
| DEFI-43/46 — the output floor is real, never zero while the spend is not: `minOut` == the pool's own `quoteSwapStep(spend)` minus one millionth, exactly | NEW COVERAGE | PAN1 | — (regime: FM5, U13) |
| DEFI-47 — the LP add settles EXACTLY V4's `getAmount0Delta` / `getAmount1Delta` rounded up (recomputed from first principles), refunds the native excess and pulls the token leg to the wei, nothing left on the hook; the library's own `getAmountsForLiquidity` is the floor form of the same value (≤ settled, ≥ settled − 1 wei) — this row surfaced and fixed the helper's ~1% full-range error, see [`README.md`](README.md) | NEW COVERAGE (+ fix) | PAN2 | — (refund exactness: LA1, L1) |
| DEFI-36 — rounding to zero: a 1-wei buy and a 1-wei sell carry no pump; pot and bucket exactly untouched | ALREADY SAFE | PAN3 | U14, M7d |
| DEFI-37 — decimals: on a 6-decimal secondary a 1,000-unit pot facing a 1,000-unit demand spends exactly `floor(0.6e9)·0.8 = 4.8e8` raw — the same formula 18 decimals obey | ALREADY SAFE | PAN4 | D1, D8, D9 |
| DEFI-39 — rounding direction: at a full bucket and an open gate the quote is exactly `floor(min(pot, f·R, 60%·demand) · 80%)` — fee-capped (1 ETH), demand-capped (0.1 ETH → 0.048), pot-capped (0.01 ETH pot → 0.008) | NEW COVERAGE | PAN5 | — (bounds: FM1, M7a) |
| DEFI-38/41 — the uint32 clock across its 2^32 wrap: funded 100 s before, settled and pumped across it, a full-size pump on both sides, gate open, clock stamped with the wrapped timestamp | NEW COVERAGE | PAN6 | — |
| DEFI-86 — observation liveness under a failing leg: a MAIN that refuses delivery to the hook makes the pump's self-call revert (caught: no `Pumped`, debit rolled back) while the swap lands and `lastTimestamp` / `lastTick` advance | NEW COVERAGE | PAN7 | — (isolation: A10) |
| DEFI-92 — check and settlement share one basis: an exact-input sell of 300 MAIN pumps exactly `floor(floor(60% · ETH received) · 80%)` — the delta, never `amountSpecified` | NEW COVERAGE | PAN8 | — (direction: A8) |
| DEFI-35 — formula exactness: `pumpShareOf` == `min(60%, f/d)` with `d = 1.0001^gap − 1` recomputed independently from the reported tick gap via the sqrt-ratio table, at three premiums | ALREADY SAFE | PAN9 | M4, FM4 |
| DEFI-48 — token vs value: both directions denominate the demand in the pot's currency (≤ 48% of the ETH paid on a buy, ≤ 48% of the ETH received on a sell, never a share of the token amount) | ALREADY SAFE | PAN10 | A8, U9, U10 |
| DEFI-44/45 deadlines and user slippage | N/A | — | no user parameter exists |
| SUI-* / APT-* | N/A | — | Move-chain specific |
