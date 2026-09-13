# Trail of Bits (skills) — GlueHook mapping

**Firm:** [trailofbits/skills](https://github.com/trailofbits/skills)
**Suite:** `test/external/Ext-TOB.t.sol` (`ExtTOB`) — 14 tests
**Run:** `./scripts/run-external.sh --match-contract ExtTOB`

**This is not an official audit.** Trail of Bits did not review, endorse, or sign this document. It
is the hook's own integration of the firm's published best practices and skills into the test
campaign.

## Skill files read (GitHub raw, not installed)

- https://raw.githubusercontent.com/trailofbits/skills/main/README.md
- https://raw.githubusercontent.com/trailofbits/skills/main/plugins/entry-point-analyzer/README.md
- https://raw.githubusercontent.com/trailofbits/skills/main/plugins/sharp-edges/README.md
- https://raw.githubusercontent.com/trailofbits/skills/main/plugins/insecure-defaults/README.md
- https://raw.githubusercontent.com/trailofbits/skills/main/plugins/building-secure-contracts/skills/token-integration-analyzer/SKILL.md
- https://raw.githubusercontent.com/trailofbits/skills/main/plugins/property-based-testing/README.md

Applied: `entry-point-analyzer` (every external door classified — pot-admin, owner, operator,
contract-only, permissionless — and each class attacked from the wrong caller), `sharp-edges`
(type-identical argument swaps, value/amount confusion on a payable door, silent zero no-ops),
`insecure-defaults` (what the plain `addLiquidity` ships with), `token-integration-analyzer`
(weird-ERC20 missing-return, returns-false, fee-on-transfer, blocklist — each as the pot's
secondary or the program's main), `property-based-testing` (Foundry-transposed round-trip and
bounded-quote fuzz).

## Check-by-check verdict

Verdicts follow the legend in [`README.md`](README.md).

| Check | Verdict | Test | Main-suite proof |
| --- | --- | --- | --- |
| Pot-admin doors refuse a stranger (`initPot`, `setRecipient`, `addLiquidity`, `addLiquidityAdvanced`), pot untouched, admin control | ALREADY SAFE | TOB1 | U3, U4, U5, L3 |
| Owner doors vs operator doors: stranger refused; after the operator role moves, the OWNER is refused on operator doors and the OPERATOR on owner doors | ALREADY SAFE | TOB2 | L18, L19, SP7 |
| Contract-only doors: PoolManager callbacks and self-calls refuse any other caller; unlock callback refuses a non-manager; manager-driven UNKNOWN op refused | ALREADY SAFE | TOB3 | U2 |
| Permissionless doors are permissionless and cannot redirect value: stranger funds, retries a park, harvests a public program; a recipient pulls only its own backlog | ALREADY SAFE | TOB4 | U6, B6, L9, L18 |
| Insecure defaults: plain `addLiquidity` ships with EVERYTHING off (zero shares, recipients = owner, harvest closed, auto-harvest disarmed, owner == operator, not native) and is SILENT behind swaps | ALREADY SAFE | TOB5 | SP8, G2b, N3 |
| Type-identical argument swaps fail loudly: `initPot(key, RECIPIENT, MAIN)` → `BadRoles`, native main → `BadRoles`, `launchPool` on a foreign-hook key refused | ALREADY SAFE | TOB6 | U4, LA3, LA6 |
| Value/amount confusion on `donate`: native pot refuses `msg.value != amount` both ways and a zero; ERC20 pot refuses any value, a zero, an unapproved pull (token error bubbles, no silent credit) | ALREADY SAFE | TOB7 | U6, U8, LA2 |
| Zero and bounds are loud: zero liquidity on create / add, a removal of zero, over the holding, or to `address(0)` — all `BadConfig` | NEW COVERAGE | TOB8 | — (partial: LA7, L8) |
| Weird ERC20 — missing return value (USDT class) as the secondary: pulls through SafeERC20, exact credit, obligation == held | NEW COVERAGE | TOB9 | — |
| Weird ERC20 — returns false (Tether-Gold class) as the secondary: `SafeERC20FailedOperation`, no phantom pot | NEW COVERAGE | TOB10 | — |
| Fee-on-transfer secondary: the credit is the MEASURED arrival (900 of 1,000 at 10%), obligation == real balance | ALREADY SAFE | TOB11 | U8, A7 |
| Blocklist main: a refused live delivery PARKS per pool; unblocked, `flushDirect` pays the whole park and clears it | ALREADY SAFE | TOB12 | A4, B8, NS1 |
| Property: `addProgramLiquidity(L)` → `removeProgramLiquidity(L)` never mints value (fuzzed L) — the remover gets at most what the adder paid on both legs, program liquidity back to its seed | ALREADY SAFE | TOB13 | L8, L12, PI6 |
| Property: `quotePump` never reverts for any demand and is bounded by the pot, by the gate's share of the demand and by the fee ceiling (fuzzed demand) | ALREADY SAFE | TOB14 | FM1, FM6, U13 |
