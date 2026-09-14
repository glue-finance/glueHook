"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useState } from "react";
import { erc20Abi, zeroAddress, type Address, type Hex } from "viem";
import type { Net } from "./chains";
import { clientForNet } from "./client";
import { fetchPoolEvents, resolveTimestamps, type PoolEvent } from "./events";
import { abiFor, asPotView, asProgramView, isNative, type PoolKey, type Pot, type Program } from "./hook";
import { isCanonicalHook } from "./chains";
import { importPool, scanPools, type RegisteredPool } from "./registry";

// ---------------------------------------------------------------------------
// Pool registry
// ---------------------------------------------------------------------------

export function usePoolList(net: Net) {
  const [progress, setProgress] = useState<number | null>(null);
  const qc = useQueryClient();
  useEffect(() => {
    setProgress(null);
  }, [net.chain.id]);
  const q = useQuery({
    queryKey: ["pools", net.chain.id],
    queryFn: async () => {
      setProgress(null);
      const pools = await scanPools(
        net,
        // leave the last percent for ingest so the bar doesn't read "done"
        // while getTransaction is still resolving each PotOpened log
        (scanned, total) => setProgress(Math.min(99, Number((scanned * 99n) / total))),
        (partial) => {
          if (partial.length > 0) {
            qc.setQueryData<RegisteredPool[]>(["pools", net.chain.id], partial);
          }
        },
      );
      setProgress(null);
      return pools;
    },
    staleTime: 60_000,
    retry: 1,
  });
  const importById = useCallback(
    async (poolId: Hex): Promise<RegisteredPool | null> => {
      const p = await importPool(net, poolId);
      if (p) qc.invalidateQueries({ queryKey: ["pools", net.chain.id] });
      return p;
    },
    [net, qc],
  );
  return { ...q, progress, importById };
}

// ---------------------------------------------------------------------------
// Live pot + program state
// ---------------------------------------------------------------------------

export function usePot(net: Net, poolId: Hex | null, hook?: Address) {
  const at = hook ?? net.hook; // a V1 pool's pot lives on the V1 hook
  return useQuery({
    queryKey: ["pot", net.chain.id, poolId, at],
    enabled: !!poolId,
    refetchInterval: 12_000,
    queryFn: async (): Promise<Pot> => {
      const client = clientForNet(net);
      return asPotView(
        (await client.readContract({
          address: at,
          abi: abiFor(at),
          functionName: "potOf",
          args: [poolId!],
        })) as Parameters<typeof asPotView>[0],
      );
    },
  });
}

export function useProgram(net: Net, poolId: Hex | null, hook?: Address) {
  const at = hook ?? net.hook; // a V1 pool's program lives on the V1 hook
  return useQuery({
    queryKey: ["program", net.chain.id, poolId, at],
    enabled: !!poolId,
    refetchInterval: 12_000,
    queryFn: async (): Promise<Program> => {
      const client = clientForNet(net);
      return asProgramView(
        (await client.readContract({
          address: at,
          abi: abiFor(at),
          functionName: "programOf",
          args: [poolId!],
        })) as Parameters<typeof asProgramView>[0],
      );
    },
  });
}

// ---------------------------------------------------------------------------
// Quotes (attack / defense curves)
// ---------------------------------------------------------------------------

/**
 * The pot's attack curve, quoted by the hook's own views.
 * UNITS: `quotePump` speaks SECONDARY on both axes (the carrying buy's
 * input and the pot's spend). V1/V2 also expose `quoteShield` (MAIN units);
 * V3 dropped the shield — the same probes return an empty defense curve.
 */
export function useQuoteCurves(
  net: Net,
  key: PoolKey | null,
  potBalance: bigint | undefined,
  sqrtPriceX96: bigint | undefined,
  mainIs0: boolean,
) {
  return useQuery({
    queryKey: [
      "quotes",
      net.chain.id,
      key ? JSON.stringify(key) : null,
      potBalance?.toString(),
      sqrtPriceX96?.toString(),
      mainIs0,
    ],
    enabled: !!key && potBalance !== undefined && potBalance > 0n && !!sqrtPriceX96,
    staleTime: 30_000,
    queryFn: async () => {
      const client = clientForNet(net);
      const bal = potBalance!;
      const steps = [1n, 2n, 5n, 10n, 25n, 50n, 100n, 250n, 500n];
      const at = key!.hooks as Address;
      const abi = abiFor(at);

      const pumpSizes = steps.map((m) => (bal * m) / 100n);

      const pump = await Promise.all(
        pumpSizes.map(async (s) => {
          try {
            const [spend, out] = (await client.readContract({
              address: at,
              abi,
              functionName: "quotePump",
              args: [key!, s],
            })) as [bigint, bigint];
            return { size: s, spend, out };
          } catch {
            return { size: s, spend: 0n, out: 0n };
          }
        }),
      );

      if (isCanonicalHook(at)) {
        return { pump, shield: [] as { size: bigint; absorbed: bigint; paid: bigint }[] };
      }

      const r = Number(sqrtPriceX96!) / 2 ** 96;
      const rawMainPerRawSec = mainIs0 ? 1 / (r * r) : r * r;
      const shieldSizes = pumpSizes.map((s) => {
        const v = Number(s) * rawMainPerRawSec;
        return isFinite(v) && v >= 1 ? BigInt(Math.round(v)) : 1n;
      });
      const shield = await Promise.all(
        shieldSizes.map(async (s) => {
          try {
            const [absorbed, paid] = (await client.readContract({
              address: at,
              abi,
              functionName: "quoteShield",
              args: [key!, -s],
            })) as [bigint, bigint];
            return { size: s, absorbed, paid };
          } catch {
            return { size: s, absorbed: 0n, paid: 0n };
          }
        }),
      );
      return { pump, shield };
    },
  });
}

export function usePumpShare(net: Net, poolId: Hex | null, hook?: Address) {
  const at = hook ?? net.hook;
  return useQuery({
    queryKey: ["pumpShare", net.chain.id, poolId, at],
    enabled: !!poolId && isCanonicalHook(at),
    refetchInterval: 12_000,
    queryFn: async () => {
      const client = clientForNet(net);
      const [shareWad, spotTick, referenceTick] = (await client.readContract({
        address: at,
        abi: abiFor(at),
        functionName: "pumpShareOf",
        args: [poolId!],
      })) as [bigint, number, number];
      return { shareWad, spotTick, referenceTick };
    },
  });
}

export function useDeliveredCum(net: Net, poolId: Hex | null, asset: Address | undefined, hook?: Address) {
  const at = hook ?? net.hook;
  return useQuery({
    queryKey: ["deliveredCum", net.chain.id, poolId, asset, at],
    enabled: !!poolId && !!asset && isCanonicalHook(at),
    refetchInterval: 12_000,
    queryFn: async () => {
      const client = clientForNet(net);
      return (await client.readContract({
        address: at,
        abi: abiFor(at),
        functionName: "deliveredCumOf",
        args: [poolId!, asset!],
      })) as bigint;
    },
  });
}

// ---------------------------------------------------------------------------
// Event feed with incremental polling
// ---------------------------------------------------------------------------

export function useFeed(net: Net, pool: RegisteredPool | null) {
  const [events, setEvents] = useState<PoolEvent[]>([]);
  const [loading, setLoading] = useState(false);
  const [progress, setProgress] = useState<number | null>(null);

  useEffect(() => {
    if (!pool) {
      setEvents([]);
      return;
    }
    let dead = false;
    let inFlight = false;
    setLoading(true);

    async function pull(first: boolean) {
      // on a slow chain the initial scan can outlive several poll ticks —
      // overlapping scans would re-fetch the same ranges and hammer the RPC
      if (inFlight) return;
      inFlight = true;
      try {
        const evs = await fetchPoolEvents(
          net,
          pool!.hook, // the pool's own deployment — V1 events live on V1
          pool!.poolId,
          pool!.block,
          first
            ? (s, t) => setProgress(Math.min(100, Number((s * 100n) / t)))
            : undefined,
        );
        const stamped = await resolveTimestamps(net, pool!.poolId, evs);
        if (!dead) {
          setEvents([...stamped]);
          setProgress(null);
        }
      } catch {
        /* transient RPC failure — next poll retries */
      } finally {
        inFlight = false;
      }
      if (!dead && first) setLoading(false);
    }

    pull(true);
    const id = setInterval(() => pull(false), 6000);
    return () => {
      dead = true;
      clearInterval(id);
    };
  }, [net, pool]);

  return { events, loading, progress };
}

// ---------------------------------------------------------------------------
// Token metadata
// ---------------------------------------------------------------------------

export type TokenMeta = { symbol: string; decimals: number };

export function useTokenMeta(net: Net, addr: Address | null | undefined) {
  return useQuery({
    queryKey: ["token", net.chain.id, addr],
    enabled: !!addr,
    staleTime: Infinity,
    queryFn: async (): Promise<TokenMeta> => {
      if (!addr || isNative(addr))
        return {
          symbol: net.chain.nativeCurrency.symbol,
          decimals: net.chain.nativeCurrency.decimals,
        };
      const client = clientForNet(net);
      try {
        const [symbol, decimals] = await Promise.all([
          client.readContract({ address: addr, abi: erc20Abi, functionName: "symbol" }),
          client.readContract({ address: addr, abi: erc20Abi, functionName: "decimals" }),
        ]);
        return { symbol: symbol as string, decimals: Number(decimals) };
      } catch {
        return { symbol: addr.slice(0, 6), decimals: 18 };
      }
    },
  });
}

export { zeroAddress };
