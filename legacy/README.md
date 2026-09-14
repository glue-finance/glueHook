# Legacy generations

GlueHook has shipped three generations. The live one is **V3** at
`0xbB021554C5294328b04fa313669715bD201BA040` (source in [`../contracts`](../contracts)). The two
earlier generations are **still deployed and still work**: nothing was paused, upgraded or
removed. A hook is immutable code at an address; the pools that adopted V1 or V2 keep trading,
their pots keep pumping, and their LP programs keep harvesting exactly as on the day they launched.
Anyone can still initialise new pools on them if they prefer the older mechanics.

This folder is the exact source of each retired generation, so a pool on V1 or V2 can always be
read, audited and integrated against the code it actually runs.

| Generation | Hook | Library (GlueLiquidity) | GlueStick | Bits | Source |
|---|---|---|---|---|---|
| **V1** | `0xb216070c3509047ea597E2E626A29cea427a60C8` | `0x26CD66aDec6176c11f894A9DE5bC504235c90241` | — (standalone) | `0x20C8` | [`v1/`](v1) |
| **V2** | `0x0F41715dc432692b66A5aDF8dCfef6Ac407b20c8` | `0x74EcCF857176CB538AAB1642A972444857f7860F` | `0xdac0cbf141E6270C5De6Dd2d6532992562810b38` | `0x20C8` | [`v2/`](v2) |
| **V3** (live) | `0xbB021554C5294328b04fa313669715bD201BA040` | `0xFAc051590a9F2c2AC4838c88F5754591Df194bc5` | `0x32b926e7D6ac6B92e50dF40dDfd3555691bc8b3b` | `0x2040` | [`../contracts`](../contracts) |

Each generation was deployed from a fresh key with plain `CREATE`: library at nonce 0, hook at
nonce 1. That is why one address holds the same code on every network.

## Where they live

**V1** — 23 networks. Mainnets: Ethereum, Base, Unichain, Arbitrum, Optimism, BNB Chain, Polygon,
Avalanche, Blast, Celo, Monad, X Layer, World Chain, Zora, Soneium, MegaETH, Robinhood, Tempo.
Testnets: Sepolia, Base Sepolia, Unichain Sepolia, Arbitrum Sepolia, Robinhood Testnet.

**V2** — 18 networks. Mainnets: Ethereum, Base, Unichain, Arbitrum, Optimism, BNB Chain, Polygon,
Avalanche, X Layer, World Chain, Soneium, MegaETH, Robinhood. Testnets: Sepolia, Base Sepolia,
Unichain Sepolia, Arbitrum Sepolia, Robinhood Testnet.

The app at [gluehook.trade](https://gluehook.trade) discovers pools on all three hooks and talks to
each pool through the ABI of the generation it was created on. New pools from the app are always
created on V3.

## What changed between them

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
| V3 | `19a731c` — *V3: the live generation* | 2026-09-13 |

The trees here are byte-identical copies of `contracts/` at those commits; only `foundry.toml`
and `remappings.txt` were adjusted to point at `../../lib`.
