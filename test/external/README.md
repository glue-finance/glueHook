# test/external/ — auditor-skill suites

**This is not an official audit.** None of the firms listed here reviewed, endorsed, or signed
these suites. Each file is the hook's own integration of that firm's published best practices and
skills into the test campaign. The firms are not parties to this work. The matching check tables
(with an `ALREADY SAFE` / `NEW COVERAGE` verdict per row and the main-suite twin of every
restatement) live in [`audit/external/`](../../audit/external/).

**49 tests across 4 firms.** Each file is an executable translation of a public audit firm's
skill checklist onto the hook's surface. They share `ExtBase.sol` — the main fixture plus the
hostile actors the checklists call for:

| Actor | What it does |
| --- | --- |
| `RiderMain` | a MAIN whose `transferFrom` hook calls `PoolManager.swap` on its own pool while the hook is pulling a program's seed — the transient PAYER window attack (PSH9) |
| `ProbeRecipient` | a native recipient that, paid at the swap's gas (no stipend), either observes the hook's books mid-frame (QS2), re-enters a chosen door, burns the gas it was given (QS7), or refuses (QS8) |
| `ProbeEngine` | a registered native engine that, from the full-gas `recordHarvest` callback, re-enters any hook door or the PoolManager (QS1) or observes the ledger at report time (QS2) |
| `MissingReturnERC20`, `ReturnFalseERC20` | weird-ERC20 secondaries (TOB9, TOB10); fee-on-transfer and blocklist mocks come from `test/mocks` |

They are **not** part of the main count. The default Foundry profile skips this folder; run them
only through:

```bash
./scripts/run-external.sh                         # every firm
./scripts/run-external.sh --match-contract ExtPSH # one firm
FOUNDRY_PROFILE=external forge test --match-path 'test/external/**'
```

| Firm | Contract | Tests | Docs |
| --- | --- | ---: | --- |
| Trail of Bits | `ExtTOB` | 14 | [`audit/external/trail-of-bits.md`](../../audit/external/trail-of-bits.md) |
| Pashov Audit Group | `ExtPSH` | 13 | [`audit/external/pashov.md`](../../audit/external/pashov.md) |
| QuillShield | `ExtQS` | 12 | [`audit/external/quillshield.md`](../../audit/external/quillshield.md) |
| Panther | `ExtPAN` | 10 | [`audit/external/panther.md`](../../audit/external/panther.md) |

Skills are read from GitHub (raw URLs in each firm doc). Nothing is vendored.
