#!/usr/bin/env node
/**
 * ERC-7730 (clear signing) descriptor builder for GlueHook V3.
 *
 * Reads the compiled ABI in `out/` and the hand-written annotations in
 * `./annotations.mjs`, then writes `calldata-GlueHook.json` into
 * `./registry/glue/` — the exact folder layout the
 * ethereum/clear-signing-erc7730-registry expects for a PR.
 *
 *   node erc7730/build.mjs            # (after `forge build`)
 *
 * Function keys are built FROM THE ABI so they are always canonical
 * (`name(type param,type param)`, tuples spelled out with their component
 * names, no space after commas). Every leaf parameter of an annotated function
 * gets a field; the annotation decides label/format, and anything left
 * un-annotated is emitted as `raw` so the build fails loudly in `erc7730 lint`
 * rather than silently dropping a parameter from the signing screen.
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { CONTRACTS, METADATA } from "./annotations.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const outDir = join(here, "registry", "glue");
mkdirSync(outDir, { recursive: true });

/** Load `out/<Name>.sol/<Name>.json` (forge artifact) and return its ABI. */
function loadAbi(name) {
  const file = join(root, "out", `${name}.sol`, `${name}.json`);
  return JSON.parse(readFileSync(file, "utf8")).abi;
}

/** Human-readable fragment piece for one ABI input: `type name` with tuples expanded. */
function fragmentOf(input) {
  if (input.type.startsWith("tuple")) {
    const inner = `(${input.components.map(fragmentOf).join(",")})`;
    return `${inner}${input.type.slice("tuple".length)} ${input.name}`;
  }
  return `${input.type} ${input.name}`;
}

let missing = 0;

/**
 * Field specs for a list of ABI inputs.
 *
 * Plain structs are flattened into dotted paths (`config.buybackShareWad`).
 * Annotations are always looked up by the ABSOLUTE path.
 */
function buildFields(inputs, absPrefix, relPrefix, ann, where, used) {
  const out = [];
  for (const input of inputs) {
    const abs = absPrefix ? `${absPrefix}.${input.name}` : input.name;
    const rel = relPrefix ? `${relPrefix}.${input.name}` : input.name;
    const isArray = input.type.endsWith("[]");
    if (input.type.startsWith("tuple")) {
      if (isArray) {
        const fields = buildFields(input.components, `${abs}.[]`, "", ann, where, used);
        if (fields.length) out.push({ path: `${rel}.[]`, fields });
      } else {
        out.push(...buildFields(input.components, abs, rel, ann, where, used));
      }
      continue;
    }
    const absLeaf = isArray ? `${abs}.[]` : abs;
    const relLeaf = isArray ? `${rel}.[]` : rel;
    used.add(absLeaf);
    const f = ann.fields?.[absLeaf];
    if (f === null) continue; // deliberately hidden
    if (!f) {
      missing++;
      console.warn(`  ! ${where} — no annotation for ${absLeaf} (${input.type}); emitting raw`);
      out.push({ path: relLeaf, label: absLeaf, format: "raw" });
      continue;
    }
    out.push({ path: relLeaf, ...f });
  }
  return out;
}

for (const [contractName, spec] of Object.entries(CONTRACTS)) {
  const abi = loadAbi(contractName);
  const byName = new Map();
  for (const f of abi) if (f.type === "function") byName.set(f.name, [...(byName.get(f.name) ?? []), f]);

  const formats = {};
  for (const [fnName, ann] of Object.entries(spec.functions)) {
    const overloads = byName.get(fnName);
    if (!overloads) throw new Error(`${contractName}.${fnName}: not in ABI`);
    const fn = overloads.length === 1 ? overloads[0] : overloads.find((o) => o.inputs.length === ann.arity);
    if (!fn) throw new Error(`${contractName}.${fnName}: ambiguous overload, set \`arity\``);
    if (fn.stateMutability === "view" || fn.stateMutability === "pure") throw new Error(`${contractName}.${fnName}: read-only`);

    const key = `${fn.name}(${fn.inputs.map(fragmentOf).join(",")})`;
    const used = new Set();
    const fields = buildFields(fn.inputs, "", "", ann, `${contractName}.${fnName}`, used);
    for (const p of Object.keys(ann.fields ?? {})) {
      if (!used.has(p) && !p.startsWith("@.")) throw new Error(`${contractName}.${fnName}: annotation for unknown path ${p}`);
    }
    if (fn.stateMutability === "payable" && ann.fields?.["@.value"] !== null) {
      fields.push({ path: "@.value", ...(ann.fields?.["@.value"] ?? { label: "Native sent", format: "amount", visible: "optional" }) });
    }
    const entry = { $id: fnName, intent: ann.intent };
    if (ann.interpolatedIntent) entry.interpolatedIntent = ann.interpolatedIntent;
    entry.fields = fields;
    formats[key] = entry;
  }

  const context = { $id: contractName, contract: { deployments: spec.deployments } };
  if (spec.factory) context.contract.factory = spec.factory;

  const doc = {
    $schema: "../../specs/erc7730-v2.schema.json",
    context,
    metadata: { ...METADATA, contractName, ...(spec.metadata ?? {}) },
    display: { formats },
  };
  const file = join(outDir, `calldata-${contractName}.json`);
  writeFileSync(file, JSON.stringify(doc, null, 2) + "\n");
  console.log(`wrote ${file} (${Object.keys(formats).length} functions)`);
}

if (missing) {
  console.warn(`\n${missing} parameter(s) fell back to raw — annotate them in annotations.mjs`);
  process.exitCode = 1;
}
