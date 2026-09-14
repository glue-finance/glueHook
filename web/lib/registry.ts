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
import type { Generation, GenerationTag, Net } from "./chains";
import { earliestDeployBlock, hooksOf } from "./chains";
import { clientForNet, scanClientsFor } from "./client";
import { poolIdOf, type PoolKey } from "./hook";
import { findLogsBackward, scanLogs } from "./logs";
import { snapshotFor } from "./snapshot";

export type RegisteredPool = {
  poolId: Hex;
  key: PoolKey | null; // null when recovery failed (pot usable, key-bound ops not)
  admin: Address;
  block: number;
  /** the hook deployment this pool's pot lives on (V1, V2 or the canonical V3) —
   *  every per-pool read and write must target THIS address */
  hook: Address;
};

export type CacheEntry = { key: PoolKey | null; admin: Address; block: number; hook: Address };

// v9: three hook generations (V1 + V2 + V3). v8 caches only watched two
// addresses and could stamp a frontier that skipped V3 PotOpened logs.
export type PoolCache = {
  v: 9;
  /** top of the contiguously scanned range (inclusive); "0" = nothing scanned */
  lastBlock: string;
  /**
   * bottom of the contiguously scanned range (inclusive). Absent = backfilled
   * all the way to the earliest deploy block (every cache written before the
   * staged crawl existed was contiguous from there, so absence reads as done).
   */
  floor?: string;
  pools: Record<string, CacheEntry>;
};
type Cache = PoolCache;

/** One chain's entry in `pools.snapshot.json`. */
export type SnapshotChain = Pick<PoolCache, "lastBlock" | "floor" | "pools">;

/** What a scan is doing right now, for the progress bar. */
export type ScanStage = "tip" | GenerationTag;
export type ScanProgress = { stage: ScanStage; scanned: bigint; total: bigint };
export type ProgressFn = (p: ScanProgress) => void;

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

export function emptyCache(): Cache {
  return { v: 9, lastBlock: "0", pools: {} };
}

/**
 * Fold `src` into `dst`: keep every pool, prefer entries that carry a key,
 * and only ever move the scanned frontier forward.
 */
export function mergeCache(dst: Cache, src: Pick<Cache, "lastBlock" | "floor" | "pools">): boolean {
  let changed = false;
  for (const [id, e] of Object.entries(src.pools ?? {})) {
    const have = dst.pools[id];
    if (!have || (!have.key && e.key)) {
      dst.pools[id] = { ...e };
      changed = true;
    }
  }
  const srcTop = BigInt(src.lastBlock || "0");
  if (srcTop === 0n) return changed;
  const dstEmpty = BigInt(dst.lastBlock) === 0n;
  if (srcTop > BigInt(dst.lastBlock)) {
    dst.lastBlock = src.lastBlock;
    changed = true;
  }
  // scanned ranges: both sides descend from a full crawl or the snapshot, so
  // they overlap and the union is contiguous — take the lower floor. An absent
  // floor means "backfilled to the deploy block", which wins outright.
  if (dstEmpty) {
    if (src.floor) dst.floor = src.floor;
    else delete dst.floor;
    changed = true;
  } else if (dst.floor && (!src.floor || BigInt(src.floor) < BigInt(dst.floor))) {
    if (src.floor) dst.floor = src.floor;
    else delete dst.floor;
    changed = true;
  }
  return changed;
}

/**
 * Baseline for a chain: the pools shipped with the build (`pools.snapshot.json`,
 * regenerated with `npm run pools:snapshot`). Whatever happened after the
 * snapshot's frontier is picked up by the delta scan — which is minutes of
 * blocks, not the whole history since the V1 deploy.
 */
export function seededCache(chainId: number): Cache {
  const c = emptyCache();
  const snap = snapshotFor(chainId);
  if (snap) mergeCache(c, snap);
  return c;
}

function loadCache(chainId: number): Cache {
  const c = seededCache(chainId);
  if (typeof localStorage !== "undefined") {
    try {
      const raw = localStorage.getItem(cacheKey(chainId));
      if (raw) {
        const local = JSON.parse(raw) as Cache;
        if (local.v === 9) mergeCache(c, local);
      }
    } catch {
      /* corrupted cache → snapshot + rescan */
    }
  }
  return c;
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
  budget?: number,
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
      budget,
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

  /**
   * Recover the key of a freshly opened pot. Order matters:
   *  1. the RECEIPT — `launchPool` (and any launcher contract wrapping it)
   *     initializes the pool in the same tx, so the PoolManager `Initialize`
   *     log with this id is right there; works for any calldata shape
   *  2. the CALLDATA — `initPot` on an already-initialized pool carries the
   *     key as its first argument
   *  Anything left is handed to the PoolManager log walk afterwards.
   */
  const recover = async (p: Pending): Promise<PoolKey | null> => {
    try {
      const rec = await client.getTransactionReceipt({ hash: p.hash });
      for (const log of rec.logs) {
        if (log.address.toLowerCase() !== net.poolManager.toLowerCase()) continue;
        if (log.topics[0] !== INITIALIZE_TOPIC0) continue;
        const hit = keyFromInitializeLog(log);
        if (hit && hit.id.toLowerCase() === p.poolId) return hit.key;
      }
    } catch {
      /* fall through */
    }
    try {
      const tx = await client.getTransaction({ hash: p.hash });
      return keyFromCalldata(tx.input, p.poolId);
    } catch {
      return null;
    }
  };

  for (let i = 0; i < pending.length; i += INGEST_BATCH) {
    const batch = pending.slice(i, i + INGEST_BATCH);
    const keys = await Promise.all(batch.map(recover));
    for (let j = 0; j < batch.length; j++) {
      const p = batch[j];
      cache.pools[p.poolId] = { key: keys[j], admin: p.admin, block: p.block, hook: p.hook };
      dirty = true;
    }
    onUpdate?.();
  }
  return dirty;
}

/**
 * Discover every GlueHook pool on a chain and recover each pool's PoolKey.
 *
 * Order is what makes it feel fast:
 *  1. TIP — the blocks since the cached frontier (usually minutes' worth).
 *  2. BACKFILL, newest generation first — V3 pools can only exist after the
 *     V3 deploy block, which is a few windows of history; then V2's segment,
 *     then V1's, each querying only the hooks that existed in that segment.
 *     V3 pools render while V2/V1 are still loading.
 *
 * The scanned range `[floor, lastBlock]` stays contiguous at all times: the
 * tip raises `lastBlock`, the backfill lowers `floor`, and a window that keeps
 * failing stops the crawl where it is rather than skipping blocks.
 */
export async function scanPools(
  net: Net,
  onProgress?: ProgressFn,
  onPartial?: (pools: RegisteredPool[]) => void,
): Promise<RegisteredPool[]> {
  const cache = loadCache(net.chain.id);
  // show what we already know (snapshot + local) before any network call
  const known = listFromCache(cache);
  if (known.length > 0) onPartial?.(known);

  return crawlPools(net, cache, {
    onProgress,
    onPartial,
    persist: () => saveCache(net.chain.id, cache),
  });
}

/**
 * Same crawl for `scripts/snapshot-pools.mts`: no localStorage, it just
 * advances the in-memory cache it is given.
 */
export async function scanPoolsInto(
  net: Net,
  cache: Cache,
  onProgress?: ProgressFn,
): Promise<RegisteredPool[]> {
  // the snapshot run can afford a deep Initialize walk for keys the
  // receipt/calldata paths missed — a browser gets the default 40-request budget
  return crawlPools(net, cache, { onProgress, keyWalkBudget: 400 });
}

/** Hook generations newest → oldest, each with the block it went live. */
function generationsDesc(net: Net): Generation[] {
  const all: Generation[] = [{ tag: "v3", hook: net.hook, deployBlock: net.deployBlock }, ...net.legacy];
  return all.sort((a, b) => b.deployBlock - a.deployBlock);
}

/** Backfill chunk: wide enough for scanLogs to reach its parallel fan-out. */
const BACKFILL_CHUNK_WINDOWS = 16n;

async function crawlPools(
  net: Net,
  cache: Cache,
  opts: {
    onProgress?: ProgressFn;
    onPartial?: (pools: RegisteredPool[]) => void;
    persist?: () => void;
    keyWalkBudget?: number;
  },
): Promise<RegisteredPool[]> {
  const { onProgress, onPartial } = opts;
  const earliest = BigInt(earliestDeployBlock(net));
  const latest = await clientForNet(net).getBlockNumber();
  const cap = BigInt(net.logRange);
  const clients = scanClientsFor(net);

  let dirty = false;
  // never publish an empty list — setQueryData([]) makes React Query drop
  // isLoading while the crawl is still running, which flashes "no pools"
  const notify = () => {
    const list = listFromCache(cache);
    if (list.length > 0) onPartial?.(list);
  };
  const persist = () => {
    if (dirty) opts.persist?.();
  };

  notify();

  // ---- 1. tip: everything since the cached frontier, all hooks -------------
  const top = BigInt(cache.lastBlock);
  if (top < earliest) {
    // nothing scanned yet — open an empty range at the tip; the backfill below
    // grows it downward, newest generation first
    cache.lastBlock = latest.toString();
    cache.floor = (latest + 1n).toString();
    dirty = true;
  } else if (top < latest) {
    const from = top + 1n;
    const hooks = hooksOf(net);
    const gap = latest - from + 1n;
    if (gap > cap) {
      // stale frontier: read the newest window first so a pool launched
      // minutes ago shows before the rest of the gap is walked
      const tip = await scanLogs(clients, {
        address: hooks,
        topics: [POT_OPENED_TOPIC0],
        fromBlock: latest - cap + 1n,
        toBlock: latest,
        maxRange: cap,
      });
      dirty = (await ingestOpenedLogs(net, cache, tip.logs, notify)) || dirty;
      persist();
    }
    const { logs, scannedTo } = await scanLogs(clients, {
      address: hooks,
      topics: [POT_OPENED_TOPIC0],
      fromBlock: from,
      toBlock: latest,
      maxRange: cap,
      onProgress: (scanned, total) => onProgress?.({ stage: "tip", scanned, total }),
    });
    dirty = (await ingestOpenedLogs(net, cache, logs, notify)) || dirty;
    if (scannedTo >= from) {
      cache.lastBlock = scannedTo.toString();
      dirty = true;
    }
    persist();
    notify();
  }

  // ---- 2. backfill: V3 segment, then V2, then V1 ---------------------------
  // Each segment is walked newest → oldest in chunks so `floor` only ever
  // moves down over blocks that were actually read.
  let floor = cache.floor ? BigInt(cache.floor) : earliest;
  const gens = generationsDesc(net);
  let stopped = false;
  for (let i = 0; i < gens.length && !stopped && floor > earliest; i++) {
    const g = gens[i];
    const segFrom = BigInt(g.deployBlock);
    const upper = i === 0 ? latest : BigInt(gens[i - 1].deployBlock) - 1n;
    const segTo = upper < floor - 1n ? upper : floor - 1n;
    if (segFrom > segTo) continue;
    // only hooks that existed somewhere in this segment can have emitted here
    const hooks = gens.filter((x) => BigInt(x.deployBlock) <= segTo).map((x) => x.hook);
    const total = segTo - segFrom + 1n;
    let done = 0n;
    const chunk = cap * BACKFILL_CHUNK_WINDOWS;
    let to = segTo;
    while (to >= segFrom) {
      const from = to - chunk + 1n > segFrom ? to - chunk + 1n : segFrom;
      const { logs, scannedTo } = await scanLogs(clients, {
        address: hooks,
        topics: [POT_OPENED_TOPIC0],
        fromBlock: from,
        toBlock: to,
        maxRange: cap,
        onProgress: (scanned) => onProgress?.({ stage: g.tag, scanned: done + scanned, total }),
      });
      dirty = (await ingestOpenedLogs(net, cache, logs, notify)) || dirty;
      if (scannedTo < to) {
        // the chunk did not complete — keep the frontier above it; the pools
        // it did find are cached already and the rest is retried next time
        stopped = true;
        break;
      }
      floor = from;
      cache.floor = floor.toString();
      done += to - from + 1n;
      dirty = true;
      persist();
      to = from - 1n;
    }
    notify();
  }
  if (cache.floor && floor <= earliest) {
    delete cache.floor;
    dirty = true;
  }
  persist();

  const unresolved: Hex[] = [];
  let newestMiss = BigInt(earliestDeployBlock(net));
  for (const [id, p] of Object.entries(cache.pools)) {
    if (p.key) continue;
    unresolved.push(id as Hex);
    const b = p.block > 0 ? BigInt(p.block) : latest;
    if (b > newestMiss) newestMiss = b;
  }
  if (unresolved.length > 0) {
    const recovered = await keysFromPoolManager(net, unresolved, newestMiss, opts.keyWalkBudget);
    for (const [id, key] of recovered) {
      const entry = cache.pools[id];
      if (entry) {
        entry.key = key;
        dirty = true;
      }
    }
    notify();
  }

  persist();
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
