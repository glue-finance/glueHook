/**
 * Clear-signing annotations for every user-facing GlueHook V3 entrypoint.
 *
 * Keyed by contract → function → leaf parameter path (dotted). `build.mjs`
 * turns this into an ERC-7730 descriptor; the function fragments and parameter
 * tree come from the ABI, so this file only says HOW to show each value. A
 * `null` field hides a parameter (only for opaque identity — never for amounts,
 * recipients or targets).
 *
 * Scales: ProgramConfig shares are WAD (1e18 = 100%) → `%` with 16 decimals.
 * Uniswap V4 `fee` is hundredths of a bip → `%` with 4 decimals. `address(0)`
 * is the native coin wherever an asset is expected, burn / locked / frozen
 * wherever a recipient / owner / operator is expected (spelled in the label).
 * `type(uint256).max` disarms an auto-harvest min.
 */

export const CHAINS = [1, 8453, 130, 42161, 10, 56, 137, 43114, 196, 480, 1868, 4326, 4663, 5042];

export const ADDR = {
  glueHook: "0x03D482cB3Ff339C2d29736818D0F72c66dD6A040",
};

const everywhere = (address) => CHAINS.map((chainId) => ({ chainId, address }));

export const METADATA = {
  owner: "Glue",
  info: { url: "https://gluehook.trade", legalName: "Glue Protocol", deploymentDate: "2026-09-13T00:00:00Z" },
  constants: {
    native: "0x0000000000000000000000000000000000000000",
  },
};

const NATIVE = "$.metadata.constants.native";
const asset = (label) => ({ label, format: "addressName", params: { types: ["token", "collection"] } });
const account = (label) => ({ label, format: "addressName", params: { types: ["eoa", "wallet", "contract"] } });
const amount = (label, tokenPath) => ({ label, format: "tokenAmount", params: { tokenPath, nativeCurrencyAddress: [NATIVE] } });
const pctWad = (label) => ({ label, format: "unit", params: { base: "%", decimals: 16 } });
const feePips = (label) => ({ label, format: "unit", params: { base: "%", decimals: 4 } });
const raw = (label) => ({ label, format: "raw" });
const optional = (f) => ({ ...f, visible: "optional" });
const native = (label = "Native sent") => ({ label, format: "amount" });

const KEY = {
  "key.currency0": asset("Token 0"),
  "key.currency1": asset("Token 1"),
  "key.fee": feePips("Pool fee"),
  "key.tickSpacing": raw("Tick spacing"),
  "key.hooks": null, // always this contract
};

const CONFIG = {
  "config.buybackShareWad": pctWad("Buyback share"),
  "config.burnShareWad": pctWad("Burn share"),
  "config.compoundShareWad": pctWad("Compound share"),
  "config.potCompoundShareWad": optional(pctWad("Pot compound")),
  "config.potBurnShareWad": optional(pctWad("Pot burn")),
  "config.publicHarvest": raw("Public harvest"),
  "config.secondaryRecipient": account("Fee → secondary"),
  "config.mainRecipient": account("Fee → main"),
  "config.minMain": optional(amount("Min main (max=off)", "main")),
  "config.minSecondary": optional(raw("Min 2nd (max=off)")),
};

const CONFIG_NO_MAIN = {
  ...CONFIG,
  "config.minMain": optional(raw("Min main (max=off)")),
};

export const CONTRACTS = {
  GlueHook: {
    deployments: everywhere(ADDR.glueHook),
    functions: {
      launchPool: {
        intent: "Launch GlueHook pool",
        interpolatedIntent: "Launch {key.currency0}/{key.currency1} pool",
        fields: {
          ...KEY,
          sqrtPriceX96: optional(raw("Price sqrtX96")),
          main: asset("Main asset"),
          recipient: account("Delivery (0=burn)"),
          tickLower: optional(raw("Lower tick")),
          tickUpper: optional(raw("Upper tick")),
          liquidity: raw("L units"),
          owner: account("Owner (0=locked)"),
          ...CONFIG,
          "@.value": optional(native()),
        },
      },
      initPot: {
        intent: "Open buyback pot",
        interpolatedIntent: "Open pot, main {main}",
        fields: {
          ...KEY,
          main: asset("Main asset"),
          recipient: account("Delivery (0=burn)"),
        },
      },
      addLiquidity: {
        intent: "Create LP program",
        fields: {
          ...KEY,
          tickLower: optional(raw("Lower tick")),
          tickUpper: optional(raw("Upper tick")),
          liquidity: raw("L units"),
          owner: account("Owner (0=locked)"),
          "@.value": optional(native()),
        },
      },
      addLiquidityAdvanced: {
        intent: "Create LP program",
        interpolatedIntent: "Create LP program for {key.currency0}/{key.currency1}",
        fields: {
          ...KEY,
          tickLower: optional(raw("Lower tick")),
          tickUpper: optional(raw("Upper tick")),
          liquidity: raw("L units"),
          owner: account("Owner (0=locked)"),
          ...CONFIG_NO_MAIN,
          "@.value": optional(native()),
        },
      },
      addProgramLiquidity: {
        intent: "Add program LP",
        fields: {
          ...KEY,
          liquidity: raw("L units"),
          "@.value": optional(native()),
        },
      },
      removeProgramLiquidity: {
        intent: "Remove program LP",
        fields: {
          ...KEY,
          liquidity: raw("L units"),
          to: account("Send remainder to"),
        },
      },
      harvest: {
        intent: "Harvest LP fees",
        interpolatedIntent: "Harvest {key.currency0}/{key.currency1}",
        fields: { ...KEY },
      },
      donate: {
        intent: "Donate to pot",
        interpolatedIntent: "Donate to {key.currency0}/{key.currency1} pot",
        fields: {
          ...KEY,
          amount: amount("Donation", "key.currency0"),
          "@.value": optional(native()),
        },
      },
      claim: {
        intent: "Claim owed tokens",
        interpolatedIntent: "Claim owed {asset}",
        fields: { asset: asset("Asset") },
      },
      flushDirect: {
        intent: "Retry delivery",
        fields: { poolId: raw("Pool id") },
      },
      setProgramConfig: {
        intent: "Edit LP program",
        fields: {
          poolId: raw("Pool id"),
          ...CONFIG_NO_MAIN,
        },
      },
      setProgramOperator: {
        intent: "Set program operator",
        interpolatedIntent: "Set operator to {newOperator}",
        fields: {
          poolId: raw("Pool id"),
          newOperator: account("Operator (0=frozen)"),
        },
      },
      setRecipient: {
        intent: "Set pot recipient",
        interpolatedIntent: "Set delivery to {recipient}",
        fields: {
          poolId: raw("Pool id"),
          recipient: account("Delivery (0=burn)"),
        },
      },
      transferProgramOwnership: {
        intent: "Transfer LP program",
        interpolatedIntent: "Transfer program to {newOwner}",
        fields: {
          poolId: raw("Pool id"),
          newOwner: account("Owner (0=locked)"),
        },
      },
    },
  },
};
