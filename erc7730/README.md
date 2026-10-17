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
- `address(0)` = native coin wherever an asset is expected. On a fee recipient
  it means no remainder, and the contract accepts it only when that side's
  shares already sum to 100% (`Fee → main (0=none)`, `Fee → 2nd (0=none)`). On an owner it locks the
  liquidity and forces public harvest (`Owner (0=lock+public)`), except
  `addLiquidity`, where a zero owner reverts. On the operator it freezes edits.
- `donate` debits the pot's stored secondary. That token is not in the
  calldata, so the amount is raw base units. Attached value still shows the
  native leg.
- `(0, 0)` ticks are the full-range sentinel. Adding or removing program
  liquidity harvests through the stored split first. Liquidity is pool units;
  the attached native value is a cap (`Max native sent`), and the ERC-20 leg
  is whatever the pool charges for those units.
- Auto-harvest mins: `type(uint256).max` = disarmed (`off` when the token is
  in the calldata, otherwise the label says `max=off`).
- The pool key's `hooks` field is `visible: "never"` — it is always this contract.

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

- "Display intent too long" — `interpolatedIntent` strings that embed both
  token paths run past 30 characters. Every plain `intent` is ≤30 chars.
- "Display label too long" — a few labels name a sentinel the calldata cannot
  compute (`Donation (pot 2nd token, raw)`, `Owner (0=lock+public)`,
  `Lower tick (0,0=full)`). Length is a warning; the wording is the review.

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
