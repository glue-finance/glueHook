# GlueHook — website

The GlueHook site: landing page, live app (on-chain charts + LP management), simulator, and docs.

- **Stack:** Next.js (App Router) + TypeScript + Tailwind v4 + wagmi/viem + RainbowKit.
- **No backend:** all live data comes from public RPCs (`eth_getLogs` + view calls); scanned logs are cached in `localStorage`.
- **Charts:** hand-rolled SVG (`components/app/LineChart.tsx`).
- **Chains:** the 18 deployed networks live in `lib/chains.ts` (per-chain RPC overridable with `NEXT_PUBLIC_RPC_<chainId>`).
- **Generations:** V3 (`0xbB02…A040`) is canonical — new pools, the app's create flow, Glue engines. V2 (`0x0F41…20c8`) and V1 (`0xb216…60C8`) stay served as legacy; reads and writes route through each pool's own `key.hooks`.
- **ABI:** `lib/abi.v3.ts` is generated from the Foundry artifact (`out/GlueHook.sol/GlueHook.json`) via `npm run abi`. V1/V2 share `lib/abi.v2.ts`. Call `abiFor(hook)` at a pool's own address.

## Develop

```bash
npm install
npm run dev
```

Regenerate the V3 ABI after a contracts build:

```bash
npm run abi
```

## Deploy

Vercel project with **Root Directory = `web`**, framework Next.js. Optional env:

- `NEXT_PUBLIC_WALLETCONNECT_ID` — WalletConnect Cloud project id (wallet modal).
- `NEXT_PUBLIC_RPC_<chainId>` — override the default public RPC for a chain.
