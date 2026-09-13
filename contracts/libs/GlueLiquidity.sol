// SPDX-License-Identifier: BUSL-1.1
//
// Licensed Work: GlueHook
// The Licensed Work is (c) 2026 gluefinance.eth and is owned exclusively by Glue Labs Inc. (Delaware).
// Licensor: Glue Labs Inc. (Delaware)
// Change Date: the earlier of 2030-08-05 or a date specified at gluehook-license-date.gluefinance.eth
// Change License: GNU General Public License v2.0 or later
// Full licence text: https://github.com/glue-finance/GlueHook/blob/main/LICENCE.txt

pragma solidity ^0.8.35;

import {GluedV4Core, IPoolManagerMin} from "./GluedV4Core.sol";
import {GluedMath} from "./GluedMath.sol";
import {IGlueHook} from "../interfaces/IGlueHook.sol";
import {IGlueStickMin} from "../interfaces/IGlueStickMin.sol";
import {IGlueWrapperMin} from "../interfaces/IGlueWrapperMin.sol";
import {IGlueHookedEngine} from "../interfaces/IGlueHookedEngine.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title  GlueLiquidity - the LP PROGRAM's harvest and AUTO-COMPOUND engine, extracted for EIP-170.
 * @notice A DELEGATECALL-linked library holding the heavy bodies of the program layer: the MERGED
 *         harvest — ONE `modifyLiquidity` that collects the position's fees and re-mints the
 *         compound budget in the same call, netting the fees against the mint's cost — the flat
 *         gross-referenced split, and the delivery engine (the Glue burn, the recipient pushes).
 *         The compound is the piece that gives a hooked pool the auto-compounding
 *         concentrated-liquidity venues lack natively: a selectable `compoundShareWad` of every
 *         harvest, PLUS whatever earlier mints could not place (the CARRY), is re-minted into the
 *         program's own position at the live price, inside the very swaps that generated the
 *         fees. The resident hook keeps only thin, gate-checked forwarders; every function here
 *         runs in the hook's own storage, address and balance (so `address(this)` is the hook, the
 *         PoolManager callbacks land on the hook, and events are emitted from the hook's address).
 * @dev    State comes in as STORAGE POINTERS from the hook's own declarations - the library declares
 *         no state of its own and the hook's storage layout is untouched by the extraction.
 */
library GlueLiquidity {
    using SafeERC20 for IERC20;

    /// @dev WAD denominator, mirroring the hook's.
    uint256 private constant PRECISION = 1e18;
    /// @dev `GluedV4Callback`'s ADD op code, for the own-unlock mint payload.
    uint8 private constant OP_ADD_LIQUIDITY = 1;
    /// @dev `GluedV4Callback`'s COLLECT op code, for the own-unlock collect payload.
    uint8 private constant OP_COLLECT_FEES = 3;
    /// @dev The hook's own HARVEST op code (its `GluedV4Callback` extension): the merged
    ///      collect + compound mint inside one unlock, handled by {harvestCallback}.
    uint8 private constant OP_HARVEST = 5;

    /// @dev Mirror of {IGlueHook.Harvested}: emitted from the hook's address under delegatecall.
    event Harvested(bytes32 indexed poolId, uint256 mainFees, uint256 secondaryFees, uint256 burned, uint256 fueled);
    /// @dev Mirror of {IGlueHook.Compounded}: emitted from the hook's address under delegatecall.
    event Compounded(bytes32 indexed poolId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used);
    /// @dev Mirror of {IGlueHook.PotInitialized}: emitted from the hook's address under delegatecall.
    event PotInitialized(bytes32 indexed poolId, address main, address secondary, address recipient);
    /// @dev Mirror of {IGlueHook.RecipientSet}: emitted from the hook's address under delegatecall.
    event RecipientSet(bytes32 indexed poolId, address recipient);
    /// @dev Mirror of {IGlueHook.ProgramCreated}: emitted from the hook's address under delegatecall.
    event ProgramCreated(bytes32 indexed poolId, address indexed owner, int24 tickLower, int24 tickUpper);
    /// @dev Mirror of {IGlueHook.ProgramConfigured}: emitted from the hook's address under delegatecall.
    event ProgramConfigured(bytes32 indexed poolId, IGlueHook.ProgramConfig config);
    /// @dev Mirror of {IGlueHook.ProgramLiquidityAdded}: emitted from the hook's address under delegatecall.
    event ProgramLiquidityAdded(bytes32 indexed poolId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used);
    /// @dev Mirror of {IGlueHook.ProgramOperatorSet}: emitted from the hook's address under delegatecall.
    event ProgramOperatorSet(bytes32 indexed poolId, address indexed newOperator);
    /// @dev Mirror of {IGlueHook.ProgramOwnershipTransferred}: emitted from the hook's address under delegatecall.
    event ProgramOwnershipTransferred(bytes32 indexed poolId, address indexed newOwner);
    /// @dev Mirror of {IGlueHook.Delivered}: emitted from the hook's address under delegatecall.
    event Delivered(bytes32 indexed poolId, address indexed to, uint256 amount, IGlueHook.Delivery mode);
    /// @dev Mirror of {IGlueHook.Paid}: emitted from the hook's address under delegatecall.
    event Paid(address indexed to, address indexed asset, uint256 amount);
    /// @dev Mirror of {IGlueHook.Owed}: emitted from the hook's address under delegatecall.
    event Owed(address indexed to, address indexed asset, uint256 amount);
    /// @dev Mirror of {IGlueHook.FlushedDirect}: emitted from the hook's address under delegatecall.
    event FlushedDirect(bytes32 indexed poolId, address indexed to, uint256 amount);

    /// @dev Mirror of {IGlueHook.HarvestRecorded}: emitted from the hook's address under delegatecall.
    event HarvestRecorded(bytes32 indexed poolId, address indexed engine, uint256 deliveredMain, uint256 deliveredSec, bool recorded);

    /// @dev The Glue Protocol's GlueStick singleton (mirror of the hook's {GlueHook.GLUE_STICK}):
    ///      the SAME address on every chain. Pot creation classifies the main through its registry
    ///      (`wrapperOf`) and ensures the main's glue exists through it (best effort); the burn
    ///      itself then talks to the main's GlueWrapper directly. Program creation asks it whether
    ///      the creator is a REGISTERED LP engine (`isRegisteredEngine`) to stamp NATIVE programs.
    address private constant GLUE_STICK = 0x32b926e7D6ac6B92e50dF40dDfd3555691bc8b3b;

    /// @dev The hook's transient PAYER slot: `keccak256("GlueHook.payer")`. While set — only ever
    ///      around a liquidity add's unlock — the hook's `_transferToken` settles ERC20 legs straight
    ///      from this address. Transient storage is the hook's own under delegatecall, so the literal
    ///      MUST match the hook's.
    bytes32 private constant PAYER_SLOT = 0x1bde310958327eb1c8a9046a2bb97d1e21ae8a0e23960bbeb793bdf7f87b6f8b;

    // ── Pump sizing parameters (the hook re-exports the public ones) ────────────────

    /// @dev The spend bucket's TIME base: one fee ceiling per this long with no volume at all.
    uint32 internal constant PUMP_REFILL = 30 minutes;
    /// @dev The spend bucket's VOLUME credit: `k ×` the fee each funded swap pays.
    uint256 internal constant PUMP_FEE_LEVERAGE = 4;
    /// @dev The largest share of a swap's secondary the pump matches (60%).
    uint256 internal constant PUMP_SHARE_MAX_WAD = 0.6e18;
    /// @dev Share of the capped spend the pump actually uses (80%).
    uint256 internal constant PUMP_HAIRCUT_BPS = 8_000;
    /// @dev Basis-point denominator.
    uint256 private constant BPS = 10_000;
    /// @dev V4 fee denominator (a fee is in millionths).
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    /// @dev Millionths to WAD.
    uint256 private constant FEE_TO_WAD = PRECISION / FEE_DENOMINATOR;
    /// @dev Rounding allowance on the pump's own output floor (one part in a million).
    uint256 private constant MIN_OUT_SHAVE = 1e6;

    // ═══════════════════════════════════════════════════════════════════════════════
    // PUMP SIZING
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Size the pump and derive its own output floor (the hook's `_pumpSize` body; see the
     *         hook for the four ceilings' derivation). Pure arithmetic over the pool's live state and
     *         the pot's bucket — nothing in here can revert on any input the hook can hand it.
     * @param pm The PoolManager.
     * @param key The pool key.
     * @param id The pool identifier.
     * @param p The pool's pot (its balance, main and bucket are read).
     * @param slot0 The pool's live slot0 — the state the swapper's trade left behind.
     * @param demand Secondary the carrying swap moved.
     * @param refX8 The reference tick as it stands now, in 1/256ths.
     * @return spend Secondary to spend on the pump.
     * @return minOut Output floor for the pump's own swap.
     * @return bucketCredited The bucket timestamp after this swap's volume credit, before any spend
     *         — what to store when the pump does not run or reverts.
     * @return bucketAfter The bucket timestamp after the credit AND this spend — what to store once
     *         the pump has gone through.
     */
    function pumpSize(
        address pm,
        IPoolManagerMin.PoolKey calldata key,
        bytes32 id,
        IGlueHook.Pot storage p,
        GluedV4Core.Slot0 memory slot0,
        uint256 demand,
        int32 refX8
    ) external view returns (uint256 spend, uint256 minOut, uint32 bucketCredited, uint32 bucketAfter) {
        uint256 pot = p.balance;
        // No pot, or no flow to size against
        if (pot == 0 || demand == 0) return (0, 0, 0, 0);
        // Buying main means selling secondary: zeroForOne exactly when main is currency1
        bool zeroForOne = p.main != key.currency0;
        // `slot0.lpFee`, never `key.fee`: Slot0 is the fee the pool actually charges (and it
        // composes with the protocol fee in {GluedV4Core.swapFee}).
        uint24 fee = GluedV4Core.swapFee(slot0.protocolFee, slot0.lpFee, zeroForOne);

        // 1. The fee ceiling: f·R on the side the pot spends
        // The secondary is the input, so it is currency0 exactly when the pump swaps zeroForOne
        uint256 depth = GluedV4Core.tangentReserve(
            slot0.sqrtPriceX96, GluedV4Core.getPoolLiquidity(pm, id), zeroForOne
        );
        uint256 feeCap = GluedMath.md512(depth, fee, FEE_DENOMINATOR);
        // A pool with no depth, or a zero-fee pool, can never host a pump that cannot be sandwiched
        if (feeCap == 0) return (0, 0, 0, 0);

        // 2. The spend bucket. Its level is kept as the seconds of time-refill it is worth, so a
        // volume credit of `k·f·demand` (a share `k·demand/depth` of the ceiling) is
        // `k·demand·PUMP_REFILL/depth` seconds, and the level is clamped at one ceiling. Wrapping
        // uint32 arithmetic; a pot no pump has drawn on yet (timestamp zero) reads as full.
        uint256 budget;
        {
            uint32 last = p.pumpBucketTimestamp;
            uint256 level; // in seconds of refill
            unchecked { level = uint32(block.timestamp) - last; }
            if (last == 0 || level >= PUMP_REFILL) level = PUMP_REFILL;
            else {
                uint256 credit = GluedMath.md512(PUMP_FEE_LEVERAGE * demand, PUMP_REFILL, depth);
                level = credit >= PUMP_REFILL - level ? PUMP_REFILL : level + credit;
            }
            bucketCredited = _stamp(level);
            budget = feeCap * level / PUMP_REFILL;
        }
        spend = pot < budget ? pot : budget;

        // 3 + 4. The demand ceiling, at the share the reference gate allows at this spot
        uint256 demandCap =
            GluedMath.md512(demand, pumpShare(slot0.tick, refX8, fee, !zeroForOne), PRECISION);
        if (demandCap < spend) spend = demandCap;

        // Strictly inside whichever ceiling won
        spend = GluedMath.md512(spend, PUMP_HAIRCUT_BPS, BPS);
        if (spend != 0) {
            ( , minOut) = GluedV4Core.quoteSwapStep(pm, key, zeroForOne, -int256(spend));
            // Rounding allowance on a same-transaction quote of the pool's own arithmetic
            minOut -= minOut / MIN_OUT_SHAVE;
        }
        // Without a pool-exact quote there is no floor to enforce, so there is no pump
        if (minOut == 0) return (0, 0, bucketCredited, bucketCredited);

        // The bucket after this spend: what is left of the budget, expressed as the time it would
        // have taken to refill — `budget − spend ≤ feeCap`, so this sits within PUMP_REFILL of now
        bucketAfter = _stamp((budget - spend) * PUMP_REFILL / feeCap);
    }

    /**
     * @notice The reference gate's share: the fraction of the carrying swap's secondary the pump
     *         may match at this spot.
     * @dev `d` is MAIN's premium over the reference, `1.0001^Δ − 1` for the tick gap `Δ` oriented
     *      so that a positive gap is a dearer main: a V4 tick is the log-price of currency0 in
     *      currency1, so the gap is `spot − ref` when main is currency0 (main's price rises with
     *      the tick) and `ref − spot` when main is currency1 (its reciprocal). The reference is
     *      rounded to the whole tick on the side that makes the gap read a hair LARGER — the strict
     *      side. At or below the reference the share is {PUMP_SHARE_MAX_WAD}; above it, `f / d`
     *      capped there. `f/d`, not `2f/d`: a pusher's round trip costs `2f` per unit pushed, but
     *      BOTH its legs summon pumps at the premium — the push itself and the dump — so the demand
     *      the attacker presents at the premium is TWICE what they pushed, and the share that puts
     *      the round trip at break-even is `f/d`. Pure and bounded: the gap is clamped to the tick
     *      range, so nothing in here can revert.
     * @param spotTick The pool's live tick.
     * @param refX8 The reference tick in 1/256ths.
     * @param fee The pool's live composed fee in millionths, in the pump's direction.
     * @param mainIsZero True when main is `currency0`.
     * @return shareWad The share (1e18 = 100%).
     */
    function pumpShare(int24 spotTick, int32 refX8, uint24 fee, bool mainIsZero)
        public pure returns (uint256 shareWad)
    {
        // The arithmetic shift floors the reference; the ceiling is one above whenever a fraction
        // was cut. Main-is-currency0 wants the floor (a lower reference = a larger gap), main-is-
        // currency1 the ceiling — either way the premium is never under-stated.
        int256 ref = int256(refX8) >> 8;
        int256 above;
        if (mainIsZero) {
            above = int256(spotTick) - ref;
        } else {
            if (refX8 & 0xFF != 0) ++ref;
            above = ref - int256(spotTick);
        }
        // At or below the reference: no premium to sell into, full share
        if (above <= 0) return PUMP_SHARE_MAX_WAD;
        // Clamp into the tick range the sqrt-ratio port accepts (a premium this large is a share of
        // effectively nothing anyway)
        if (above > int256(GluedV4Core.MAX_USABLE_TICK)) above = int256(GluedV4Core.MAX_USABLE_TICK);

        // ratio = 1.0001^above in WAD, from its Q64.96 square root
        uint256 sqrtRatioX96 = GluedV4Core.getSqrtRatioAtTick(int24(above));
        uint256 ratioWad = GluedMath.md512(
            GluedMath.md512(sqrtRatioX96, sqrtRatioX96, GluedV4Core.Q96), PRECISION, GluedV4Core.Q96
        );
        // One tick above already reads > 1.0001 in WAD, so the premium is strictly positive here
        if (ratioWad <= PRECISION) return PUMP_SHARE_MAX_WAD;
        uint256 premiumWad = ratioWad - PRECISION;

        // s = f / d
        shareWad = GluedMath.md512(uint256(fee) * FEE_TO_WAD, PRECISION, premiumWad);
        if (shareWad > PUMP_SHARE_MAX_WAD) shareWad = PUMP_SHARE_MAX_WAD;
    }

    /// @dev A bucket level (seconds of refill it is worth, at most PUMP_REFILL) as the timestamp
    ///      that encodes it. Zero is the never-drawn sentinel, so a level that lands there is
    ///      written one second off — nothing.
    function _stamp(uint256 level) private view returns (uint32 ts) {
        unchecked { ts = uint32(block.timestamp) - uint32(level); }
        if (ts == 0) ts = 1;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // POT ROLES
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice The one-shot role declaration (the hook's {IGlueHook-initPot} body). Admin-gated
     *         (`msg.sender` is the original caller under delegatecall), one of the pool's own
     *         currencies becomes MAIN and the other SECONDARY. MAIN must be GLUEABLE — never the
     *         network token and never the chain's canonical wrapped native — because every burn is
     *         a pure Glue unglue. The declaration then CLASSIFIES the main through the GlueStick's
     *         registry: a GlueWrapper main (the ERC20 face of a glued ERC20 or ERC721 collection)
     *         is recorded as its own glue — its burn is a PARK on itself — and any other main is
     *         recorded with its canonical wrapper, created on the spot when missing. Both reads are
     *         best effort: a refusal never blocks the pool (the glue is retried once at the first
     *         burn, and later burns settle to the held ledger).
     * @param p The pool's pot.
     * @param L The hook's delivery/attribution ledgers (the glue registry lives there).
     * @param key The pool key.
     * @param id The pool identifier.
     * @param main The currency to defend.
     * @param recipient The delivery target (`address(0)` = burn).
     * @param nativeWrap The chain's canonical wrapped native (the hook's {GlueHook.NATIVEWRAP}).
     */
    function initPot(
        IGlueHook.Pot storage p,
        IGlueHook.Ledgers storage L,
        IPoolManagerMin.PoolKey calldata key,
        bytes32 id,
        address main,
        address recipient,
        address nativeWrap
    ) external {
        // A pool that never ran through the hook's `beforeInitialize` has no admin and no pot
        if (p.admin == address(0)) revert IGlueHook.PotNotReady();
        if (msg.sender != p.admin) revert IGlueHook.NotAllowed();
        // Roles are declared once and never move
        if (p.configured) revert IGlueHook.PotAlreadyReady();
        // Main must be one of the pool's own currencies; the other side becomes the buyback currency
        if (main != key.currency0 && main != key.currency1) revert IGlueHook.BadRoles();
        // MAIN must be glueable: the burn path is Glue's unglue, and neither the network token nor
        // its canonical wrapper can ever run it (Glue rejects the wrapper by design). On a chain
        // with no wrapped native, `nativeWrap` is `address(0)` — already covered by the first test.
        if (main == address(0) || main == nativeWrap) revert IGlueHook.BadRoles();

        address secondary = main == key.currency0 ? key.currency1 : key.currency0;
        p.main = main;
        p.secondary = secondary;
        // `address(0)` is stored verbatim and MEANS "burn": a pure Glue unglue (falling through to
        // held-forever) runs instead of a plain transfer. Any other value is a literal delivery target.
        p.recipient = recipient;
        p.configured = true;

        // Classify the main once, from the GlueStick's own registry (only the Stick writes it, so
        // the asset cannot fake the answer): a GlueWrapper resolves to ITSELF, a glued sticky to
        // its wrapper, an unglued asset to zero — then ensure the glue of an unglued main so burns
        // route through Glue from the first swap. Both are tolerated failures: a chain without the
        // GlueStick, or a main Glue refuses to admit, never blocks the pool (the first burn retries
        // the ensure once, then settles to the held ledger).
        if (L.glue[main] == address(0)) {
            address glue = _wrapperOf(main);
            if (glue == address(0)) glue = _tryEnsure(main);
            if (glue != address(0)) L.glue[main] = glue;
        }

        emit PotInitialized(id, main, secondary, recipient);
    }

    /**
     * @notice Move the pot's delivery target (the hook's {IGlueHook-setRecipient} body).
     *         Admin-gated; `address(0)` restores the burn behaviour (a main is always glueable —
     *         {initPot} enforced it — so burn intent is always a legal target).
     * @param p The pool's pot.
     * @param poolId The pool identifier.
     * @param recipient The new target (`address(0)` restores the burn behaviour).
     */
    function setRecipient(IGlueHook.Pot storage p, bytes32 poolId, address recipient) external {
        // Only a live pot has a recipient to move
        if (!p.configured) revert IGlueHook.PotNotReady();
        if (msg.sender != p.admin) revert IGlueHook.NotAllowed();

        p.recipient = recipient;
        emit RecipientSet(poolId, recipient);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Validate a split config and write it into the program. Every share is a fraction of
     *         the GROSS fees of its side, so legality is per side: the two shares that can claim a
     *         side (`compound + buyback` on the secondary, `compound + burn` on the main) must sum
     *         to at most 100%, and a side whose shares sum below 100% must name a live recipient,
     *         because a remainder can exist there. A burn share is always legal: {initPot}
     *         guaranteed the main is glueable, so the Glue burn path is always runnable.
     * @dev A config edit only shapes FUTURE harvests: nothing already split or carried is re-touched.
     * @param g The pool's program.
     * @param cfg The split rules to validate and store.
     */
    function applyConfig(IGlueHook.Program storage g, IGlueHook.ProgramConfig memory cfg)
        external
    {
        _applyConfig(g, cfg);
    }

    /**
     * @notice Hand off or freeze the rules role (the hook's {IGlueHook-setProgramOperator} body).
     *         Operator-gated; `address(0)` freezes the rules forever — the OWNER's property is
     *         untouched either way.
     * @param g The pool's program.
     * @param poolId The pool identifier.
     * @param newOperator The new operator (`address(0)` = frozen forever).
     */
    function setOperator(IGlueHook.Program storage g, bytes32 poolId, address newOperator) external {
        if (!g.exists) revert IGlueHook.PotNotReady();
        // A zeroed operator role means frozen forever, since `msg.sender` is never zero
        if (msg.sender != g.operator) revert IGlueHook.NotAllowed();
        g.operator = newOperator;
        emit ProgramOperatorSet(poolId, newOperator);
    }

    /**
     * @notice Move the property role (the hook's {IGlueHook-transferProgramOwnership} body).
     *         Owner-gated. Surrendering the property (`address(0)`) locks the liquidity forever by
     *         construction — `msg.sender` matches nobody — so the harvest gate opens for good: an
     *         ownerless program must never be manually unharvestable. A NATIVE program's owner is
     *         its engine forever: the transfer is refused.
     * @param g The pool's program.
     * @param poolId The pool identifier.
     * @param newOwner The new owner (`address(0)` = surrendered).
     */
    function transferOwnership(IGlueHook.Program storage g, bytes32 poolId, address newOwner) external {
        if (!g.exists) revert IGlueHook.PotNotReady();
        if (msg.sender != g.owner) revert IGlueHook.NotAllowed();
        // NATIVE: the property is pinned to the creating engine — no transfer, no surrender
        if (g.native) revert IGlueHook.NotAllowed();
        g.owner = newOwner;
        if (newOwner == address(0)) g.publicHarvest = true;
        emit ProgramOwnershipTransferred(poolId, newOwner);
    }

    /// @dev {applyConfig}'s body, shared with {createProgram}.
    function _applyConfig(IGlueHook.Program storage g, IGlueHook.ProgramConfig memory cfg)
        private
    {
        uint256 secClaim = uint256(cfg.compoundShareWad) + cfg.buybackShareWad;
        uint256 mainClaim = uint256(cfg.compoundShareWad) + cfg.burnShareWad;
        if (secClaim > PRECISION || mainClaim > PRECISION) revert IGlueHook.BadConfig();
        if (secClaim < PRECISION && cfg.secondaryRecipient == address(0)) revert IGlueHook.BadConfig();
        if (mainClaim < PRECISION && cfg.mainRecipient == address(0)) revert IGlueHook.BadConfig();
        // NATIVE: both remainder recipients are pinned to the engine (the owner); the operator may
        // still edit every share, the public-harvest flag and the auto-harvest minimums
        if (g.native && (cfg.mainRecipient != g.owner || cfg.secondaryRecipient != g.owner)) {
            revert IGlueHook.BadConfig();
        }

        // THE BUYBACK SPLIT: the pot's output is carved like a fee side — compound + burn ≤ 100%,
        // the exact rest following the pot's recipient. No recipient rule here: the remainder's
        // destination is the POT's recipient, which always has defined semantics (a live address
        // delivers, `address(0)` burns — always runnable on an initPot-validated main).
        uint256 potClaim = uint256(cfg.potCompoundShareWad) + cfg.potBurnShareWad;
        if (potClaim > PRECISION) revert IGlueHook.BadConfig();

        g.buybackShareWad = cfg.buybackShareWad;
        g.burnShareWad = cfg.burnShareWad;
        g.compoundShareWad = cfg.compoundShareWad;
        g.potCompoundShareWad = cfg.potCompoundShareWad;
        g.potBurnShareWad = cfg.potBurnShareWad;
        // An ownerless program stays force-opened whatever the stored config says: with no owner to
        // pass the gate, a closed manual harvest would strand fees the auto-trigger never reaches
        g.publicHarvest = cfg.publicHarvest || g.owner == address(0);
        g.secondaryRecipient = cfg.secondaryRecipient;
        g.mainRecipient = cfg.mainRecipient;
        g.minMain = cfg.minMain;
        g.minSecondary = cfg.minSecondary;
        // The auto-harvest is armed as soon as ONE side has a real min: the per-swap gate reads
        // this bit off the program's first slot and skips the pending-fee scan entirely otherwise
        g.armed = cfg.minMain != type(uint256).max || cfg.minSecondary != type(uint256).max;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PROGRAM CREATION & LIQUIDITY
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Create a pool's program and seed its liquidity (the shared body of the hook's
     *         {IGlueHook-addLiquidity}, {IGlueHook-addLiquidityAdvanced} and {IGlueHook-launchPool}).
     *         Gated to the pot admin (`msg.sender` is the original caller under delegatecall), one
     *         program per pool, config validated here. The tick range is resolved (sentinel `(0,0)`
     *         = full range) and fixed forever: the position's identity in the PoolManager is
     *         (hook, ticks, salt), so a moving range would orphan the fees. A creator the GlueStick
     *         reports as a REGISTERED LP engine stamps the program NATIVE: owner and both remainder
     *         recipients are forced to the engine (the passed `owner` and recipients are ignored),
     *         and every later harvest reports to it ({place}). Any other creator takes the plain
     *         path unchanged — a codeless or foreign Stick never blocks creation.
     * @param p The pool's pot.
     * @param g The pool's program slot.
     * @param pm The PoolManager.
     * @param id The pool identifier.
     * @param key The pool key.
     * @param tickLower Lower tick, `(0,0)` = full range.
     * @param tickUpper Upper tick.
     * @param liquidity Liquidity units to mint.
     * @param owner The program's owner and first operator (`address(0)` = surrendered at birth).
     * @param cfg The split rules to store.
     * @return amount0 Currency0 the position consumed.
     * @return amount1 Currency1 the position consumed.
     */
    function createProgram(
        IGlueHook.Pot storage p,
        IGlueHook.Program storage g,
        address pm,
        bytes32 id,
        IPoolManagerMin.PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address owner,
        IGlueHook.ProgramConfig memory cfg
    ) external returns (uint256 amount0, uint256 amount1) {
        // The pot's roles ARE the split's two sides, so a program cannot precede them
        if (!p.configured) revert IGlueHook.PotNotReady();
        // The pot admin owns the pool's one program slot — nobody can front-run the split rules
        if (msg.sender != p.admin) revert IGlueHook.NotAllowed();
        // ONE program per pool, forever
        if (g.exists) revert IGlueHook.PotAlreadyReady();

        // Resolve the sentinel before storing: every later read uses the REAL ticks
        if (tickLower == 0 && tickUpper == 0) {
            (tickLower, tickUpper) = GluedV4Core.fullRangeTicks(key.tickSpacing);
        }

        // NATIVE stamping: a registered Glue LP engine creating the program is pinned as its owner
        // and both remainder recipients, once and forever
        if (_isRegisteredEngine(msg.sender)) {
            g.native = true;
            owner = msg.sender;
            cfg.mainRecipient = msg.sender;
            cfg.secondaryRecipient = msg.sender;
        }

        g.exists = true;
        g.owner = owner;
        // The owner starts as its own settings editor; hand off or zero it with setProgramOperator
        g.operator = owner;
        g.tickLower = tickLower;
        g.tickUpper = tickUpper;
        _applyConfig(g, cfg);

        emit ProgramCreated(id, owner, tickLower, tickUpper);
        emit ProgramConfigured(id, cfg);
        return _mint(g, pm, id, key, liquidity);
    }

    /**
     * @notice Mint `liquidity` units into an EXISTING program's position, funded by the caller (the
     *         hook's {IGlueHook-addProgramLiquidity} body — the owner gate and the harvest-first rule
     *         run in the resident hook before this).
     * @param g The pool's program.
     * @param pm The PoolManager.
     * @param id The pool identifier.
     * @param key The pool key.
     * @param liquidity Liquidity units to mint.
     * @return amount0 Currency0 the position consumed.
     * @return amount1 Currency1 the position consumed.
     */
    function mintLiquidity(
        IGlueHook.Program storage g,
        address pm,
        bytes32 id,
        IPoolManagerMin.PoolKey calldata key,
        uint128 liquidity
    ) external returns (uint256 amount0, uint256 amount1) {
        return _mint(g, pm, id, key, liquidity);
    }

    /**
     * @dev The mint itself. The unlock runs the hook's own ADD handler; while it settles, the
     *      transient PAYER is set so an ERC20 leg is pulled straight from the caller to the
     *      PoolManager at the EXACT amount owed — no estimate, no refund, and never a wei of the
     *      hook's own inventory. A native leg (always `currency0`) is prepaid by the attached value
     *      (preserved by delegatecall), checked as a hard cap afterwards and the excess returned; a
     *      pool with no native side must attach none.
     * @param g The pool's program.
     * @param pm The PoolManager.
     * @param id The pool identifier.
     * @param key The pool key.
     * @param liquidity Liquidity units to mint.
     * @return amount0 Currency0 the position consumed.
     * @return amount1 Currency1 the position consumed.
     */
    function _mint(
        IGlueHook.Program storage g,
        address pm,
        bytes32 id,
        IPoolManagerMin.PoolKey calldata key,
        uint128 liquidity
    ) private returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) revert IGlueHook.BadConfig();
        // A pool with no native side must carry no value — the hook's own ETH is pot money
        bool nativeSide = key.currency0 == address(0);
        if (!nativeSide && msg.value != 0) revert IGlueHook.BadDonation();

        // ERC20 legs settle straight from the caller while the payer is set
        assembly ("memory-safe") { tstore(PAYER_SLOT, caller()) }
        bytes memory ret = IPoolManagerMin(pm).unlock(
            abi.encode(
                OP_ADD_LIQUIDITY,
                key,
                int256(uint256(liquidity)),
                GluedV4Core.positionSalt(address(this)),
                g.tickLower,
                g.tickUpper
            )
        );
        assembly ("memory-safe") { tstore(PAYER_SLOT, 0) }

        (int128 d0, int128 d1) = abi.decode(ret, (int128, int128));
        amount0 = d0 < 0 ? uint256(uint128(-d0)) : 0;
        amount1 = d1 < 0 ? uint256(uint128(-d1)) : 0;

        // Book before the refund — the only external call left in the frame
        g.liquidity += liquidity;
        emit ProgramLiquidityAdded(id, liquidity, amount0, amount1);

        // The attached value is a hard cap on the native leg; the unused excess goes back
        if (nativeSide) {
            if (amount0 > msg.value) revert IGlueHook.BadDonation();
            if (msg.value > amount0) Address.sendValue(payable(msg.sender), msg.value - amount0);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // HARVEST — the merged collect + compound
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice The harvest's body (shared by the hook's in-swap {executeHarvest} self-call and its
     *         manual {_harvestInto}): collect the program's fees, split them, and re-mint the
     *         compound budget — in ONE `modifyLiquidity` whenever there is something to mint.
     * @dev The fees are KNOWN before the position is touched (`f0`/`f1`: the hook's pending-fee
     *      scan, the same formula V4 runs in `Position.update`), so the compound budget — this
     *      harvest's slice plus the standing carry — can be sized and minted in the SAME call that
     *      collects: V4 credits the fees and debits the mint against one delta per currency, and
     *      only the NET moves (a take when the fees exceed the mint's cost, a settle from the
     *      hook's carry when they do not). The compounded slice never leaves the PoolManager and
     *      the second `modifyLiquidity` + its two takes are gone. The merged call self-verifies
     *      against `feesAccrued` — V4's own fee number for the position — and against the budget
     *      (the mint may never consume more than the slice + carry): any violation reverts the
     *      frame. In-swap that revert is caught by the hook's self-call, which re-runs the harvest
     *      with `mint == false`; manual, the own-unlock is try/caught here. Either way the
     *      fallback is the COLLECT-ONLY path (a zero-delta `modifyLiquidity`, fees read off V4's
     *      credit rather than the scan): the harvest lands, the whole compound budget waits in the
     *      carry — exactly the outcome a failed compound had before the merge.
     *
     *      EVERY leg is a fraction of the GROSS of its side: the compound budget and the
     *      buyback/burn shares are computed from the same base, and each recipient leg is the
     *      exact remainder (`gross − compound − share`), never a second multiplication — the legs
     *      sum to the harvest byte-for-byte. What the mint does not consume is saved back into the
     *      carry and retried at every next harvest, never leaking to the pot or a recipient. The
     *      pot's buyback share is credited HERE — bookkeeping only — and the outbound legs are
     *      returned for the hook's send phase, so every send in the frame happens after every write.
     * @param p The pool's pot (credited with the buyback share).
     * @param g The pool's program.
     * @param L The hook's delivery/attribution ledgers.
     * @param pm The PoolManager.
     * @param id The pool identifier.
     * @param key The pool key.
     * @param f0 Pending currency0 fees per the hook's scan (ignored on the collect-only path).
     * @param f1 Pending currency1 fees per the hook's scan (ignored on the collect-only path).
     * @param inUnlock True when the PoolManager is already unlocked (the in-swap frame).
     * @param mint True to attempt the merged compound mint; false forces the collect-only path.
     * @return fMain Fees collected on the main side.
     * @return fSec Fees collected on the secondary side.
     * @return burnLeg Main-side slice for the burn cascade.
     * @return mainLeg Main-side slice for the program's main recipient.
     * @return secLeg Secondary-side slice for the program's secondary recipient.
     */
    function harvest(
        IGlueHook.Pot storage p,
        IGlueHook.Program storage g,
        IGlueHook.Ledgers storage L,
        address pm,
        bytes32 id,
        IPoolManagerMin.PoolKey calldata key,
        uint256 f0,
        uint256 f1,
        bool inUnlock,
        bool mint
    ) external returns (uint256 fMain, uint256 fSec, uint256 burnLeg, uint256 mainLeg, uint256 secLeg) {
        // A zero-fee harvest still retries a standing carry; with neither there is nothing to do.
        // (Without `mint` the scan may not have run — the collect below is the fee source then.)
        if (mint && (f0 | f1 | g.carryMain | g.carrySecondary) == 0) return (0, 0, 0, 0, 0);

        bool mainIsZero = p.main == key.currency0;
        // ONE position touch: the merged collect + mint, or the plain collect
        uint256 used0;
        uint256 used1;
        (f0, f1, used0, used1) = _touch(g, pm, id, key, f0, f1, mainIsZero, inUnlock, mint);
        if ((f0 | f1 | g.carryMain | g.carrySecondary) == 0) return (0, 0, 0, 0, 0);

        (fMain, fSec) = mainIsZero ? (f0, f1) : (f1, f0);
        (burnLeg, mainLeg, secLeg) = mainIsZero
            ? _split(p, g, L, id, fMain, fSec, used0, used1)
            : _split(p, g, L, id, fMain, fSec, used1, used0);
    }

    /**
     * @dev The harvest's single position touch. With `mint`, the compound budget — this harvest's
     *      slice off the scanned fees plus the standing carry, per currency — is sized into
     *      liquidity at the live price and minted in the SAME `modifyLiquidity` that collects the
     *      fees ({_mintNetting}); a budget that funds nothing, a `mint == false` call, or a manual
     *      merged mint that failed its guard fall to the plain zero-delta collect, whose fees are
     *      read off V4's own credit.
     * @return c0 Currency0 fees collected (the scan, confirmed, on the merged path).
     * @return c1 Currency1 fees collected.
     * @return used0 Currency0 the mint cost (zero on the collect-only path).
     * @return used1 Currency1 the mint cost.
     */
    function _touch(
        IGlueHook.Program storage g,
        address pm,
        bytes32 id,
        IPoolManagerMin.PoolKey calldata key,
        uint256 f0,
        uint256 f1,
        bool mainIsZero,
        bool inUnlock,
        bool mint
    ) private returns (uint256 c0, uint256 c1, uint256 used0, uint256 used1) {
        if (mint) {
            (uint256 b0, uint256 b1) = _budgets(g, f0, f1, mainIsZero);
            uint128 liq = (b0 | b1) == 0 ? 0 : _liquidityForFees(pm, g, id, b0, b1);
            if (liq != 0) {
                bool ok;
                (ok, used0, used1) = _mintNetting(g, pm, key, liq, f0, f1, b0, b1, inUnlock);
                if (ok) {
                    g.liquidity += liq;
                    emit Compounded(id, liq, used0, used1);
                    return (f0, f1, used0, used1);
                }
            }
        }
        // The plain collect: nothing minted, the whole budget will be carried
        (c0, c1) = inUnlock ? _collectInSwap(pm, g, key) : _collectOwnUnlock(pm, g, key);
    }

    /// @dev The compound budget per CURRENCY: the compound share of each side's scanned fees plus
    ///      that side's standing carry.
    function _budgets(IGlueHook.Program storage g, uint256 f0, uint256 f1, bool mainIsZero)
        private view returns (uint256 b0, uint256 b1)
    {
        uint256 cw = g.compoundShareWad;
        (uint256 carry0, uint256 carry1) =
            mainIsZero ? (g.carryMain, g.carrySecondary) : (g.carrySecondary, g.carryMain);
        b0 = GluedMath.md512(f0, cw, PRECISION) + carry0;
        b1 = GluedMath.md512(f1, cw, PRECISION) + carry1;
    }

    /**
     * @dev THE SPLIT off the gross of each side, the carry bookkeeping and the pot credit — every
     *      write of the harvest, no send. The recipients take the exact remainders; whatever the
     *      mint did not place (all of the budget on the collect-only path) goes back into the
     *      carry — LP-ing is retried forever, never rerouted.
     * @param uMain Main the mint cost.
     * @param uSec Secondary the mint cost.
     */
    function _split(
        IGlueHook.Pot storage p,
        IGlueHook.Program storage g,
        IGlueHook.Ledgers storage L,
        bytes32 id,
        uint256 fMain,
        uint256 fSec,
        uint256 uMain,
        uint256 uSec
    ) private returns (uint256 burnLeg, uint256 mainLeg, uint256 secLeg) {
        uint256 cMain = GluedMath.md512(fMain, g.compoundShareWad, PRECISION);
        uint256 cSec = GluedMath.md512(fSec, g.compoundShareWad, PRECISION);
        uint256 buyLeg = GluedMath.md512(fSec, g.buybackShareWad, PRECISION);
        burnLeg = GluedMath.md512(fMain, g.burnShareWad, PRECISION);
        secLeg = fSec - cSec - buyLeg;
        mainLeg = fMain - cMain - burnLeg;

        // THE CARRY: this harvest's slice plus everything carried, minus what the mint placed
        uint256 budgetMain = cMain + g.carryMain;
        uint256 budgetSec = cSec + g.carrySecondary;
        if ((budgetMain | budgetSec) != 0) {
            L.carryTotal[p.main] = L.carryTotal[p.main] + (budgetMain - uMain) - g.carryMain;
            L.carryTotal[p.secondary] = L.carryTotal[p.secondary] + (budgetSec - uSec) - g.carrySecondary;
            g.carryMain = budgetMain - uMain;
            g.carrySecondary = budgetSec - uSec;
        }

        if (buyLeg != 0) {
            p.balance += buyLeg;
            L.potTotal[p.secondary] += buyLeg;
        }

        emit Harvested(id, fMain, fSec, burnLeg, buyLeg);
    }

    /**
     * @notice The HARVEST unlock's callback body (the hook's `GluedV4Callback` extension for
     *         {OP_HARVEST}, reached from the manual path's own unlock): the merged mint, verified
     *         and settled inside the unlock frame so a violation reverts the whole unlock — which
     *         {harvest} catches and answers with the collect-only path.
     * @param pm The PoolManager.
     * @param params The op payload: `(key, liquidity, salt, tickLower, tickUpper, f0, f1, b0, b1)`.
     * @return ABI-encoded `(used0, used1)` — what the mint really cost per currency.
     */
    function harvestCallback(address pm, bytes memory params) external returns (bytes memory) {
        (
            IPoolManagerMin.PoolKey memory key,
            int256 liquidityDelta,
            bytes32 salt,
            int24 tickLower,
            int24 tickUpper,
            uint256 f0,
            uint256 f1,
            uint256 b0,
            uint256 b1
        ) = abi.decode(params, (IPoolManagerMin.PoolKey, int256, bytes32, int24, int24, uint256, uint256, uint256, uint256));

        (int256 callerDelta, int256 feesAccrued) = IPoolManagerMin(pm).modifyLiquidity(
            key,
            IPoolManagerMin.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
            }),
            ""
        );
        (uint256 used0, uint256 used1) = _settleMerged(pm, key, callerDelta, feesAccrued, f0, f1, b0, b1);
        return abi.encode(used0, used1);
    }

    /**
     * @dev The merged mint: ONE `modifyLiquidity(+liq)` that collects the fees and pays the mint
     *      out of them. In-swap the PoolManager is already unlocked, so the call is direct and a
     *      violation reverts the frame (the hook's self-call catches it). Manual, it opens the
     *      hook's own HARVEST unlock, try/caught here: a failure reports `ok == false` and the
     *      caller falls back to the collect-only path.
     * @param g The pool's program (its fixed ticks identify the position).
     * @param pm The PoolManager.
     * @param key The pool key.
     * @param liq Liquidity units the compound budget funds.
     * @param f0 Scanned currency0 fees (verified against V4's `feesAccrued`).
     * @param f1 Scanned currency1 fees.
     * @param b0 Currency0 compound budget (slice + carry): the mint's cost cap.
     * @param b1 Currency1 compound budget.
     * @param inUnlock True when the PoolManager is already unlocked (the in-swap frame).
     * @return ok True when the merged mint went through (always, in-swap: a failure reverts).
     * @return used0 Currency0 the mint cost.
     * @return used1 Currency1 the mint cost.
     */
    function _mintNetting(
        IGlueHook.Program storage g,
        address pm,
        IPoolManagerMin.PoolKey calldata key,
        uint128 liq,
        uint256 f0,
        uint256 f1,
        uint256 b0,
        uint256 b1,
        bool inUnlock
    ) private returns (bool ok, uint256 used0, uint256 used1) {
        if (inUnlock) {
            (int256 callerDelta, int256 feesAccrued) = IPoolManagerMin(pm).modifyLiquidity(
                key,
                IPoolManagerMin.ModifyLiquidityParams({
                    tickLower: g.tickLower,
                    tickUpper: g.tickUpper,
                    liquidityDelta: int256(uint256(liq)),
                    salt: GluedV4Core.positionSalt(address(this))
                }),
                ""
            );
            (used0, used1) = _settleMerged(pm, key, callerDelta, feesAccrued, f0, f1, b0, b1);
            return (true, used0, used1);
        }

        // Outside any unlock (manual harvest, liquidity ops): the hook's own HARVEST unlock, whose
        // callback ({harvestCallback}) mints, verifies and settles from the hook's own balance
        try IPoolManagerMin(pm).unlock(
            abi.encode(
                OP_HARVEST,
                key,
                int256(uint256(liq)),
                GluedV4Core.positionSalt(address(this)),
                g.tickLower,
                g.tickUpper,
                f0,
                f1,
                b0,
                b1
            )
        ) returns (bytes memory ret) {
            (used0, used1) = abi.decode(ret, (uint256, uint256));
            ok = true;
        } catch {}
    }

    /**
     * @dev Verify and settle a merged `modifyLiquidity(+liq)`. V4 credits the position's fees and
     *      debits the mint's principal against ONE delta per currency, and reports the fees on
     *      their own as `feesAccrued`. Two checks, both fatal to the frame: V4's fee number must
     *      equal the scan the split was sized from (`f0`/`f1`), and the mint's cost — the fees
     *      minus the net delta — must fit the compound budget (`b0`/`b1`), so the mint can never
     *      touch a wei of pot, parked, held, owed or recipient money. Then only the NET moves: a
     *      positive leg is taken to the hook (fees beyond the mint), a negative one settled from
     *      the hook's own balance (the carry the mint is deploying, at most `b − f` per side).
     * @return used0 Currency0 the mint cost.
     * @return used1 Currency1 the mint cost.
     */
    function _settleMerged(
        address pm,
        IPoolManagerMin.PoolKey memory key,
        int256 callerDelta,
        int256 feesAccrued,
        uint256 f0,
        uint256 f1,
        uint256 b0,
        uint256 b1
    ) private returns (uint256 used0, uint256 used1) {
        (int128 d0, int128 d1) = _unpack(callerDelta);
        (int128 a0, int128 a1) = _unpack(feesAccrued);
        // V4's own fee credit must be exactly what the split was sized from
        if (a0 < 0 || a1 < 0 || uint256(uint128(a0)) != f0 || uint256(uint128(a1)) != f1) {
            revert IGlueHook.QuoteMismatch();
        }
        // The mint's cost is the fees minus the net; a mint never credits beyond the fees
        int256 c0 = int256(f0) - int256(d0);
        int256 c1 = int256(f1) - int256(d1);
        if (c0 < 0 || c1 < 0) revert IGlueHook.QuoteMismatch();
        used0 = uint256(c0);
        used1 = uint256(c1);
        // The mint may never outspend the budget; a 1-wei round-up edge abandons the compound
        if (used0 > b0 || used1 > b1) revert IGlueHook.QuoteMismatch();

        // Only the net moves, once per currency
        if (d0 > 0) IPoolManagerMin(pm).take(key.currency0, address(this), uint256(uint128(d0)));
        else if (d0 < 0) _settle(pm, key.currency0, uint256(uint128(-d0)));
        if (d1 > 0) IPoolManagerMin(pm).take(key.currency1, address(this), uint256(uint128(d1)));
        else if (d1 < 0) _settle(pm, key.currency1, uint256(uint128(-d1)));
    }

    /**
     * @dev Collect the program's accrued fees while the PoolManager is ALREADY unlocked (the
     *      in-swap frame): a direct zero-delta `modifyLiquidity`, then take both sides here.
     * @param pm The PoolManager.
     * @param g The pool's program (its fixed ticks identify the position).
     * @param key The pool key.
     * @return f0 Currency0 fees taken to the hook.
     * @return f1 Currency1 fees taken to the hook.
     */
    function _collectInSwap(address pm, IGlueHook.Program storage g, IPoolManagerMin.PoolKey calldata key)
        private returns (uint256 f0, uint256 f1)
    {
        (int256 callerDelta, ) = IPoolManagerMin(pm).modifyLiquidity(
            key,
            IPoolManagerMin.ModifyLiquidityParams({
                tickLower: g.tickLower,
                tickUpper: g.tickUpper,
                liquidityDelta: 0,
                salt: GluedV4Core.positionSalt(address(this))
            }),
            ""
        );
        (int128 d0, int128 d1) = _unpack(callerDelta);
        if (d0 > 0) {
            f0 = uint256(uint128(d0));
            IPoolManagerMin(pm).take(key.currency0, address(this), f0);
        }
        if (d1 > 0) {
            f1 = uint256(uint128(d1));
            IPoolManagerMin(pm).take(key.currency1, address(this), f1);
        }
    }

    /**
     * @dev Collect the program's accrued fees OUTSIDE any unlock (manual harvest, liquidity ops):
     *      opens the hook's own COLLECT unlock, whose callback takes both sides to the hook.
     * @param pm The PoolManager.
     * @param g The pool's program.
     * @param key The pool key.
     * @return f0 Currency0 fees taken to the hook.
     * @return f1 Currency1 fees taken to the hook.
     */
    function _collectOwnUnlock(address pm, IGlueHook.Program storage g, IPoolManagerMin.PoolKey calldata key)
        private returns (uint256 f0, uint256 f1)
    {
        // The callback lands on the hook's own `unlockCallback` (address preserved by delegatecall);
        // with no transient recipient set, its takes default to the hook - exactly where fees belong
        bytes memory ret = IPoolManagerMin(pm).unlock(
            abi.encode(
                OP_COLLECT_FEES,
                key,
                int256(0),
                GluedV4Core.positionSalt(address(this)),
                g.tickLower,
                g.tickUpper
            )
        );
        (int128 d0, int128 d1) = abi.decode(ret, (int128, int128));
        f0 = d0 > 0 ? uint256(uint128(d0)) : 0;
        f1 = d1 > 0 ? uint256(uint128(d1)) : 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PLACEMENT — the delivery engine (buyback split, cascade, payouts)
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Place every outbound leg of a frame — the ONLY sends, after ALL bookkeeping. The
     *         pot's output (`potOut` — the main a pump bought) runs the BUYBACK SPLIT
     *         first: `potCompoundShareWad` joins the program's main-side compound carry (buy
     *         pressure becoming the pool's own liquidity at the next harvest's mint),
     *         `potBurnShareWad` joins the burn cascade, and the EXACT rest follows the pot's
     *         recipient exactly as an unsplit delivery would — a live address is delivered to
     *         (park-with-retry on refusal), `address(0)` merges it into the frame's single cascade
     *         walk. A pool with NO program has zero shares by construction (a non-existent
     *         program's storage is zero), so its pot output is always delivered whole.
     * @dev Nothing here can revert the carrying swap: pushes report instead of reverting, refusals park
     *      or book, the carry credit is pure bookkeeping, and the burn cascade falls through to
     *      the terminal hold.
     * @param p The pool's pot.
     * @param g The pool's program (zero-initialised when no program exists).
     * @param L The hook's delivery/attribution ledgers.
     * @param id The pool identifier.
     * @param burnLeg Main-side harvest slice for the burn cascade.
     * @param mainLeg Main-side harvest slice for the program's main recipient.
     * @param secLeg Secondary-side harvest slice for the program's secondary recipient.
     * @param potOut The pot's output: main the pump just bought.
     */
    function place(
        IGlueHook.Pot storage p,
        IGlueHook.Program storage g,
        IGlueHook.Ledgers storage L,
        bytes32 id,
        uint256 burnLeg,
        uint256 mainLeg,
        uint256 secLeg,
        uint256 potOut
    ) external {
        // Nothing to place
        if ((burnLeg | mainLeg | secLeg | potOut) == 0) return;
        address main = p.main;

        if (potOut != 0) {
            // THE BUYBACK SPLIT — floors on the shares, so the remainder is exact and the dust
            // stays with the pot's own delivery
            uint256 comp = GluedMath.md512(potOut, g.potCompoundShareWad, PRECISION);
            uint256 potBurn = GluedMath.md512(potOut, g.potBurnShareWad, PRECISION);
            if (comp != 0) {
                // Pure bookkeeping: the leg joins the compound carry and is re-minted as the
                // pool's own liquidity by the next harvest's compound attempt — it can never leak
                // (the carry only ever becomes liquidity) and custody covers it ({obligationOf})
                g.carryMain += comp;
                L.carryTotal[main] += comp;
                emit Delivered(id, address(this), comp, IGlueHook.Delivery.COMPOUNDED);
                potOut -= comp;
            }
            if (potBurn != 0) {
                burnLeg += potBurn;
                potOut -= potBurn;
            }
            // A burn-intent pot merges the exact rest into the frame's single burn walk
            if (p.recipient == address(0)) {
                burnLeg += potOut;
                potOut = 0;
            }
        }

        // The pot's live-recipient delivery: park-with-retry on refusal
        if (potOut != 0) _deliver(p, L, id, main, potOut);
        // ONE cascade walk for every burn-intent leg of the frame
        if (burnLeg != 0) _burn(L, id, main, burnLeg);
        // The program's own harvest legs, each reporting what actually LANDED (0 when booked owed)
        uint256 dMain;
        uint256 dSec;
        if (mainLeg != 0) dMain = _payRecipient(L, g.mainRecipient, main, mainLeg);
        if (secLeg != 0) dSec = _payRecipient(L, g.secondaryRecipient, p.secondary, secLeg);

        // NATIVE: advance the delivered ledger and report the frame to the engine — AFTER every
        // send of the frame, so nothing the engine does can touch a delivery, the pot or the swap
        if (g.native) _recordHarvest(L, id, g.owner, main, p.secondary, dMain, dSec);
    }

    /**
     * @dev The native program's harvest report. The per-`(pool, asset)` DELIVERED ledger moves by
     *      exactly what landed on the engine this frame (a leg booked to `owed` counts only in the
     *      frame whose successful push folds it in), then `recordHarvest` runs with the carrying
     *      call's gas forwarded (the EVM's 63/64 rule is the only bound), its revert swallowed and
     *      its return data ignored: the callback is pure bookkeeping on the engine's side and the
     *      engine reconciles a failed one from the ledger. No gas stipend on purpose: the callee is
     *      a Glue-registered engine (pinned at pool creation), so the callback's cost is the
     *      engine's own — a fixed number baked into this immutable hook would drift with every
     *      engine upgrade and every chain gas repricing, while unused gas is refunded either way.
     *      The one consequence a broken engine (or a sticky token whose transfer burns gas inside
     *      the engine's wrap) can have is an out-of-gas swap on ITS OWN pool — the same standing
     *      Uniswap gives a hook or a token that breaks. A frame that landed nothing on the engine
     *      is not reported. Under delegatecall the engine sees `msg.sender == hook`.
     * @param L The hook's delivery/attribution ledgers.
     * @param id The pool identifier.
     * @param engine The native program's engine (its owner and both recipients).
     * @param main The pool's main currency.
     * @param secondary The pool's secondary currency.
     * @param dMain Main-side remainder delivered this frame.
     * @param dSec Secondary-side remainder delivered this frame.
     */
    function _recordHarvest(
        IGlueHook.Ledgers storage L,
        bytes32 id,
        address engine,
        address main,
        address secondary,
        uint256 dMain,
        uint256 dSec
    ) private {
        // Nothing landed: the ledger stands and the engine has nothing to attribute
        if ((dMain | dSec) == 0) return;
        if (dMain != 0) L.deliveredCum[id][main] += dMain;
        if (dSec != 0) L.deliveredCum[id][secondary] += dSec;
        // Non-bubbling report at full forwarded gas: a revert or an out-of-gas only flips the flag
        (bool ok, ) = engine.call(abi.encodeCall(IGlueHookedEngine.recordHarvest, (id, dMain, dSec)));
        emit HarvestRecorded(id, engine, dMain, dSec, ok);
    }

    /**
     * @notice Retry the delivery of main that a pot's live recipient refused (the hook's
     *         {IGlueHook-flushDirect} body). Permissionless; the pot's CURRENT recipient is always
     *         the source of truth.
     * @param p The pool's pot.
     * @param L The hook's delivery/attribution ledgers.
     * @param id The pool whose direct-parked main is retried.
     * @return amount The amount delivered.
     */
    function flushDirect(IGlueHook.Pot storage p, IGlueHook.Ledgers storage L, bytes32 id)
        external returns (uint256 amount)
    {
        amount = L.parkedDirect[id];
        if (amount == 0) revert IGlueHook.PotNotReady();

        address recipient = p.recipient;
        // A pot moved to burn since the park has no direct target any more
        if (recipient == address(0)) revert IGlueHook.PotNotReady();

        address asset = p.main;
        // Still refusing: leave it parked for a later attempt
        if (!_pushRaw(recipient, asset, amount)) revert IGlueHook.PotNotReady();

        L.parked[asset] -= amount;
        L.parkedDirect[id] = 0;
        emit FlushedDirect(id, recipient, amount);
    }

    /**
     * @dev Place main with a LIVE recipient, without ever being able to revert the swap that
     *      produced it: a non-reverting ETH send when main is the network token, a non-reverting
     *      `transfer` otherwise; a refusal parks the main, booked per pool for {flushDirect}.
     */
    function _deliver(
        IGlueHook.Pot storage p,
        IGlueHook.Ledgers storage L,
        bytes32 id,
        address asset,
        uint256 amount
    ) private {
        if (_pushRaw(p.recipient, asset, amount)) {
            emit Delivered(id, p.recipient, amount, IGlueHook.Delivery.DIRECT);
            return;
        }
        L.parked[asset] += amount;
        L.parkedDirect[id] += amount;
        emit Delivered(id, address(this), amount, IGlueHook.Delivery.PARKED);
    }

    /**
     * @dev The burn, never able to revert the carrying swap. THE burn is the Glue Protocol's own,
     *      in the shape the main's classification ({initPot}) dictates:
     *
     *        - The main IS a GlueWrapper (`glue[asset] == asset`): PARK. The shares are transferred
     *          to the wrapper's own address — the one custody Glue's supply oracle subtracts from
     *          the circulating supply, for arbitrary wei amounts, in both ERC20 and NFT mode (a
     *          wrapper's `unglue` cannot burn its own shares: NFT mode needs whole units and rejects
     *          the empty-collateral shape, ERC20 mode pulls RAW sticky the hook never holds).
     *        - Any other main: a pure `unglue` called on the main's canonical wrapper with an EMPTY
     *          collateral list — the supply is pulled from the hook's exact allowance and destroyed
     *          inside the protocol (which runs its own burn / dead-route fallbacks), redeeming
     *          nothing and concentrating the glue's backing for every remaining holder. A main
     *          whose glue was unknown at declaration is glued lazily, once, here.
     *
     *      The hook never destroys supply itself. Every leg is accepted only on a verified balance
     *      drop; a refused unglue flags the asset unburnable, so later burns of it skip the probe
     *      and settle straight to the held ledger — HELD on the hook FOREVER, no withdrawal path
     *      exists, so custody IS the burn. A refused park never flags: it is one plain transfer a
     *      real wrapper cannot refuse, so the next leg simply retries it.
     */
    function _burn(IGlueHook.Ledgers storage L, bytes32 id, address asset, uint256 amount) private {
        address glue = L.glue[asset];
        if (glue == asset) {
            // 1a. PARK: shares owned by the wrapper itself are out of circulation for Glue
            if (_tryTransfer(asset, asset, amount)) {
                emit Delivered(id, asset, amount, IGlueHook.Delivery.BURNED);
                return;
            }
        } else if (!L.unburnable[asset]) {
            // A known non-glueable skips the probe: straight to the terminal hold
            if (glue == address(0)) {
                // Lazy glue: the creation-time ensure was refused or the GlueStick was codeless
                glue = _tryEnsure(asset);
                if (glue != address(0)) L.glue[asset] = glue;
            }
            // 1b. The Glue burn through the main's wrapper, verified by the hook's own balance drop
            if (glue != address(0) && _tryUnglue(glue, asset, amount)) {
                emit Delivered(id, glue, amount, IGlueHook.Delivery.BURNED);
                return;
            }

            // The probe failed: never run it again for this asset
            L.unburnable[asset] = true;
        }

        // 2. Held forever — the terminal sink
        L.held[asset] += amount;
        emit Delivered(id, address(this), amount, IGlueHook.Delivery.HELD);
    }

    /**
     * @dev Push a harvest leg to its recipient, folding in any backlog owed to the same pair. A
     *      success clears the backlog; a refusal books the NEW amount on top of it (the backlog
     *      was already booked) and never reverts.
     * @return delivered What actually landed on `to`: `amount + backlog` on a successful push,
     *         zero when the leg was booked to `owed`.
     */
    function _payRecipient(IGlueHook.Ledgers storage L, address to, address asset, uint256 amount)
        private returns (uint256 delivered)
    {
        uint256 backlog = L.owed[to][asset];
        if (_pushRaw(to, asset, amount + backlog)) {
            if (backlog != 0) {
                delete L.owed[to][asset];
                L.owedTotal[asset] -= backlog;
            }
            delivered = amount + backlog;
            emit Paid(to, asset, delivered);
        } else {
            L.owed[to][asset] += amount;
            L.owedTotal[asset] += amount;
            emit Owed(to, asset, amount);
        }
    }

    /// @dev One non-reverting push: the native send or the tolerant ERC20 transfer, both reporting.
    function _pushRaw(address to, address asset, uint256 amount) private returns (bool ok) {
        if (amount == 0) return true;
        return asset == address(0) ? _sendEth(to, amount) : _tryTransfer(asset, to, amount);
    }

    /// @dev Native send at the carrying call's gas, reporting failure instead of reverting so a
    ///      delivery can be parked or booked and retried. No gas stipend, the same way Uniswap moves
    ///      ETH (`call(gas(), …)`): a fixed number in this immutable hook would drift with every
    ///      chain gas repricing and push a legitimate smart-contract recipient out of the push path
    ///      for good. What a recipient can do with the gas is bounded by the transient guard, not by
    ///      gas: every value-moving entry of the hook is `guarded`, so a re-entry bounces. What a
    ///      recipient that BURNS gas can do is fail the swap on the pool whose program or pot named
    ///      it (the 1/64 the EVM keeps may not finish the frame) — its own pool, the standing
    ///      Uniswap gives a hook or a token that breaks. Refusals still land in `owed` / the park,
    ///      both reachable through full-gas doors (`claim`, `flushDirect`).
    function _sendEth(address to, uint256 amount) private returns (bool ok) {
        (ok, ) = to.call{value: amount}("");
    }

    /// @dev The pure Glue burn: an exact-amount approval to the main's GlueWrapper, then the
    ///      wrapper's own `unglue` with an EMPTY collateral list (no GlueStick hop — the wrapper
    ///      pulls the raw sticky from `msg.sender` and destroys it in-protocol). Accepted only when
    ///      the hook's balance really fell by `amount` — a codeless glue or a lying token falls
    ///      through instead of counting as burned. Every leg is tolerant: a failure reports false
    ///      (the caller settles to the held ledger) and never reverts the carrying swap.
    /// @param glue The main's canonical GlueWrapper (never the main itself: that is a park).
    /// @param token The main being burned.
    /// @param amount The raw amount to destroy.
    function _tryUnglue(address glue, address token, uint256 amount) private returns (bool ok) {
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        if (balBefore < amount) return false;

        // Exact-amount approval, tolerant of odd ERC20s (missing return data is accepted)
        (bool aOk, bytes memory aData) = token.call(abi.encodeCall(IERC20.approve, (glue, amount)));
        if (!(aOk && (aData.length == 0 || (aData.length >= 32 && abi.decode(aData, (bool)))))) return false;

        // Pure burn: empty collaterals redeem nothing, the pulled supply is destroyed in-protocol
        (bool s, ) = glue.call(
            abi.encodeCall(IGlueWrapperMin.unglue, (new address[](0), amount, address(this)))
        );

        ok = s && IERC20(token).balanceOf(address(this)) <= balBefore - amount;
        if (!ok) {
            // Clear the dangling allowance; its own failure is ignorable (a GlueWrapper only ever
            // pulls ERC20 from `msg.sender` inside the caller's own call, so a stale allowance
            // moves nothing)
            (aOk, ) = token.call(abi.encodeCall(IERC20.approve, (glue, 0)));
        }
    }

    /// @dev The GlueStick's registry read, tolerant of a codeless Stick (a chain the Glue Protocol
    ///      never reached): `wrapperOf(asset)` is the asset itself for a GlueWrapper, its canonical
    ///      wrapper for a glued sticky, zero for an unglued asset — or zero when the call fails.
    function _wrapperOf(address asset) private view returns (address glue) {
        (bool s, bytes memory data) =
            GLUE_STICK.staticcall(abi.encodeCall(IGlueStickMin.wrapperOf, (asset)));
        if (s && data.length >= 32) glue = abi.decode(data, (address));
    }

    /// @dev The GlueStick's engine-registry read, tolerant: true only when the Stick answers a
    ///      well-formed `true` to `isRegisteredEngine(who)`; a codeless or foreign Stick, a revert or
    ///      short or malformed return data all read as false, so the plain (non-native) path is
    ///      never blocked (a raw word compare instead of `abi.decode`, which would revert on a
    ///      non-boolean word).
    function _isRegisteredEngine(address who) private view returns (bool registered) {
        (bool s, bytes memory data) =
            GLUE_STICK.staticcall(abi.encodeCall(IGlueStickMin.isRegisteredEngine, (who)));
        if (s && data.length >= 32) {
            uint256 word;
            assembly ("memory-safe") { word := mload(add(data, 32)) }
            registered = word == 1;
        }
    }

    /// @dev The GlueStick's validated creation chokepoint, tolerant: clones the asset's glue when
    ///      missing and returns it, or zero when the Stick refuses the asset (the network wrapper,
    ///      a wrap-of-a-wrap, a non-conforming contract) or has no code.
    function _tryEnsure(address asset) private returns (address glue) {
        (bool s, bytes memory data) = GLUE_STICK.call(abi.encodeCall(IGlueStickMin.ensureWrapper, (asset)));
        if (s && data.length >= 32) glue = abi.decode(data, (address));
    }

    /// @dev ERC20 transfer that reports failure instead of reverting, so the cascade can move on.
    function _tryTransfer(address token, address to, uint256 amount) private returns (bool ok) {
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        // A token may return nothing, or a boolean that must be true
        ok = success && (data.length == 0 || (data.length >= 32 && abi.decode(data, (bool))));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // COMPOUND SIZING
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @dev Liquidity the compound budget can fund across the program's fixed range at the live
     *      price, per the standard three cases: below the range only currency0 funds it, above it
     *      only currency1, inside it whichever side binds (the minimum). Floor math end to end, so
     *      the amounts the mint then rounds up stay within the budget in all but 1-wei edge cases -
     *      which {_settleMerged}'s budget check catches.
     * @param pm The PoolManager.
     * @param g The pool's program.
     * @param id The pool identifier.
     * @param amount0 Currency0 budget.
     * @param amount1 Currency1 budget.
     * @return liquidity Liquidity units the budget funds (0 = nothing to compound).
     */
    function _liquidityForFees(
        address pm,
        IGlueHook.Program storage g,
        bytes32 id,
        uint256 amount0,
        uint256 amount1
    ) private view returns (uint128 liquidity) {
        uint160 sqrtLower = GluedV4Core.getSqrtRatioAtTick(g.tickLower);
        uint160 sqrtUpper = GluedV4Core.getSqrtRatioAtTick(g.tickUpper);
        uint160 sqrtP = GluedV4Core.getSlot0(pm, id).sqrtPriceX96;

        if (sqrtP <= sqrtLower) {
            // Price below the range: the position is all currency0
            return GluedV4Core.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount0);
        }
        if (sqrtP >= sqrtUpper) {
            // Price above the range: the position is all currency1
            return GluedV4Core.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount1);
        }
        // In range: both sides fund it and the smaller one binds
        return GluedV4Core.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PRIMITIVES (library-local copies of the callback contract's internals)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Pay a negative delta into the PoolManager: value-settle for native, sync → transfer →
    ///      settle for an ERC20. Runs under delegatecall, so the value and the tokens are the
    ///      hook's own - the fees the frame just collected.
    function _settle(address pm, address currency, uint256 amount) private {
        if (currency == address(0)) {
            IPoolManagerMin(pm).settle{value: amount}();
        } else {
            IPoolManagerMin(pm).sync(currency);
            IERC20(currency).safeTransfer(pm, amount);
            IPoolManagerMin(pm).settle();
        }
    }

    /// @dev Split a packed `BalanceDelta` into its two signed 128-bit legs.
    function _unpack(int256 delta) private pure returns (int128 amount0, int128 amount1) {
        assembly ("memory-safe") {
            amount0 := sar(128, delta)
            amount1 := signextend(15, delta)
        }
    }
}
