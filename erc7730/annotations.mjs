/**
 * Clear-signing annotations for every user-facing GlueHook V3 entrypoint.
 *
 * Keyed by contract → function → leaf parameter path (dotted). `build.mjs`
 * turns this into an ERC-7730 descriptor; the function fragments and parameter
 * tree come from the ABI, so this file only says HOW to show each value. A
 * `null` field hides a parameter (only for opaque identity — never for amounts,
 * recipients or targets). `visible: "never"` keeps the field in the file but
 * off the screen; that is how `key.hooks` is handled, because it is always
 * this contract.
 *
 * Scales: ProgramConfig shares are WAD (1e18 = 100%) → `%` with 16 decimals.
 * Uniswap V4 `fee` is hundredths of a bip → `%` with 4 decimals. `address(0)`
 * is the native coin wherever an asset is expected. On a recipient it means
 * "no remainder" and is valid only when that side's shares already sum to
 * 100%. On an owner it locks the liquidity forever and forces public harvest,
 * except on `addLiquidity`, where a zero owner reverts because the default
 * recipients are the owner. `type(uint256).max` disarms an auto-harvest min.
 *
 * `donate` pulls the pot's stored secondary, which is not in the calldata, so
 * the amount is shown raw. `(0, 0)` ticks are a full-range sentinel.
 * `addProgramLiquidity` / `removeProgramLiquidity` harvest through the stored
 * split before they move principal. Liquidity is in pool units; the ERC-20
 * leg is whatever the pool charges, and the attached native value is a cap.
 */

export const CHAINS = [1, 8453, 130, 42161, 10, 56, 137, 43114, 196, 480, 1868, 4326, 4663, 5042];

export const ADDR = {
  glueHook: "0x03D482cB3Ff339C2d29736818D0F72c66dD6A040",
};

const everywhere = (address) => CHAINS.map((chainId) => ({ chainId, address }));

export const METADATA = {
  owner: "Glue",
  info: { url: "https://gluehook.trade", deploymentDate: "2026-09-13T00:00:00Z" },
  constants: {
    native: "0x0000000000000000000000000000000000000000",
  },
};

const NATIVE = "$.metadata.constants.native";
const MAX_U256 = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

const asset = (label) => ({ label, format: "addressName", params: { types: ["token", "collection"] } });
const account = (label) => ({
  label,
  format: "addressName",
  params: { types: ["eoa", "wallet", "contract"], sources: ["local", "ens"] },
});
const amount = (label, tokenPath, extra) => ({
  label,
  format: "tokenAmount",
  params: { tokenPath, nativeCurrencyAddress: [NATIVE], ...extra },
});
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
  "key.hooks": { label: "Hook", format: "addressName", params: { types: ["contract"] }, visible: "never" },
};

const TICKS = {
  tickLower: optional(raw("Lower tick (0,0=full)")),
  tickUpper: optional(raw("Upper tick (0,0=full)")),
};

const CONFIG = {
  "config.buybackShareWad": pctWad("Buyback share"),
  "config.burnShareWad": pctWad("Burn share"),
  "config.compoundShareWad": pctWad("Compound share"),
  "config.potCompoundShareWad": pctWad("Pot compound"),
  "config.potBurnShareWad": pctWad("Pot burn"),
  "config.publicHarvest": raw("Public harvest"),
  "config.secondaryRecipient": account("Fee → 2nd (0=none)"),
  "config.mainRecipient": account("Fee → main (0=none)"),
  "config.minMain": amount("Min main", "main", { threshold: MAX_U256, message: "off" }),
  "config.minSecondary": raw("Min 2nd (max=off)"),
};

const CONFIG_NO_MAIN = {
  ...CONFIG,
  "config.minMain": raw("Min main (max=off)"),
};

const LIQUIDITY = raw("Liquidity units");
const MAX_NATIVE = native("Max native sent");
const LOCKED_OWNER = account("Owner (0=lock+public)");

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
          ...TICKS,
          liquidity: LIQUIDITY,
          owner: LOCKED_OWNER,
          ...CONFIG,
          "@.value": MAX_NATIVE,
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
        interpolatedIntent: "Create LP for {key.currency0}/{key.currency1}",
        fields: {
          ...KEY,
          ...TICKS,
          liquidity: LIQUIDITY,
          // A zero owner reverts here: both default recipients are the owner.
          owner: account("Owner"),
          "@.value": MAX_NATIVE,
        },
      },
      addLiquidityAdvanced: {
        intent: "Create LP program",
        interpolatedIntent: "Create LP for {key.currency0}/{key.currency1}",
        fields: {
          ...KEY,
          ...TICKS,
          liquidity: LIQUIDITY,
          owner: LOCKED_OWNER,
          ...CONFIG_NO_MAIN,
          "@.value": MAX_NATIVE,
        },
      },
      addProgramLiquidity: {
        intent: "Add program LP (harvests)",
        interpolatedIntent: "Add LP to {key.currency0}/{key.currency1} (harvests)",
        fields: {
          ...KEY,
          liquidity: LIQUIDITY,
          "@.value": MAX_NATIVE,
        },
      },
      removeProgramLiquidity: {
        intent: "Remove program LP (harvests)",
        interpolatedIntent: "Remove LP from {key.currency0}/{key.currency1} (harvests)",
        fields: {
          ...KEY,
          liquidity: LIQUIDITY,
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
        // The secondary token is stored on the pot, not in the calldata.
        interpolatedIntent: "Donate to {key.currency0}/{key.currency1} pot",
        fields: {
          ...KEY,
          amount: raw("Donation (pot 2nd token, raw)"),
          "@.value": native(),
        },
      },
      claim: {
        intent: "Claim owed tokens",
        interpolatedIntent: "Claim owed {asset}",
        fields: { asset: asset("Asset") },
      },
      flushDirect: {
        intent: "Retry delivery",
        interpolatedIntent: "Retry parked delivery",
        fields: { poolId: raw("Pool id") },
      },
      setProgramConfig: {
        intent: "Edit LP program",
        interpolatedIntent: "Edit LP program split",
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
          newOwner: LOCKED_OWNER,
        },
      },
    },
  },
};
