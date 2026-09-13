# Pashov Audit Group (skills) — GlueHook mapping

**Firm:** [pashov/skills](https://github.com/pashov/skills)
**Suite:** `test/external/Ext-PSH.t.sol` (`ExtPSH`) — 13 tests
**Run:** `./scripts/run-external.sh --match-contract ExtPSH`

**This is not an official audit.** Pashov Audit Group did not review, endorse, or sign this
document. It is the hook's own integration of the firm's published best practices and skills into
the test campaign.

## Skill files read (GitHub raw, not installed)

- https://raw.githubusercontent.com/pashov/skills/main/README.md
- https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/SKILL.md
- https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/references/hacking-agents/access-control-agent.md
- https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/references/hacking-agents/asymmetry-agent.md
- https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/references/hacking-agents/boundary-agent.md
- https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/references/hacking-agents/economic-security-agent.md
- https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/references/hacking-agents/flow-gap-agent.md
- https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/references/hacking-agents/invariant-agent.md
- https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/references/hacking-agents/execution-trace-agent.md

Applied hacking agents: **access-control** (the weakest guard on every writable slot, escalation
chains), **asymmetry** (mirrored branches and mirrored operations), **economic-security** (the
admin-variant sandwich), **boundary** (codeless receivers, empty states, max inputs),
**flow-gap** (the transient PAYER window, the timers), **invariant** (conservation within a pool,
across pools, and the atomic rollback), **execution-trace** (a hostile MAIN riding the manager's
unlock from inside the hook's own frame).

## Check-by-check verdict

Verdicts follow the legend in [`README.md`](README.md).

| Check | Verdict | Test | Main-suite proof |
| --- | --- | --- | --- |
| Weakest guard on `Pot.recipient`: two writers only (`initPot` once, `setRecipient` admin); the program's owner and operator cannot move it; a second `initPot` refused | ALREADY SAFE | PSH1 | U3, U5 |
| No escalation chain: operator cannot become owner or lock the owner out; owner cannot take the operator seat back; a zeroed operator is frozen for everyone; a surrendered owner locks the liquidity but forces the harvest open | ALREADY SAFE | PSH2 | L10, L11, L19, L20 |
| Asymmetry — the two `donate` branches mirror: same two ledgers, same event body, ERC20 pulls EXACTLY `amount` from an unlimited allowance | ALREADY SAFE | PSH3 | U6, U8 |
| Asymmetry — add ↔ remove mirror: `liquidity` moves by exactly ±L, both harvest first (hook's ETH grows by exactly the pot's buyback leg, its token stock by nothing), principal never rests on the hook | ALREADY SAFE | PSH4 | L7, L8, N13 |
| Admin-variant sandwich: a config edit right before a harvest applies to the WHOLE pending amount — nothing pro-rata, nothing retroactive — so front/back-running an operator's edit extracts nothing | NEW COVERAGE | PSH5 | — (regime: L5, L27) |
| Codeless / receive-less receivers: EOA takes the ERC20 leg; a contract with no `receive` bounces the native leg into `owed` without reverting; backlog == Σ legs across harvests | ALREADY SAFE | PSH6 | L9, FM9 |
| Empty states are typed reverts, never silent zeros: `harvest` with no program / no liquidity, `claim` with no backlog, `flushDirect` with nothing parked or with the pot on burn (park intact) | ALREADY SAFE | PSH7 | B6, L9, L18 |
| Max inputs: a 2^120 ERC20 donation credited exactly; a boundless quote bounded by the pot; a `uint128.max` liquidity add reverts instead of truncating, program untouched | NEW COVERAGE | PSH8 | — |
| **Flow gap — the transient PAYER window cannot be hijacked**: while the hook pulls a program's seed, a hostile MAIN's transfer hook calls `PoolManager.swap` on the pool (the manager IS unlocked) to summon a pump whose settle would draw from the payer's allowance; the guard throws it out (`Reentrancy`, wrapped by the manager), pot untouched, no pump, payer paid exactly the position's amounts | NEW COVERAGE | PSH9 | — |
| Timers move ONLY behind swaps: funding a funded pot, moving the recipient, editing the rules and a manual harvest leave `referenceTickX8`, `lastTick`, `lastTimestamp` and the bucket untouched; the next swap moves the clock (control) | ALREADY SAFE | PSH10 | M3a–M3d, M7e |
| Conservation of the pump's legs over a session: pot drop == Σ spent; Σ bought == Σ delivered | ALREADY SAFE | PSH11 | PP2, PP6, PI2 |
| Conservation ACROSS pools: two pots in one secondary — obligation == pot₁ + pot₂ == hook balance to the wei, neither pot spends the other's money | ALREADY SAFE | PSH12 | A9, M9 |
| Atomic rollback and pot money never funds a position: with ANOTHER pool's pot ETH on the hook, an under-funded native `launchPool` settles transiently, is caught (`BadDonation`) and rolls back as ONE unit — no pool, no pot, no program, value back, the other pot intact | ALREADY SAFE | PSH13 | LA5, LA7, LA1 |
