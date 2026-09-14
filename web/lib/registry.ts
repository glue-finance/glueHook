import {
  decodeAbiParameters,
  decodeEventLog,
  parseAbiItem,
  slice,
  toEventSelector,
  toFunctionSelector,
  type Address,
  type Hex,
  type Log,
} from "viem";
import type { Net } from "./chains";
import { earliestDeployBlock, hooksOf } from "./chains";
import { clientForNet, scanClientsFor } from "./client";
import { poolIdOf, type PoolKey } from "./hook";
import { findLogsBackward, scanLogs } from "./logs";

export type RegisteredPool = {
  poolId: Hex;
  key: PoolKey | null; // null when recovery failed (pot usable, key-bound ops not)
  admin: Address;
  block: number;
  /** the hook deployment this pool's pot lives on (V1, V2 or the canonical V3) —
   *  every per-pool read and write must target THIS address */
  hook: Address;
};

// v9: three hook generations (V1 + V2 + V3). v8 caches only watched two
// addresses and could stamp a frontier that skipped V3 PotOpened logs.
type Cache = {
  v: 9;
  lastBlock: string;
  pools: Record<string, { key: PoolKey | null; admin: Address; block: number; hook: Address }>;
};

const potOpenedEvent = parseAbiItem(
  "event PotOpened(bytes32 indexed poolId, address indexed admin)",
);
const pmInitializeEvent = parseAbiItem(
  "event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)",
);

const INIT_POT_SELECTOR = toFunctionSelector(
  "initPot((address,address,uint24,int24,address),address,address)",
);
const LAUNCH_POOL_SELECTOR = toFunctionSelector(
  "launchPool((address,address,uint24,int24,address),uint160,address,address,int24,int24,uint128,address,(uint64,uint64,uint64,uint64,uint64,bool,address,address,uint256,uint256))",
);

/**
 * Uniswap v4 dynamic-fee sentinel (LPFeeLibrary.DYNAMIC_FEE_FLAG). GlueHook
 * serves static-fee pools only, so these never surface in the picker.
 */
const DYNAMIC_FEE_FLAG = 0x800000;
const isDynamicFeeKey = (key: PoolKey | null): boolean =>
  key !== null && (Number(key.fee) & DYNAMIC_FEE_FLAG) !== 0;

const cacheKey = (chainId: number) => `gh.pools.${chainId}`;

function loadCache(chainId: number): Cache {
  if (typeof localStorage !== "undefined") {
    try {
      const raw = localStorage.getItem(cacheKey(chainId));
      if (raw) {
        const c = JSON.parse(raw) as Cache;
        if (c.v === 9) return c;
      }
    } catch {
      /* corrupted cache → rescan */
    }
  }
  return { v: 9, lastBlock: "0", pools: {} };
}

function saveCache(chainId: number, c: Cache) {
  if (typeof localStorage !== "undefined") {
    try {
      localStorage.setItem(cacheKey(chainId), JSON.stringify(c));
    } catch {
      /* quota — non-fatal */
    }
  }
}

const POOL_KEY_TUPLE = {
  type: "tuple",
  components: [
    { type: "address", name: "currency0" },
    { type: "address", name: "currency1" },
    { type: "uint24", name: "fee" },
    { type: "int24", name: "tickSpacing" },
    { type: "address", name: "hooks" },
  ],
} as const;

/**
 * Recover the PoolKey from the calldata of the transaction that opened the
 * pot. Two shapes are tried, and BOTH are verified by hashing the candidate
 * back to the poolId, so a wrong guess can never poison the registry.
 */
function keyFromCalldata(data: Hex, poolId: Hex): PoolKey | null {
  const id = poolId.toLowerCase();
  const heads: Hex[] = [];
  if (data.length >= 2 + 8 + 320) heads.push(slice(data, 4, 4 + 160));
  for (const sel of [INIT_POT_SELECTOR, LAUNCH_POOL_SELECTOR]) {
    const idx = data.indexOf(sel.slice(2));
    if (idx >= 2 && (idx - 2) % 2 === 0) {
      const at = (idx - 2) / 2 + 4;
      if (data.length >= 2 + at * 2 + 320) heads.push(slice(data, at, at + 160));
    }
  }
  for (const head of heads) {
    try {
      const [key] = decodeAbiParameters([POOL_KEY_TUPLE], head);
      const k = key as PoolKey;
      if (poolIdOf(k).toLowerCase() === id) return k;
    } catch {
      /* not this shape */
    }
  }
  return null;
}

const POT_OPENED_TOPIC0 = toEventSelector(potOpenedEvent);
const INITIALIZE_TOPIC0 = toEventSelector(pmInitializeEvent);

function keyFromInitializeLog(log: Log): { id: Hex; key: PoolKey } | null {
  try {
    const { args } = decodeEventLog({
      abi: [pmInitializeEvent],
      topics: log.topics as [Hex, ...Hex[]],
      data: log.data,
    });
    const a = args as unknown as {
      id: Hex;
      currency0: Address;
      currency1: Address;
      fee: number;
      tickSpacing: number;
      hooks: Address;
    };
    const key: PoolKey = {
      currency0: a.currency0,
      currency1: a.currency1,
      fee: Number(a.fee),
      tickSpacing: Number(a.tickSpacing),
      hooks: a.hooks,
    };
    return poolIdOf(key).toLowerCase() === a.id.toLowerCase() ? { id: a.id, key } : null;
  } catch {
    return null;
  }
}

async function keysFromPoolManager(
  net: Net,
  ids: Hex[],
  toBlock: bigint,
): Promise<Map<string, PoolKey>> {
  const found = new Map<string, PoolKey>();
  if (ids.length === 0) return found;
  try {
    const logs = await findLogsBackward(scanClientsFor(net), {
      address: net.poolManager,
      topics: [INITIALIZE_TOPIC0, ids.map((i) => i.toLowerCase() as Hex)],
      fromBlock: BigInt(earliestDeployBlock(net)),
      toBlock,
      maxRange: BigInt(net.logRange),
      done: (ls) => ls.length >= ids.length,
    });
    for (const log of logs) {
      const hit = keyFromInitializeLog(log);
      if (hit) found.set(hit.id.toLowerCase(), hit.key);
    }
  } catch (e) {
    console.warn(`[registry] PoolKey recovery failed for ${ids.length} pool(s):`, e);
  }
  return found;
}

function listFromCache(cache: Cache): RegisteredPool[] {
  return Object.entries(cache.pools)
    .filter(([, p]) => !isDynamicFeeKey(p.key))
    .map(([poolId, p]) => ({
      poolId: poolId as Hex,
      ...p,
    }));
}

const INGEST_BATCH = 4;

async function ingestOpenedLogs(
  net: Net,
  cache: Cache,
  logs: Log[],
  onUpdate?: () => void,
): Promise<boolean> {
  const client = clientForNet(net);
  let dirty = false;
  type Pending = { poolId: Hex; admin: Address; block: number; hook: Address; hash: Hex };
  const pending: Pending[] = [];

  for (const log of logs) {
    let poolId: Hex;
    let admin: Address;
    try {
      const { args } = decodeEventLog({
        abi: [potOpenedEvent],
        topics: log.topics as [Hex, ...Hex[]],
        data: log.data,
      });
      ({ poolId, admin } = args as unknown as { poolId: Hex; admin: Address });
    } catch {
      continue;
    }
    if (!poolId || !log.transactionHash) continue;
    const id = poolId.toLowerCase() as Hex;
    // already fully recovered (e.g. tip window overlapping the historical crawl)
    if (cache.pools[id]?.key) continue;
    pending.push({
      poolId: id,
      admin,
      block: Number(log.blockNumber ?? 0n),
      hook: log.address as Address,
      hash: log.transactionHash,
    });
  }

  for (let i = 0; i < pending.length; i += INGEST_BATCH) {
    const batch = pending.slice(i, i + INGEST_BATCH);
    const txs = await Promise.all(
      batch.map((p) => client.getTransaction({ hash: p.hash }).catch(() => null)),
    );
    for (let j = 0; j < batch.length; j++) {
      const p = batch[j];
      const tx = txs[j];
      cache.pools[p.poolId] = {
        key: tx ? keyFromCalldata(tx.input, p.poolId) : null,
        admin: p.admin,
        block: p.block,
        hook: p.hook,
      };
      dirty = true;
    }
    onUpdate?.();
  }
  return dirty;
}

/**
 * Scan PotOpened logs across every hook generation from the earliest deploy
 * block (or the cached frontier), and recover each pool's PoolKey.
 *
 * When the backlog is wider than one RPC window the recent tip is scanned
 * FIRST so a pool launched a few minutes ago shows up before the historical
 * crawl finishes. The frontier still only advances contiguously.
 */
export async function scanPools(
  net: Net,
  onProgress?: (scanned: bigint, total: bigint) => void,
  onPartial?: (pools: RegisteredPool[]) => void,
): Promise<RegisteredPool[]> {
  const cache = loadCache(net.chain.id);
  const earliest = earliestDeployBlock(net);
  const from =
    BigInt(cache.lastBlock) > BigInt(earliest) ? BigInt(cache.lastBlock) + 1n : BigInt(earliest);
  const latest = await clientForNet(net).getBlockNumber();
  const hooks = hooksOf(net);
  const cap = BigInt(net.logRange);

  let dirty = false;
  // never publish an empty list — setQueryData([]) makes React Query drop
  // isLoading while the crawl is still running, which flashes "no pools"
  const notify = () => {
    const list = listFromCache(cache);
    if (list.length > 0) onPartial?.(list);
  };
  const persist = () => {
    if (dirty) saveCache(net.chain.id, cache);
  };

  notify();

  if (from <= latest) {
    const gap = latest - from + 1n;
    if (gap > cap) {
      const tipFrom = latest - cap + 1n;
      const tip = await scanLogs(scanClientsFor(net), {
        address: hooks,
        topics: [POT_OPENED_TOPIC0],
        fromBlock: tipFrom,
        toBlock: latest,
        maxRange: cap,
      });
      dirty = (await ingestOpenedLogs(net, cache, tip.logs, notify)) || dirty;
      persist();
    }

    const { logs, scannedTo } = await scanLogs(scanClientsFor(net), {
      address: hooks,
      topics: [POT_OPENED_TOPIC0],
      fromBlock: from,
      toBlock: latest,
      maxRange: cap,
      onProgress,
    });
    dirty = (await ingestOpenedLogs(net, cache, logs, notify)) || dirty;
    if (scannedTo >= from) {
      cache.lastBlock = scannedTo.toString();
      dirty = true;
    }
    persist();
    notify();
  }

  const unresolved: Hex[] = [];
  let newestMiss = BigInt(earliestDeployBlock(net));
  for (const [id, p] of Object.entries(cache.pools)) {
    if (p.key) continue;
    unresolved.push(id as Hex);
    const b = p.block > 0 ? BigInt(p.block) : latest;
    if (b > newestMiss) newestMiss = b;
  }
  if (unresolved.length > 0) {
    const recovered = await keysFromPoolManager(net, unresolved, newestMiss);
    for (const [id, key] of recovered) {
      const entry = cache.pools[id];
      if (entry) {
        entry.key = key;
        dirty = true;
      }
    }
    notify();
  }

  if (dirty) saveCache(net.chain.id, cache);
  return listFromCache(cache);
}

export function registerPool(net: Net, key: PoolKey, admin: Address, block: number): RegisteredPool {
  const poolId = poolIdOf(key).toLowerCase() as Hex;
  const cache = loadCache(net.chain.id);
  const entry = { key, admin, block, hook: key.hooks as Address };
  cache.pools[poolId] = entry;
  saveCache(net.chain.id, cache);
  return { poolId, ...entry };
}

export async function importPool(net: Net, poolId: Hex): Promise<RegisteredPool | null> {
  const id = poolId.toLowerCase() as Hex;
  const cache = loadCache(net.chain.id);
  const hit = cache.pools[id];
  if (hit?.key) return isDynamicFeeKey(hit.key) ? null : { poolId: id, ...hit };

  const latest = await clientForNet(net).getBlockNumber();
  const key = (await keysFromPoolManager(net, [id], latest)).get(id);
  if (key && isDynamicFeeKey(key)) return null;
  if (!key) return hit ? { poolId: id, ...hit } : null;
  const entry = {
    key,
    admin: (hit?.admin ?? "0x0000000000000000000000000000000000000000") as Address,
    block: hit?.block ?? net.deployBlock,
    hook: key.hooks as Address,
  };
  cache.pools[id] = entry;
  saveCache(net.chain.id, cache);
  return { poolId: id, ...entry };
}
