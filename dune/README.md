# Dune — GlueHook live dashboard

Dashboard: [dune.com/lalilulel0x0869/gluehook-live](https://dune.com/lalilulel0x0869/gluehook-live) (id `217819`).

`queries/` is the versioned SQL of every saved query on the dashboard. Each file is exactly what is
saved on Dune; edit here, then push back (see below).

| Query | File | What |
| --- | --- | --- |
| 8263572 | `8263572-pump-volume.sql` | `Pumped` events per pool (raw logs, `topic1` = poolId, spent/bought from `data`) |
| 8263573 | `8263573-daily-volume.sql` | swap volume USD, daily + cumulative (`uniswap_v4_*.base_trades` joined to `dex.trades`) |
| 8263574 | `8263574-leaderboard.sql` | volume leaderboard by chain / pair |
| 8263575 | `8263575-tvl-by-chain.sql` | pools' active-liquidity TVL over time, by chain |
| 8263576 | `8263576-tvl.sql` | TVL now / 7d / 30d counters |
| 8263914 | `8263914-volume-windows.sql` | volume 24h / 30d / lifetime counters |

## Hook filters

Every query matches every live hook address at once, and prunes each chain from the block V1
landed there (the earliest hook on that chain):

```
hooks / contract_address IN (
  0xb216070c3509047ea597e2e626a29cea427a60c8,   -- V1
  0x0f41715dc432692b66a5adf8dcfef6ac407b20c8,   -- V2
  0xbb021554c5294328b04fa313669715bd201ba040,   -- V3, superseded campaign-4 build
  0x03d482cb3ff339c2d29736818d0f72c66dd6a040    -- V3 (canonical)
)
AND block_number >= <V1 hookBlock on that chain>
AND block_date >= DATE '2026-06-01'
```

Dune covers 10 of the 14 mainnets with Uniswap v4 spells (no MegaETH, X Layer, Soneium yet). **Arc** has raw tables (`arc.logs`, `arc.transactions`, …) but no `uniswap_v4_arc` spells yet, so it is in the raw-log **pump-volume** query only (from the V3 hook block 21132279); add it to the volume/TVL queries the day `uniswap_v4_arc.base_trades` / `PoolManager_evt_*` appear. Volume is indexed from
Uniswap v4 call traces, so it is exact for every generation (V1/V2 carried swap-delta flags; V3
does not).

## Sync

`scripts/dune-sync.mjs` (ops tooling, gitignored) pulls each query over the Dune API, applies the
generation patch, writes `queries/`, `PATCH`es the SQL and description back, and asks for a fresh
execution. It reads the API key from `.deploy/secrets.json.duneKey`.

```bash
node scripts/dune-sync.mjs --pull   # refresh queries/ from Dune, no write-back
node scripts/dune-sync.mjs          # patch + push + execute
```

On the free plan `POST /query/{id}/execute` is refused by the datapoint quota; the dashboard
re-runs stale queries itself when someone opens it. If `PATCH` is ever refused, paste the file's
SQL into the query editor by hand — the files here are always the source of truth.
