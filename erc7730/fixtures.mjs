#!/usr/bin/env node
/**
 * Reference test fixtures (`testsv2/`) for the GlueHook ERC-7730 descriptor.
 *
 * For every sample call below this script ABI-encodes the calldata, wraps it in
 * an UNSIGNED EIP-1559 transaction (what the registry's runners consume), and
 * renders the `expected` block by walking the descriptor's own field list with
 * the mock `dataProvider` — so labels, order and visibility always match the
 * descriptor that `build.mjs` just wrote. Run after `build.mjs`:
 *
 *   node erc7730/build.mjs && node erc7730/fixtures.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Interface, Transaction, getAddress } from "ethers";
import { ADDR } from "./annotations.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const outDir = join(here, "registry", "glue", "testsv2");
mkdirSync(outDir, { recursive: true });

const CHAIN = 8453; // Base
const NATIVE_SYMBOL = "ETH";
const ZERO = "0x0000000000000000000000000000000000000000";
const E18 = 10n ** 18n;
const pct = (n) => (BigInt(n) * E18) / 100n;
const Q96 = 2n ** 96n;

const A = {
  user: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf",
  friend: "0x2c62C80aD86785DD3bfC7B616400A98E1903b672",
  sticky: "0x1111111111111111111111111111111111111111", // token, 18 dec
  usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
};

const dataProvider = {
  tokens: {
    [A.sticky.toLowerCase()]: { symbol: "TOKEN", decimals: 18, name: "Demo Token" },
    [A.usdc.toLowerCase()]: { symbol: "USDC", decimals: 6, name: "USD Coin" },
    [ZERO]: { symbol: NATIVE_SYMBOL, decimals: 18, name: "Ether" },
  },
  addressNames: {
    [ADDR.glueHook.toLowerCase()]: "GlueHook",
    [A.sticky.toLowerCase()]: "TOKEN",
    [A.usdc.toLowerCase()]: "USDC",
  },
  nftCollectionNames: {},
};

const ethQuoted = {
  currency0: ZERO,
  currency1: A.sticky,
  fee: 3000,
  tickSpacing: 60,
  hooks: ADDR.glueHook,
};

// 20% buyback + 50% compound leaves a secondary remainder, and 30% burn + 50%
// compound leaves a main remainder. Both recipients have to be live;
// address(0) is valid only when that side's shares already sum to 100%.
const split = {
  buybackShareWad: pct(20),
  burnShareWad: pct(30),
  compoundShareWad: pct(50),
  potCompoundShareWad: 0n,
  potBurnShareWad: 0n,
  publicHarvest: false,
  secondaryRecipient: A.friend,
  mainRecipient: A.user,
  minMain: 2n ** 256n - 1n,
  minSecondary: 2n ** 256n - 1n,
};

const erc20Pair = {
  currency0: A.sticky,
  currency1: A.usdc,
  fee: 3000,
  tickSpacing: 60,
  hooks: ADDR.glueHook,
};

const poolId = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

const SAMPLES = {
  GlueHook: [
    {
      fn: "launchPool",
      description: "Launch an ETH-quoted token pool, burn recipient, 3-way split",
      value: E18 / 2n,
      args: {
        key: ethQuoted,
        sqrtPriceX96: Q96,
        main: A.sticky,
        recipient: ZERO,
        tickLower: 0,
        tickUpper: 0,
        liquidity: 1_000_000n,
        owner: A.user,
        config: split,
      },
    },
    {
      fn: "initPot",
      description: "Open a buyback pot, burn recipient, TOKEN as main",
      args: { key: ethQuoted, main: A.sticky, recipient: ZERO },
    },
    {
      fn: "addLiquidityAdvanced",
      description: "Create a full-range LP program with a 3-way split",
      value: E18,
      args: {
        key: ethQuoted,
        tickLower: 0,
        tickUpper: 0,
        liquidity: 1_000_000n,
        owner: A.user,
        config: split,
      },
    },
    {
      fn: "addProgramLiquidity",
      description: "Add liquidity units to an existing program",
      value: E18 / 4n,
      args: { key: ethQuoted, liquidity: 500_000n },
    },
    {
      fn: "removeProgramLiquidity",
      description: "Remove program LP and send remainder to a friend",
      args: { key: ethQuoted, liquidity: 250_000n, to: A.friend },
    },
    {
      fn: "donate",
      description: "Donate 0.5 ETH to a native secondary pot",
      value: E18 / 2n,
      args: { key: ethQuoted, amount: E18 / 2n },
    },
    {
      fn: "donate",
      description: "Donate 1000 TOKEN to an ERC20 secondary pot",
      args: { key: erc20Pair, amount: 1000n * E18 },
    },
    {
      fn: "donate",
      description: "Donate 1000 USDC when the pot main is currency0",
      args: { key: erc20Pair, amount: 1000n * 1_000_000n },
    },
    {
      fn: "addLiquidity",
      description: "Seed a full-range LP program",
      value: E18,
      args: { key: ethQuoted, tickLower: 0, tickUpper: 0, liquidity: 1_000_000n, owner: A.user },
    },
    {
      fn: "harvest",
      description: "Harvest the program's fees",
      args: { key: ethQuoted },
    },
    {
      fn: "setProgramConfig",
      description: "Edit the program to a 3-way split",
      args: { poolId, config: split },
    },
    {
      fn: "setProgramOperator",
      description: "Freeze the program operator",
      args: { poolId, newOperator: ZERO },
    },
    {
      fn: "setRecipient",
      description: "Point the pot at burn",
      args: { poolId, recipient: ZERO },
    },
    {
      fn: "transferProgramOwnership",
      description: "Lock the program liquidity forever",
      args: { poolId, newOwner: ZERO },
    },
    {
      fn: "claim",
      description: "Claim owed TOKEN",
      args: { asset: A.sticky },
    },
    {
      fn: "flushDirect",
      description: "Retry a parked main delivery",
      args: { poolId },
    },
  ],
};

const trim = (v, decimals) => {
  const s = v.toString().padStart(decimals + 1, "0");
  const int = s.slice(0, s.length - decimals) || "0";
  const frac = decimals ? s.slice(s.length - decimals).replace(/0+$/, "") : "";
  return frac ? `${int}.${frac}` : int;
};
const constant = (descriptor, ref) =>
  typeof ref === "string" && ref.startsWith("$.metadata.constants.") ? descriptor.metadata.constants[ref.split(".").pop()] : ref;

function resolve(scope, path) {
  let cur = scope;
  for (const seg of path.split(".")) {
    if (seg === "[]") return cur;
    cur = cur?.[seg];
  }
  return cur;
}
function at(scope, path, i) {
  const v = resolve(scope, path);
  return path.includes(".[]") ? v[i] : v;
}

function fmt(descriptor, value, field, scope, i) {
  const p = field.params ?? {};
  switch (field.format) {
    case "raw":
      return typeof value === "boolean" ? String(value) : String(value);
    case "addressName": {
      const a = String(value);
      return dataProvider.addressNames[a.toLowerCase()] ?? getAddress(a);
    }
    case "tokenAmount": {
      const token = p.tokenPath === "@.to" ? scope["@.to"] : at(scope, p.tokenPath, i);
      const natives = (p.nativeCurrencyAddress ?? []).map((n) => constant(descriptor, n).toLowerCase());
      const nativeToken = natives.includes(String(token).toLowerCase());
      const t = dataProvider.tokens[String(token).toLowerCase()];
      if (!nativeToken && !t) throw new Error(`no mock token for ${token}`);
      const symbol = nativeToken ? NATIVE_SYMBOL : t.symbol;
      if (p.threshold != null && BigInt(value) >= BigInt(p.threshold)) return `${p.message ?? "All"} ${symbol}`;
      return `${trim(value, nativeToken ? 18 : t.decimals)} ${symbol}`;
    }
    case "amount":
      return `${trim(value, 18)} ${NATIVE_SYMBOL}`;
    case "unit":
      return `${trim(value, p.decimals ?? 0)}${p.base}`;
    default:
      throw new Error(`unsupported format ${field.format}`);
  }
}

function render(descriptor, fields, scope, out) {
  for (const f of fields) {
    if (f.fields) {
      const arr = resolve(scope, f.path);
      for (const el of arr) render(descriptor, f.fields, { ...el, "@.to": scope["@.to"] }, out);
      continue;
    }
    if (f.visible === "never") continue;
    if (f.path.startsWith("@.")) {
      out.push({ label: f.label, value: fmt(descriptor, scope[f.path], f, scope) });
      continue;
    }
    if (f.path.includes(".[]")) {
      const arr = resolve(scope, f.path);
      arr.forEach((v, i) => out.push({ label: f.label, value: fmt(descriptor, v, f, scope, i) }));
    } else {
      out.push({ label: f.label, value: fmt(descriptor, resolve(scope, f.path), f, scope) });
    }
  }
}

const interpolate = (descriptor, spec, scope) =>
  spec.interpolatedIntent?.replace(/\{([^}]+)\}/g, (_, path) => {
    const f = spec.fields.find((x) => x.path === path || x.path === `${path}.[]`);
    if (!f) throw new Error(`interpolated path ${path} has no field`);
    if (f.path.includes(".[]")) return resolve(scope, f.path).map((v, i) => fmt(descriptor, v, f, scope, i)).join(", ");
    return fmt(descriptor, resolve(scope, f.path), f, scope);
  });

for (const [name, samples] of Object.entries(SAMPLES)) {
  const descriptor = JSON.parse(readFileSync(join(here, "registry", "glue", `calldata-${name}.json`), "utf8"));
  const abi = JSON.parse(readFileSync(join(root, "out", `${name}.sol`, `${name}.json`), "utf8")).abi;
  const iface = new Interface(abi);
  const to = descriptor.context.contract.deployments[0].address;

  const tests = samples.map((s) => {
    const matches = Object.entries(descriptor.display.formats).filter(([, v]) => v.$id === s.fn);
    if (!matches.length) throw new Error(`${name}.${s.fn} not in descriptor`);
    const [key, spec] = matches[0];
    const fn = iface.getFunction(s.fn);
    if (!key.startsWith(`${fn.name}(`)) throw new Error(`${name}.${s.fn}: key mismatch`);
    const data = iface.encodeFunctionData(fn, fn.inputs.map((inp) => s.args[inp.name]));
    const tx = Transaction.from({
      type: 2, chainId: CHAIN, nonce: 7, maxFeePerGas: 50_000_000n, maxPriorityFeePerGas: 1_000_000n, gasLimit: 900_000n,
      to: s.to ?? to, value: s.value ?? 0n, data,
    });
    const scope = { ...s.args, "@.to": s.to ?? to, "@.value": s.value ?? 0n };
    const fields = [];
    render(descriptor, spec.fields, scope, fields);
    const expected = { intent: spec.intent, owner: descriptor.metadata.owner, fields };
    const ii = interpolate(descriptor, spec, scope);
    if (ii) expected.interpolatedIntent = ii;
    return { description: s.description, rawTx: tx.unsignedSerialized, expected };
  });

  const file = join(outDir, `calldata-${name}.tests.json`);
  writeFileSync(
    file,
    JSON.stringify({ $schema: "../../../specs/erc7730-tests-v2.schema.json", descriptor: `../calldata-${name}.json`, dataProvider, tests }, null, 2) + "\n",
  );
  console.log(`wrote ${file} (${tests.length} cases)`);
}
