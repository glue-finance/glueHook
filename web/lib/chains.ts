import { defineChain, type Chain } from "viem";
import {
  arbitrum,
  arbitrumSepolia,
  avalanche,
  base,
  baseSepolia,
  bsc,
  mainnet,
  optimism,
  polygon,
  sepolia,
  soneium,
  unichain,
  unichainSepolia,
  worldchain,
  xLayer,
} from "viem/chains";

// ---------------------------------------------------------------------------
// Chains without a viem definition
// ---------------------------------------------------------------------------

/** canonical Multicall3 — verified deployed on every custom chain below */
const MULTICALL3 = {
  multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" as const },
};

export const megaeth = defineChain({
  id: 4326,
  name: "MegaETH",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.megaeth.com/rpc"] } },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://megaeth.blockscout.com" },
  },
  contracts: MULTICALL3,
});

export const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.chain.robinhood.com"] } },
  blockExplorers: {
    default: { name: "Robinscan", url: "https://robinscan.io" },
  },
  contracts: MULTICALL3,
});

/**
 * Arc — Circle's USDC-gas L1. The gas coin is USDC itself (18 decimals at the value level; its
 * 6-decimal ERC-20 face is predeployed at 0x3600…0000). There is no WETH9 on Arc, so the hook's
 * NATIVEWRAP there is that face. ~0.5 s blocks, instant finality.
 */
export const arc = defineChain({
  id: 5042,
  name: "Arc",
  nativeCurrency: { name: "USD Coin", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.arc.io"] } },
  blockExplorers: {
    default: { name: "Arc Explorer", url: "https://explorer.arc.io" },
  },
  contracts: MULTICALL3,
});

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: "Robinhood Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.testnet.chain.robinhood.com"] } },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://explorer.testnet.chain.robinhood.com" },
  },
  contracts: MULTICALL3,
  testnet: true,
});

// ---------------------------------------------------------------------------
// Registry — one entry per deployed network
// ---------------------------------------------------------------------------

export const CANONICAL_HOOK = "0x03D482cB3Ff339C2d29736818D0F72c66dD6A040" as const;
export const CANONICAL_LIB = "0x01f739de084e7Cd3554dd4fABA970D346d3DD8Bb" as const;

/**
 * The superseded V3 build (bound to the Glue campaign-4 Stick): byte-identical source except
 * `GLUE_STICK`, same ABI, still deployed and served — discovery, reads and writes all work —
 * but new pools never land on it. Permission bits 0x2040. Pending V3 on the testnets, it is
 * still the hook the testnet registry creates pools on.
 */
export const V3_CAMPAIGN4_HOOK = "0xbB021554C5294328b04fa313669715bD201BA040" as const;

/** Live V2 — still served, no new pools. Permission bits 0x20C8. */
export const V2_HOOK = "0x0F41715dc432692b66A5aDF8dCfef6Ac407b20c8" as const;
/** Live V1 — still served, no new pools. Permission bits 0x20C8. */
export const V1_HOOK = "0xb216070c3509047ea597E2E626A29cea427a60C8" as const;

export type GenerationTag = "v1" | "v2" | "v3";
export type Generation = {
  tag: GenerationTag;
  hook: `0x${string}`;
  deployBlock: number;
};

export type Net = {
  chain: Chain;
  /** short id used in UI + env var names */
  slug: string;
  label: string;
  testnet: boolean;
  /**
   * public RPCs (browser-safe), primary first — requests fall through the
   * list on failure/rate-limit; every URL is chain-id-verified before being
   * added here. env NEXT_PUBLIC_RPC_<CHAINID> prepends a private endpoint.
   */
  rpcs: string[];
  hook: `0x${string}`;
  poolManager: `0x${string}`;
  /** block this net's canonical (V3) hook was deployed at */
  deployBlock: number;
  /**
   * Earlier hook deployments still served by the app (pools show, reads and
   * writes route through them via the pool's own `key.hooks`). Scans start
   * from the earliest deploy block and watch every address. New pools never
   * land here.
   */
  legacy: Generation[];
  explorer: string;
  /** Uniswap Universal Router (V4_SWAP entry) — absent = no swap UI on this net */
  universalRouter?: `0x${string}`;
  /**
   * Largest eth_getLogs block range the PRIMARY endpoint serves, MEASURED by
   * `scripts/probe-rpc-limits.mjs` (re-run it when the RPC list changes).
   * The scanner starts here instead of probing down from its own maximum —
   * a chain capped at 1k used to eat a ladder of 400/500s on every single
   * scan just to rediscover the cap.
   */
  logRange: number;
  /**
   * How many of the LEADING `rpcs` entries serve archive `eth_getLogs` at
   * `logRange`. A scan spreads its parallel fan-out across exactly these, so
   * they must all honour the same range. Defaults to 1 (primary only).
   */
  logEndpoints?: number;
  /**
   * The chain has NO spendable native coin (fees are paid in something else,
   * the "native" symbol is not a real asset) — never offer the native side
   * in token pickers and never pre-select it.
   */
  noNative?: boolean;
};

/** canonical Permit2 — same address on every chain */
export const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as const;

function rpcsFor(chainId: number, ...urls: string[]): string[] {
  if (typeof process !== "undefined") {
    const v = process.env[`NEXT_PUBLIC_RPC_${chainId}`];
    if (v) return [v, ...urls];
  }
  return urls;
}

/** V3 deploy block + the campaign-4 V3 build, V2 and V1 as legacy entries. */
function gens(v3: number, v3c4: number, v2: number, v1: number): { deployBlock: number; legacy: Generation[] } {
  return {
    deployBlock: v3,
    legacy: [
      { tag: "v3", hook: V3_CAMPAIGN4_HOOK, deployBlock: v3c4 },
      { tag: "v2", hook: V2_HOOK, deployBlock: v2 },
      { tag: "v1", hook: V1_HOOK, deployBlock: v1 },
    ],
  };
}

/** Testnets: V3 (campaign 5) is pending there — the campaign-4 build is still the live hook. */
function gensTestnet(v3c4: number, v2: number, v1: number): { hook: `0x${string}`; deployBlock: number; legacy: Generation[] } {
  return {
    hook: V3_CAMPAIGN4_HOOK,
    deployBlock: v3c4,
    legacy: [
      { tag: "v2", hook: V2_HOOK, deployBlock: v2 },
      { tag: "v1", hook: V1_HOOK, deployBlock: v1 },
    ],
  };
}

export const NETS: Net[] = [
  {
    chain: mainnet, slug: "ethereum", label: "Ethereum", testnet: false,
    // tenderly 50k, mevblocker + drpc 10k; publicnode caps mainnet getLogs at
    // 50 blocks and single-flights them — read fallback only, so it goes last
    rpcs: rpcsFor(1, "https://gateway.tenderly.co/public/mainnet", "https://rpc.mevblocker.io", "https://eth.drpc.org", "https://ethereum-rpc.publicnode.com"),
    hook: CANONICAL_HOOK, poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
    ...gens(25988160, 25970820, 25814686, 25703029),
    explorer: "https://etherscan.io",
    universalRouter: "0x66a9893cc07d91d95644aedd05d03f95e1dba8af",
    logRange: 50_000,
  },
  {
    chain: base, slug: "base", label: "Base", testnet: false,
    // base.org + drpc 10k; publicnode caps Base getLogs at 50 blocks — last
    rpcs: rpcsFor(8453, "https://mainnet.base.org", "https://base.drpc.org", "https://base-rpc.publicnode.com"),
    hook: CANONICAL_HOOK, poolManager: "0x498581fF718922c3f8e6A244956aF099B2652b2b",
    ...gens(51373889, 51268603, 50330047, 49657824),
    explorer: "https://basescan.org",
    universalRouter: "0x6ff5693b99212da76ad316178a184ab56d299b43",
    logRange: 10_000,
  },
  {
    chain: unichain, slug: "unichain", label: "Unichain", testnet: false,
    // publicnode is BANNED here: its unichain replica reports the live head but is missing
    // recent receipts, contract code AND returns empty getLogs with a SUCCESS status —
    // silent data loss no scanner can detect (it hid real pools until the v6 cache flush).
    // drpc + the official endpoint both serve archive logs at 10k and agree with Blockscout.
    // (mainnet.unichain.org once mishandled eth_sendRawTransaction — reads only; writes go
    // through the wallet, never through this list.)
    rpcs: rpcsFor(130, "https://unichain.drpc.org", "https://mainnet.unichain.org"),
    hook: CANONICAL_HOOK, poolManager: "0x1F98400000000000000000000000000000000004",
    ...gens(58763678, 58586531, 56701906, 55356883),
    explorer: "https://uniscan.xyz",
    universalRouter: "0xef740bf23acae26f6492b10de645d6b98dc8eaf3",
    logRange: 10_000,
    logEndpoints: 2,
  },
  {
    chain: arbitrum, slug: "arbitrum", label: "Arbitrum", testnet: false,
    // arb1 50k; drpc 500; publicnode caps Arbitrum getLogs at 50 blocks — last
    rpcs: rpcsFor(42161, "https://arb1.arbitrum.io/rpc", "https://arbitrum.drpc.org", "https://arbitrum-one-rpc.publicnode.com"),
    hook: CANONICAL_HOOK, poolManager: "0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32",
    ...gens(505672120, 504870398, 497395639, 492046075),
    explorer: "https://arbiscan.io",
    universalRouter: "0xa51afafe0263b40edaef0df8781ea9aa03e381a3",
    logRange: 50_000,
  },
  {
    chain: optimism, slug: "optimism", label: "Optimism", testnet: false,
    // mainnet.optimism.io + tenderly serve archive getLogs at 10k. publicnode
    // now 403s history ("Archive requests require a personal token"), drpc
    // free rejects every getLogs range — both kept for plain reads only
    rpcs: rpcsFor(10, "https://mainnet.optimism.io", "https://optimism.gateway.tenderly.co", "https://optimism-rpc.publicnode.com", "https://optimism.drpc.org"),
    hook: CANONICAL_HOOK, poolManager: "0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3",
    ...gens(156956814, 156867928, 155925598, 155253116),
    explorer: "https://optimistic.etherscan.io",
    universalRouter: "0x851116d9223fabed8e56c0e6b8ad0c31d98b3507",
    logRange: 10_000,
    logEndpoints: 2,
  },
  {
    chain: bsc, slug: "bnb", label: "BNB Chain", testnet: false,
    // BNB is the hardest chain to read from a browser: publicnode answers
    // anything older than the recent tip with 403 "Archive requests require a
    // personal token", every bsc-dataseed mirror answers getLogs "limit
    // exceeded" at ANY range, and drpc's public BNB tier is permanently
    // rate-limited. nodereal's public endpoint serves 50k archive ranges, the
    // 48.club pair 5k, and thirdweb 1k (but on a tight request budget) — the
    // rest are read-only fallbacks. BSC also mints ~115k blocks/day, so a
    // private NEXT_PUBLIC_RPC_56 is worth setting here more than anywhere.
    rpcs: rpcsFor(56, "https://bsc-mainnet.nodereal.io/v1/64a9df0874fb4a93b9d0a3849de012d3", "https://rpc-bsc.48.club", "https://0.48.club", "https://56.rpc.thirdweb.com", "https://bsc-rpc.publicnode.com", "https://bsc-dataseed.bnbchain.org"),
    hook: CANONICAL_HOOK, poolManager: "0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF",
    ...gens(122176002, 121722433, 117531972, 114546905),
    explorer: "https://bscscan.com",
    universalRouter: "0x1906c1d672b88cd1b9ac7593301ca990f94eae07",
    logRange: 50_000,
  },
  {
    chain: polygon, slug: "polygon", label: "Polygon", testnet: false,
    // tenderly + quiknode serve archive getLogs at 10k. publicnode has PRUNED
    // history older than a few weeks ("History has been pruned for this
    // block") so it only works for recent reads; drpc free rejects getLogs.
    // polygon-rpc.com is GONE (401 "tenant disabled")
    rpcs: rpcsFor(137, "https://polygon.gateway.tenderly.co", "https://rpc-mainnet.matic.quiknode.pro", "https://polygon-bor-rpc.publicnode.com", "https://polygon.drpc.org"),
    hook: CANONICAL_HOOK, poolManager: "0x67366782805870060151383F4BbFF9daB53e5cD6",
    ...gens(93896344, 93755100, 92496642, 91600016),
    explorer: "https://polygonscan.com",
    universalRouter: "0x1095692a6237d83c6a72f3f5efedb9a670c49223",
    logRange: 10_000,
    logEndpoints: 2,
  },
  {
    chain: worldchain, slug: "worldchain", label: "World Chain", testnet: false,
    // tenderly 50k and reliable; drpc nominally does 10k but intermittently
    // routes to an upstream capped at 100 and returns "Temporary internal
    // error" on roughly half its calls, so it is a fallback, not the primary.
    // The alchemy public gateway caps at 100.
    rpcs: rpcsFor(480, "https://worldchain-mainnet.gateway.tenderly.co", "https://worldchain.drpc.org", "https://worldchain-mainnet.g.alchemy.com/public"),
    hook: CANONICAL_HOOK, poolManager: "0xb1860D529182ac3BC1F51Fa2ABd56662b7D13f33",
    ...gens(35088528, 34999751, 34057331, 33384712),
    explorer: "https://worldscan.org",
    universalRouter: "0x8ac7bee993bb44dab564ea4bc9ea67bf9eb5e743",
    logRange: 50_000,
  },
  {
    chain: soneium, slug: "soneium", label: "Soneium", testnet: false,
    rpcs: rpcsFor(1868, "https://rpc.soneium.org", "https://soneium.drpc.org"),
    hook: CANONICAL_HOOK, poolManager: "0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32",
    ...gens(28189143, 28100347, 27157781, 26485168),
    explorer: "https://soneium.blockscout.com",
    universalRouter: "0x4cded7edf52c8aa5259a54ec6a3ce7c6d2a455df",
    logRange: 50_000,
  },
  {
    chain: megaeth, slug: "megaeth", label: "MegaETH", testnet: false,
    rpcs: rpcsFor(4326, "https://mainnet.megaeth.com/rpc"),
    hook: CANONICAL_HOOK, poolManager: "0xaCB7e78fa05D562e0A5D3089ec896D57D057d38E",
    ...gens(26743304, 26544307, 24653311, 23308084),
    explorer: "https://megaeth.blockscout.com",
    universalRouter: "0x47837eb80db5908eabba9105626d9b348bea7b02",
    logRange: 50_000,
  },
  {
    chain: robinhood, slug: "robinhood", label: "Robinhood", testnet: false,
    rpcs: rpcsFor(4663, "https://rpc.mainnet.chain.robinhood.com"),
    hook: CANONICAL_HOOK, poolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
    ...gens(64035627, 62244207, 43628009, 30206983),
    explorer: "https://robinscan.io",
    universalRouter: "0x8876789976decbfcbbbe364623c63652db8c0904",
    logRange: 50_000,
  },
  {
    chain: avalanche, slug: "avalanche", label: "Avalanche", testnet: false,
    // publicnode 50k; the official api caps ranges at 2048
    rpcs: rpcsFor(43114, "https://avalanche-c-chain-rpc.publicnode.com", "https://api.avax.network/ext/bc/C/rpc", "https://avalanche.drpc.org"),
    hook: CANONICAL_HOOK, poolManager: "0x06380C0e0912312B5150364B9DC4542BA0DbBc85",
    ...gens(95381408, 95212132, 93461396, 92242906),
    explorer: "https://snowscan.xyz",
    universalRouter: "0x94b75331ae8d42c1b61065089b7d48fe14aa73b7",
    logRange: 50_000,
  },
  {
    chain: xLayer, slug: "xlayer", label: "X Layer", testnet: false,
    // rpc.xlayer.tech/unlimited is the only public endpoint serving getLogs
    // history (1k cap); plain rpc.xlayer.tech caps at 100, drpc free rejects
    // every range. The crawl is long here — the snapshot + /api/pools carry it
    rpcs: rpcsFor(196, "https://rpc.xlayer.tech/unlimited", "https://rpc.xlayer.tech", "https://xlayer.drpc.org"),
    hook: CANONICAL_HOOK, poolManager: "0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32",
    ...gens(70744526, 70567241, 68681331, 67336132),
    explorer: "https://www.oklink.com/x-layer",
    universalRouter: "0xda00ae15d3a71466517129255255db7c0c0956d3",
    logRange: 1_000,
  },
  {
    chain: arc, slug: "arc", label: "Arc", testnet: false,
    // rpc.mainnet.arc.io serves getLogs at 5k (10k → "requested data not
    // available") on a tight request budget; arc-scan.org is a plain-read fallback
    rpcs: rpcsFor(5042, "https://rpc.mainnet.arc.io", "https://rpc.arc-scan.org"),
    hook: CANONICAL_HOOK, poolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
    // first-time chain: V3 only, no earlier generation ever landed here
    deployBlock: 21132279, legacy: [],
    explorer: "https://explorer.arc.io",
    universalRouter: "0x4fca4a51ab4f23a7447b3284fbd7d73289a89fb1",
    logRange: 5_000,
  },
  {
    chain: sepolia, slug: "sepolia", label: "Sepolia", testnet: true,
    // 1rpc.io/sepolia is exhausted (200 "usage limit reached") — dropped
    rpcs: rpcsFor(11155111, "https://ethereum-sepolia-rpc.publicnode.com"),
    poolManager: "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543",
    ...gensTestnet(11698789, 11546970, 11438219),
    explorer: "https://sepolia.etherscan.io",
    universalRouter: "0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b",
    logRange: 50_000,
  },
  {
    chain: baseSepolia, slug: "base-sepolia", label: "Base Sepolia", testnet: true,
    // publicnode 50k first; sepolia.base.org caps at 2k
    rpcs: rpcsFor(84532, "https://base-sepolia-rpc.publicnode.com", "https://sepolia.base.org", "https://base-sepolia.drpc.org"),
    poolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    ...gensTestnet(46785161, 45841074, 45168277),
    explorer: "https://sepolia.basescan.org",
    universalRouter: "0x492e6456d9528771018deb9e87ef7750ef184104",
    logRange: 50_000,
  },
  {
    chain: unichainSepolia, slug: "unichain-sepolia", label: "Unichain Sepolia", testnet: true,
    rpcs: rpcsFor(1301, "https://unichain-sepolia-rpc.publicnode.com", "https://unichain-sepolia.drpc.org", "https://sepolia.unichain.org"),
    poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
    ...gensTestnet(62486439, 60598020, 59252497),
    explorer: "https://sepolia.uniscan.xyz",
    universalRouter: "0xf70536b3bcc1bd1a972dc186a2cf84cc6da6be5d",
    logRange: 50_000,
  },
  {
    chain: arbitrumSepolia, slug: "arbitrum-sepolia", label: "Arbitrum Sepolia", testnet: true,
    rpcs: rpcsFor(421614, "https://sepolia-rollup.arbitrum.io/rpc", "https://arbitrum-sepolia-rpc.publicnode.com", "https://arbitrum-sepolia.drpc.org"),
    poolManager: "0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317",
    ...gensTestnet(308601376, 301010834, 295676509),
    explorer: "https://sepolia.arbiscan.io",
    universalRouter: "0xefd1d4bd4cf1e86da286bb4cb1b8bced9c10ba47",
    logRange: 50_000,
  },
  {
    chain: robinhoodTestnet, slug: "robinhood-testnet", label: "Robinhood Testnet", testnet: true,
    rpcs: rpcsFor(46630, "https://rpc.testnet.chain.robinhood.com"),
    poolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
    ...gensTestnet(118984924, 105754223, 97982800),
    explorer: "https://explorer.testnet.chain.robinhood.com",
    logRange: 50_000,
  },
];

export const MAINNETS = NETS.filter((n) => !n.testnet);
export const TESTNETS = NETS.filter((n) => n.testnet);

export function netById(chainId: number): Net | undefined {
  return NETS.find((n) => n.chain.id === chainId);
}

export function netBySlug(slug: string): Net | undefined {
  return NETS.find((n) => n.slug === slug);
}

export function hooksOf(net: Net): `0x${string}`[] {
  return [net.hook, ...net.legacy.map((g) => g.hook)];
}

export function earliestDeployBlock(net: Net): number {
  return Math.min(net.deployBlock, ...net.legacy.map((g) => g.deployBlock));
}

export function generationOf(net: Net, hook: string): Generation {
  const h = hook.toLowerCase();
  if (h === net.hook.toLowerCase()) return { tag: "v3", hook: net.hook, deployBlock: net.deployBlock };
  const hit = net.legacy.find((g) => g.hook.toLowerCase() === h);
  return hit ?? { tag: "v3", hook: net.hook, deployBlock: net.deployBlock };
}

export function isCanonicalHook(hook: string): boolean {
  return hook.toLowerCase() === CANONICAL_HOOK.toLowerCase();
}

/** Speaks the V3 ABI: the live V3 hook or its superseded campaign-4 build. */
export function isV3Hook(hook: string): boolean {
  const h = hook.toLowerCase();
  return h === CANONICAL_HOOK.toLowerCase() || h === V3_CAMPAIGN4_HOOK.toLowerCase();
}

export function tagOfHook(hook: string): GenerationTag {
  const h = hook.toLowerCase();
  if (h === V2_HOOK.toLowerCase()) return "v2";
  if (h === V1_HOOK.toLowerCase()) return "v1";
  return "v3";
}

/**
 * DexScreener chain slug per network — the chains DexScreener actually
 * indexes (probed against their pairs API). Feeds the embedded chart and
 * their token-image CDN; absent = no DexScreener coverage.
 */
export const DEXSCREENER_CHAIN: Record<string, string> = {
  ethereum: "ethereum",
  base: "base",
  unichain: "unichain",
  arbitrum: "arbitrum",
  optimism: "optimism",
  bnb: "bsc",
  polygon: "polygon",
  worldchain: "worldchain",
  soneium: "soneium",
  avalanche: "avalanche",
  megaeth: "megaeth",
  robinhood: "robinhood",
};
