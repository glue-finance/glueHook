#!/usr/bin/env node
/**
 * Generate web/lib/abi.v3.ts from the Foundry artifact at
 * out/GlueHook.sol/GlueHook.json (the live V3 generation, commit 19a731c).
 *
 *   npm run abi   # from web/
 *   node scripts/gen-abi.mjs
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const artifact = join(root, "out", "GlueHook.sol", "GlueHook.json");
const dest = join(here, "..", "lib", "abi.v3.ts");

const json = JSON.parse(readFileSync(artifact, "utf8"));
if (!Array.isArray(json.abi)) throw new Error(`no abi in ${artifact}`);

const body =
  `// Generated from out/GlueHook.sol/GlueHook.json — do not edit by hand.\n` +
  `export const glueHookAbi = ${JSON.stringify(json.abi, null, 2)} as const;\n`;

writeFileSync(dest, body);
console.log(`wrote ${dest} (${json.abi.length} abi items)`);
