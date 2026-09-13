# QuillShield (skills) — GlueHook mapping

**Firm:** [quillai-network/quillshield_skills](https://github.com/quillai-network/quillshield_skills)
**Suite:** `test/external/Ext-QS.t.sol` (`ExtQS`) — 12 tests
**Run:** `./scripts/run-external.sh --match-contract ExtQS`

**This is not an official audit.** QuillShield did not review, endorse, or sign this document. It
is the hook's own integration of the firm's published best practices and skills into the test
campaign.

## Skill files read (GitHub raw, not installed)

- https://raw.githubusercontent.com/quillai-network/quillshield_skills/main/README.md
- https://raw.githubusercontent.com/quillai-network/quillshield_skills/main/plugins/input-arithmetic-safety/skills/input-arithmetic-safety/SKILL.md

Applied layers: **semantic-guard-analysis** (every value-moving door carries the same guard,
probed from the one channel a stranger owns with real gas), **reentrancy-pattern-analysis**
(read-only reentrancy mid-frame), **oracle-flashloan-analysis** (the reference as the hook's own
time-weighted tick, no external feed), **input-arithmetic-safety** (share caps, floors),
**external-call-safety** (gas-burning recipient, pull-payment isolation, a refusing Glue burn),
**state-invariant-detection** (the obligation identity), **dos-griefing-analysis** (force-feeding,
under-gassed swaps).

## Check-by-check verdict

Verdicts follow the legend in [`README.md`](README.md).

| Check | Verdict | Test | Main-suite proof |
| --- | --- | --- | --- |
| **Guard consistency matrix**: from the full-gas native report the engine re-enters `donate`, `claim`, `flushDirect`, `harvest`, `addProgramLiquidity`, `removeProgramLiquidity` and `PoolManager.swap` — inside a carrying swap all seven answer `Reentrancy`; from a manual harvest the six hook doors answer `Reentrancy` and the manager `ManagerLocked`; the report completes anyway | NEW COVERAGE | QS1 | — (single doors: A5, A11, N11, NS4) |
| Read-only reentrancy: a native recipient paid at the swap's gas sees `hook.balance >= obligation` mid-leg; the engine sees, at report time, the ledger at its final value, the pot at its final balance, and solvency | NEW COVERAGE | QS2 | — |
| Flash push cannot move the reference: same block, gate after a 30% push is `f/d` under 1%, push-then-dump loses | ALREADY SAFE | QS3 | M3b, M1, A3 |
| No external price feed: the reference is seeded from the pool's own slot0 tick at declaration and re-seeded from it when a donation funds an EMPTY pot, exactly | ALREADY SAFE | QS4 | M3a, M3d |
| Share caps exact: `compound + buyback` and `compound + burn` above 100% → `BadConfig`; exactly 100% legal with a zero recipient; one wei under needs a live one | ALREADY SAFE | QS5 | L4, L16, SP6 |
| Floors never create value: one-third shares → pot `floor(fS/3)`, burn `floor(fM/3)`, recipients the exact rests; no wei lost or minted on either side | ALREADY SAFE | QS6 | L5, FM7, D3 |
| Gas-burning recipient is charged to the swap, never bounded: under a generous budget the swap lands with the leg booked `owed`; under a budget an accepting recipient fits in twice the swap fails out of gas on its own pool only, no book moved; an accepting recipient is paid again with the backlog | NEW COVERAGE | QS7 | — (booking: A4, L9) |
| Pull payments isolated: a refusing recipient cannot claim (backlog stays booked, nothing else blocked) while another claims its own in full | ALREADY SAFE | QS8 | L9, FM9 |
| Obligation identity under hostility: for both assets `obligationOf` == pot + parked + held + carry + Σ owed, and the hook's balance covers it | ALREADY SAFE | QS9 | PP1, PP5, PI1, PI3 |
| Force-feeding is inert: ETH and MAIN sent straight to the hook move no ledger, fund no pot, change no quote, never pump | NEW COVERAGE | QS10 | — |
| A refusing Glue burn never blocks the carrying swap: the leg is HELD, the asset flagged, later burns short-circuit | ALREADY SAFE | QS11 | B1, B4, NS2 |
| Under-gassed swaps never half-book: at every gas level the frame reverts whole or lands with the books closed — pot never overdraws, obligation covered | NEW COVERAGE | QS12 | — (regime: A10, M8b) |
