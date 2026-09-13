#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# EXTERNAL AUDITOR-SKILL SUITES — never part of the main `forge test`.
#
#   ./scripts/run-external.sh                         # every firm (49 tests)
#   ./scripts/run-external.sh --match-contract ExtTOB # one firm
#   ./scripts/run-external.sh -vv                     # extra args pass through
#
# Equivalent raw form:
#   FOUNDRY_PROFILE=external forge test --match-path 'test/external/**'
#
# Separation: foundry.toml's default profile skips `test/external/**`, so a
# plain `forge test` never compiles or runs them. Check tables and verdicts:
# audit/external/README.md
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
cd "$(dirname "$0")/.."
FOUNDRY_PROFILE=external forge test --match-path 'test/external/**' "$@"
