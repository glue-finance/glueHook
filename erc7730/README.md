# ERC-7730 clear-signing descriptors

Human-readable signing screens for every user-facing GlueHook V3 entrypoint, in the
format the [ethereum/clear-signing-erc7730-registry](https://github.com/ethereum/clear-signing-erc7730-registry)
accepts. Ledger (and every wallet consuming the registry) renders "Launch TOKEN/ETH
pool" instead of a selector + hex blob.

```
erc7730/
  annotations.mjs        WHAT to show per parameter (labels, formats, intents)
  build.mjs              ABI + annotations → registry/glue/calldata-GlueHook.json
  fixtures.mjs           sample calls → registry/glue/testsv2/*.tests.json
  registry/glue/         drop-in PR payload for the registry (glue entity folder)
```

## Covered contract

| Descriptor | Binding | Functions |
|---|---|---|
| `calldata-GlueHook.json` | 14 mainnets (incl. Arc 5042), same address `0x03D4…A040` | launchPool, initPot, addLiquidity, addLiquidityAdvanced, addProgramLiquidity, removeProgramLiquidity, harvest, donate, claim, flushDirect, setProgramConfig, setProgramOperator, setRecipient, transferProgramOwnership |

PoolManager / self-call entrypoints (`beforeInitialize`, `afterSwap`, `unlockCallback`,
`executeHarvest`, `executePump`) are intentionally NOT described: wallets fall back to
their generic "unknown function" screen for them, which is the right signal.

## Scales the descriptors rely on

- ProgramConfig shares are WAD (`1e18 = 100%`) → `unit` with `base: "%"`, `decimals: 16`.
- Uniswap V4 `fee` is hundredths of a bip → `unit` with `base: "%"`, `decimals: 4`.
- `address(0)` = native coin wherever an asset is expected; burn / locked / frozen
  wherever a recipient / owner / operator is expected (spelled in the label).
- Auto-harvest mins: `type(uint256).max` = disarmed (label says `max=off`).
- The pool key's `hooks` field is hidden — it is always this contract.

## Regenerate

```bash
forge build                       # ABI in out/GlueHook.sol/GlueHook.json
node erc7730/build.mjs            # exits non-zero if any parameter lacks an annotation
node erc7730/fixtures.mjs         # rebuilds the reference tests from the fresh descriptor
```

## Validate (Ledger's linter, Python 3.12)

```bash
python3.12 -m venv /tmp/erc7730-venv && /tmp/erc7730-venv/bin/pip install erc7730
git clone --depth 1 https://github.com/ethereum/clear-signing-erc7730-registry /tmp/cs-registry
cp erc7730/registry/glue/calldata-GlueHook.json /tmp/cs-registry/registry/glue/
cp erc7730/registry/glue/testsv2/calldata-GlueHook.tests.json /tmp/cs-registry/registry/glue/testsv2/
/tmp/erc7730-venv/bin/erc7730 lint /tmp/cs-registry/registry/glue/calldata-GlueHook.json
```

Expected result: **0 errors**. Remaining warnings are known and accepted by the
registry maintainers on other entities too:

- "Display intent too long" — only for `interpolatedIntent` strings (>30 chars
  by construction). Every plain `intent` is ≤30 chars and every `label` ≤20.

## Submit

1. Fork the registry, copy `calldata-GlueHook.json` and `testsv2/calldata-GlueHook.tests.json`
   into `registry/glue/` (GlueHook is a Glue contract — same entity folder).
2. `npm ci && npm run generate-index` in the registry root (updates
   `index.calldata.json`).
3. One PR against the `glue` entity. CI runs the same `erc7730 lint`, checks
   Sourcify verification of every deployment and the `testsv2/` fixtures.
4. After merge, request an auditor attestation (`registry/glue/sigs/…`) so
   Ledger devices show the descriptors without the "unverified metadata" flag —
   see `auditors/README.md` in the registry.
