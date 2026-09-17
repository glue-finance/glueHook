# Legacy generations

GlueHook has shipped three generations. The live one is **V3** at
`0x03D482cB3Ff339C2d29736818D0F72c66dD6A040` (source in [`../contracts`](../contracts)). The two
earlier generations are **still deployed and still work**: nothing was paused, upgraded or
removed. A hook is immutable code at an address; the pools that adopted V1 or V2 keep trading,
their pots keep pumping, and their LP programs keep harvesting exactly as on the day they launched.
Anyone can still initialise new pools on them if they prefer the older mechanics.

This folder is the exact source of each retired generation, so a pool on V1 or V2 can always be
read, audited and integrated against the code it actually runs.

| Generation | Hook | Library (GlueLiquidity) | Bits | Source |
|---|---|---|---|---|
| **V1** | `0xb216070c3509047ea597E2E626A29cea427a60C8` | `0x26CD66aDec6176c11f894A9DE5bC504235c90241` | `0x20C8` | [`v1/`](v1) |
| **V2** | `0x0F41715dc432692b66A5aDF8dCfef6Ac407b20c8` | `0x74EcCF857176CB538AAB1642A972444857f7860F` | `0x20C8` | [`v2/`](v2) |
| **V3** (live) | `0x03D482cB3Ff339C2d29736818D0F72c66dD6A040` | `0x01f739de084e7Cd3554dd4fABA970D346d3DD8Bb` | `0x2040` | [`../contracts`](../contracts) |

Each generation was deployed from a fresh key with plain `CREATE`: library at nonce 0, hook at
nonce 1. That is why one address holds the same code on every network. V3 is bound at compile
time to the Glue Protocol's GlueStick `0xBe99cB426fDf30F95784337d4e8CC460AC8e8608`; V1 ran
standalone.

## Where they live

**V1** — 23 networks. Mainnets: Ethereum, Base, Unichain, Arbitrum, Optimism, BNB Chain, Polygon,
Avalanche, Blast, Celo, Monad, X Layer, World Chain, Zora, Soneium, MegaETH, Robinhood, Tempo.
Testnets: Sepolia, Base Sepolia, Unichain Sepolia, Arbitrum Sepolia, Robinhood Testnet.

**V2** — 18 networks. Mainnets: Ethereum, Base, Unichain, Arbitrum, Optimism, BNB Chain, Polygon,
Avalanche, X Layer, World Chain, Soneium, MegaETH, Robinhood. Testnets: Sepolia, Base Sepolia,
Unichain Sepolia, Arbitrum Sepolia, Robinhood Testnet.

**V3** (live, `0x03D4…A040`) — 19 networks: the 13 mainnets above plus **Arc** (5042), and the same five testnets.

The app at [gluehook.trade](https://gluehook.trade) discovers pools on all three hooks and
talks to each pool through the ABI of the generation it was created on. New pools from the app are always
created on V3.

## What changed between them

The V3 launch write-up, with the exact numbers on how much harder V3 is to play than V1/V2
(20–67× depending on the fee tier): [x.com/glue_fi/status/2100237021264450020](https://x.com/glue_fi/status/2100237021264450020).

| | V1 | V2 | V3 |
|---|---|---|---|
| Pot on buys | pump | pump | pump behind **every** swap, paced by volume and gated on a reference tick |
| Pot on sells | shield (absorbs sells at pool price) | shield | none — `quoteShield` does not exist |
| Hook flags | `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` | same as V1 | `beforeInitialize` + `afterSwap` only: swapper amounts never touched, quotes exact |
| Burns | held on the hook when the token cannot burn | routed through Glue (`IGlueStickMin`) so any glued token burns properly | Glue burns, wrapper-aware |
| Pool fees | static or dynamic | static only | static only |
| LP programs | fee harvest split pot / burn / recipients | same | same + **native programs** that deliver to a registered Glue engine (`recordHarvest`) |
| Binary | `GlueHook` + `DELEGATECALL` library `GlueLiquidity` | same | same |

The interface of each generation is the file to integrate against:
[`v1/contracts/interfaces/IGlueHook.sol`](v1/contracts/interfaces/IGlueHook.sol),
[`v2/contracts/interfaces/IGlueHook.sol`](v2/contracts/interfaces/IGlueHook.sol). V1 and V2 both
expose `quoteShield(key, amountSpecified)` and `quotePump(key, userAmountIn)` for exact swap
previews; V3 only needs `quotePump`.

## Building a legacy tree

Each folder is a self-contained Foundry root that borrows the repo's `lib/` (forge-std,
OpenZeppelin). The compiler profile is the one the generation shipped under — solc 0.8.35,
`prague`, viaIR, optimizer runs = 1, revert strings stripped, no metadata hash:

```sh
cd legacy/v2          # or legacy/v1
forge build
```

The artifact is statically linked against the library sentinel `0xb0B0…0B0B`; substitute the
generation's real library address and the runtime bytecode matches what is on chain, apart from
the two constructor immutables (`poolManager`, and `nativeWrap` from V2 onward). Checked against
Ethereum mainnet for both generations on 2026-09-14.

## Provenance

| Generation | Repository commit | Landed |
|---|---|---|
| V1 | `4526d5b` — *GlueHook — a Uniswap V4 buyback-and-burn hook* | 2026-08-07 |
| V2 | `aaf3502` — *V2: Glue-integrated burns, static-fee-only hook, fresh 18-network deployment* | 2026-08-23 |
| V3 | `9c63347` — *GlueHook v5: GLUE_STICK → 0xBe99…8608* | 2026-09-16 |

The trees here are byte-identical copies of `contracts/` at those commits; only `foundry.toml`
and `remappings.txt` were adjusted to point at `../../lib`.
