/**
 * Regenerate lib/pools.snapshot.json — every GlueHook pool (V1/V2/V3) on every
 * deployed network, plus the block each chain was scanned to.
 *
 *   npm run pools:snapshot            # all networks
 *   npm run pools:snapshot -- base    # one or more slugs
 *
 * The app ships this file: browsers start from it and only scan the delta
 * since `lastBlock`, so run it (and commit) after launching pools or when the
 * snapshot is more than a few days old.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { NETS } from "../lib/chains";
import { scanPoolsInto, seededCache, type PoolCache } from "../lib/registry";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "..", "lib", "pools.snapshot.json");

type Snapshot = {
  generatedAt: string;
  chains: Record<string, { lastBlock: string; floor?: string; pools: PoolCache["pools"] }>;
};

const only = process.argv.slice(2).map((s) => s.toLowerCase());
const targets = only.length ? NETS.filter((n) => only.includes(n.slug)) : NETS;
if (targets.length === 0) {
  console.error(`no network matches ${only.join(", ")}`);
  process.exit(1);
}

const prev: Snapshot = JSON.parse(readFileSync(OUT, "utf8"));
const next: Snapshot = { generatedAt: new Date().toISOString(), chains: { ...prev.chains } };

const results = await Promise.allSettled(
  targets.map(async (net) => {
    const cache = seededCache(net.chain.id);
    const from = cache.lastBlock;
    const t0 = Date.now();
    let lastPct = -1;
    let lastStage = "";
    const pools = await scanPoolsInto(net, cache, ({ stage, scanned, total }) => {
      const pct = total > 0n ? Number((scanned * 100n) / total) : 100;
      if (stage !== lastStage) {
        lastStage = stage;
        lastPct = -1;
      }
      if (pct >= lastPct + 10 || pct === 100) {
        lastPct = pct;
        console.log(`  ${net.slug}: ${stage} ${pct}% (${scanned}/${total} blocks)`);
      }
    });
    const missing = pools.filter((p) => !p.key).length;
    const partial = cache.floor ? `  ⚠ backfill stopped at ${cache.floor}` : "";
    console.log(
      `${net.slug.padEnd(18)} ${String(pools.length).padStart(3)} pools` +
        `${missing ? ` (${missing} without key)` : ""}  ${from} → ${cache.lastBlock}  ${((Date.now() - t0) / 1000).toFixed(1)}s${partial}`,
    );
    const entry: Snapshot["chains"][string] = { lastBlock: cache.lastBlock, pools: cache.pools };
    if (cache.floor) entry.floor = cache.floor;
    next.chains[String(net.chain.id)] = entry;
  }),
);

for (let i = 0; i < results.length; i++) {
  const r = results[i];
  if (r.status === "rejected") console.error(`${targets[i].slug}: ${r.reason?.message ?? r.reason}`);
}

// stable key order → small, reviewable diffs
const ordered: Snapshot = { generatedAt: next.generatedAt, chains: {} };
for (const id of Object.keys(next.chains).sort((a, b) => Number(a) - Number(b))) {
  const c = next.chains[id];
  const pools: PoolCache["pools"] = {};
  for (const pid of Object.keys(c.pools).sort()) pools[pid] = c.pools[pid];
  ordered.chains[id] = c.floor ? { lastBlock: c.lastBlock, floor: c.floor, pools } : { lastBlock: c.lastBlock, pools };
}
writeFileSync(OUT, `${JSON.stringify(ordered, null, 2)}\n`);
console.log(`wrote ${OUT}`);
process.exit(results.some((r) => r.status === "rejected") ? 1 : 0);
