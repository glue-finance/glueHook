// SPDX-License-Identifier: BUSL-1.1
//
// Licensed Work: GlueHook
// The Licensed Work is (c) 2026 gluefinance.eth and is owned exclusively by Glue Labs Inc. (Delaware).
// Licensor: Glue Labs Inc. (Delaware)
// Change Date: the earlier of 2030-08-05 or a date specified at gluehook-license-date.gluefinance.eth
// Change License: GNU General Public License v2.0 or later
// Full licence text: https://github.com/glue-finance/GlueHook/blob/main/LICENCE.txt

/**
 *
 *  ██████╗ ██╗     ██╗   ██╗███████╗██╗  ██╗ ██████╗  ██████╗ ██╗  ██╗
 * ██╔════╝ ██║     ██║   ██║██╔════╝██║  ██║██╔═══██╗██╔═══██╗██║ ██╔╝
 * ██║  ███╗██║     ██║   ██║█████╗  ███████║██║   ██║██║   ██║█████╔╝
 * ██║   ██║██║     ██║   ██║██╔══╝  ██╔══██║██║   ██║██║   ██║██╔═██╗
 * ╚██████╔╝███████╗╚██████╔╝███████╗██║  ██║╚██████╔╝╚██████╔╝██║  ██╗
 *  ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝
 *
 */

pragma solidity ^0.8.35;

import {IPoolManagerMin} from "../libs/GluedV4Core.sol";

/**
 * @title  IGlueHook
 * @author @lalilulel0x - La Li Lu Le Lo
 * @notice Interface of the GlueHook Uniswap V4 buyback-and-burn hook: a permissionless donation POT
 *         per hooked pool that buys the pool's own asset behind every swap — throttled by a
 *         reference price so it buys dips at full size and rallies only as far as they can be
 *         proven cheap — plus one optional LP PROGRAM per pool — a hook-held liquidity position
 *         whose trading fees are auto-harvested inside swaps and split, with a selectable
 *         AUTO-COMPOUND share re-minted into the position itself.
 * @dev    Every hooked pool declares two roles for its two currencies:
 *
 *         ┌───────────┬─────────────────────────────────────────────────────────────────────────────┐
 *         │ MAIN      │ the asset being defended. It is what the pot BUYS and what the pot's        │
 *         │           │ recipient receives (`address(0)` means BURN — the burn cascade runs).       │
 *         ├───────────┼─────────────────────────────────────────────────────────────────────────────┤
 *         │ SECONDARY │ the buyback currency. It is the ONLY asset the pot holds and the ONLY asset  │
 *         │           │ {donate} accepts — native or any ERC20, whichever side of the pair it is.    │
 *         └───────────┴─────────────────────────────────────────────────────────────────────────────┘
 *
 *         Either currency may be main, so the hook is pair-agnostic: an ETH-quoted token is one
 *         configuration among many, not a requirement. The one constraint: MAIN must be GLUEABLE —
 *         never the network token and never the chain's canonical wrapped native (NATIVEWRAP) —
 *         because a BURN is the Glue Protocol's own: a pure `unglue` (empty collateral list)
 *         called directly on the main's canonical GlueWrapper, destroying the supply in-protocol
 *         and concentrating the glue's backing for every remaining holder — or, when the main IS
 *         a GlueWrapper (the ERC20 face of a glued ERC20 or ERC721 collection), a PARK: the shares
 *         are transferred to the wrapper's own address, which the Glue supply oracle counts as out
 *         of circulation. The hook never destroys supply itself; a main whose burn refuses is held
 *         on the hook FOREVER instead (custody IS the burn).
 *
 *         ONE MECHANIC, ONE POT
 *
 *         THE PUMP (`afterSwap`, on EVERY swap of a funded pool, in either direction). After the
 *         swapper's trade has executed, the pot spends secondary to buy main in that same
 *         transaction and hands it to the recipient. Behind a buy it adds to the demand; behind a
 *         sell it buys the dip the sell just made. The swapper's own execution is never touched:
 *         the pump runs after it, in its own call frame, and a failure skips the pump alone.
 *
 *         FOUR CEILINGS size it, and the pump takes the smallest, then a haircut:
 *
 *           1. THE FEE CEILING `f·R` (fee × tangent depth) — the size below which sandwiching the
 *              pump costs more in fees than the price move is worth, whatever the attacker's size.
 *           2. THE SPEND BUCKET — the pot's pace, tied to what the pool EARNS. The bucket holds at
 *              most one fee ceiling; every funded swap credits it {GlueHook.PUMP_FEE_LEVERAGE} times
 *              the fee it paid, and time credits it one ceiling per {GlueHook.PUMP_REFILL} as a slow
 *              floor. Over any window the pot spends at most `k ×` the LP fees earned plus the floor,
 *              so nobody can compress the pot's spend into a block by manufacturing volume — the
 *              volume unlocks only `k ×` what it cost in fees.
 *           3. THE DEMAND CEILING — a SHARE of the secondary the carrying swap moved (paid on a
 *              buy, received on a sell), so a dust trade unlocks only a dust pump.
 *           4. THE REFERENCE GATE sets that share: the pool keeps a time-weighted REFERENCE tick
 *              (fed only by prices that STOOD between blocks — nothing a transaction does to spot
 *              inside its own block enters it, and moving it means holding a price against the
 *              market for minutes; and it may RISE at most {GlueHook.REFERENCE_MAX_RISE_PER_MINUTE}
 *              ticks a minute, so a `+d` push takes `d / 3%` minutes of a held price to be believed,
 *              while a fall is believed at once). At or below the reference the share is its
 *              maximum; above it the share shrinks as `fee / premium`, which is exactly the level
 *              at which pushing spot up to farm the pump — both legs of the round trip summoning
 *              pumps — costs the pusher more in fees than the pumps can hand back.
 *
 *         So the pot buys every dip at full size, buys ordinary trading at full size, follows a
 *         genuine rally at a size that shrinks with the premium over the reference, paces itself to
 *         what the pool earns, and cannot be farmed by anyone moving the price inside their own
 *         transaction or their own block.
 *
 *         THE LP PROGRAM (one per pool, admin-created). The pool's single hook-held liquidity position,
 *         created plain ({addLiquidity}: zero shares, auto-harvest disarmed, everything switchable
 *         later) or with full rules at creation ({addLiquidityAdvanced}). Fees harvest automatically
 *         inside swaps once they reach the configured minimums, or manually through {harvest}. Every
 *         share reads off the GROSS of its side: `compoundShareWad` is the LP budget (the
 *         auto-compounding concentrated-liquidity venues lack natively), `buybackShareWad` fuels the
 *         pot, `burnShareWad` runs the burn cascade, and the exact rest goes to one recipient per
 *         side (`compound + buyback` and `compound + burn` each capped at 100% at set-time). What the
 *         compound mint cannot place is CARRIED and retried at every next harvest — it never leaks to
 *         the pot or a recipient. Two independent roles: the OWNER holds the property (liquidity,
 *         harvest, transfer), the OPERATOR edits the rules; either surrenders to `address(0)` on its
 *         own terms.
 *
 *         THE BUYBACK SPLIT (operator-set, part of {ProgramConfig}). The pot's OUTPUT — the main a
 *         pump buys — runs the same waterfall shape before delivery:
 *         `potCompoundShareWad` joins the program's main-side compound carry (buy pressure becoming
 *         the pool's own liquidity), `potBurnShareWad` runs the burn cascade, and the EXACT rest
 *         follows the pot's recipient exactly as an unsplit delivery would. Both shares default to
 *         zero — the unsplit behaviour — and a pool with no program always delivers whole.
 *
 *         NATIVE PROGRAMS (the Glue staking integration). A program whose creator is a REGISTERED
 *         Glue LP engine (`GlueStick.isRegisteredEngine(msg.sender)` at creation — {launchPool},
 *         {addLiquidity}, {addLiquidityAdvanced}) is stamped `native` once and forever. A native
 *         program's OWNER and BOTH remainder recipients are the creating engine and can never be
 *         moved (the operator still edits shares and the auto-harvest minimums, so the engine's
 *         push-config sync keeps working; ownership transfer is refused). On EVERY harvest of a
 *         native program — the in-swap auto-harvest, the manual {harvest}, and the harvest-first
 *         inside {addProgramLiquidity} / {removeProgramLiquidity} — AFTER the remainder legs have
 *         been pushed, the hook (a) advances the per-`(pool, asset)` DELIVERED ledger
 *         ({deliveredCumOf}: what actually landed on the engine, so a leg booked to `owed` counts
 *         only when the later successful push folds it in) and (b) calls the engine's
 *         `IGlueHookedEngine.recordHarvest(poolId, deliveredMain, deliveredSec)` with the carrying
 *         call's gas forwarded (no stipend — the engine is Glue's own, pinned at pool creation) and
 *         its revert swallowed. The callback is pure bookkeeping on the engine's side: it
 *         can never touch delivery, the pot, the compound or the carrying swap, and the engine
 *         reconciles any callback that failed from the delivered ledger at its next own harvest,
 *         so every unit is attributed exactly once. The hook hardcodes NO engine: the registry read
 *         is its only knowledge of Glue beyond the burn (`wrapperOf` / `ensureWrapper` / `unglue`).
 *         A non-native program takes ZERO new code paths.
 */
interface IGlueHook {
    // ═══════════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice A hooked pool's buyback pot.
    /// @dev `configured` is the liveness flag. A pot's `main` is always a glueable ERC20 (never the
    ///      network token, never NATIVEWRAP — {initPot} enforces it); its `secondary` may be native.
    struct Pot {
        // Who may configure the pot and move the recipient: the address that initialised the pool
        address admin;
        // The defended currency (one of the pool's two); bought back and delivered to `recipient`
        address main;
        // THE SPEND BUCKET (packed with `main`). The bucket holds at most one fee ceiling (`f·R`);
        // this timestamp encodes its level as the seconds of time-refill it is worth (full at
        // {GlueHook.PUMP_REFILL}). A swap's volume credit moves it back, a pump's spend moves it
        // forward, and time refills it linearly. Zero (a fresh pot) reads as a full bucket.
        uint32 pumpBucketTimestamp;
        // The buyback currency (the pool's other side); the only asset this pot ever holds
        address secondary;
        // Where bought main is delivered. `address(0)` MEANS BURN: a pure Glue unglue through the
        // main's own GlueWrapper — a PARK on it when the main is itself a wrapper — (falling
        // through to held-forever) runs instead of a plain transfer.
        address recipient;
        // True once {initPot} has run; until then the hook is completely passive on this pool
        bool configured;
        // ── THE REFERENCE PRICE (packed into `recipient`'s slot, so a swap reads it for free) ──
        // The time-weighted reference tick the pump's gate compares spot against: an exponential
        // average of the ticks that STOOD between blocks, time constant {GlueHook.REFERENCE_TAU},
        // in 1/256ths of a tick. Seeded from the live tick at {initPot} and whenever a donation
        // funds an empty pot; advanced on every swap of a funded pool.
        int32 referenceTickX8;
        // The tick that has stood since `lastTimestamp`: the pool's tick after its latest swap
        int24 lastTick;
        // When `lastTick` started standing
        uint32 lastTimestamp;
        // Pot inventory, denominated in `secondary`
        uint256 balance;
    }

    /// @notice The split rules of a pool's LP PROGRAM, the operator-editable half of {Program}.
    /// @dev EVERY share is a fraction of the GROSS fees of its side, so the numbers mean exactly
    ///      what they say. Per side, two shares and one recipient:
    ///
    ///      ┌────────────────┬────────────────────────────────────────────────────────────────────┐
    ///      │ SECONDARY side │ `compoundShareWad` is the LP budget, `buybackShareWad` fuels the    │
    ///      │                │ pool's pot, and the REST — gross minus both — goes to               │
    ///      │                │ `secondaryRecipient`. The two shares must sum to ≤ 100%.            │
    ///      ├────────────────┼────────────────────────────────────────────────────────────────────┤
    ///      │ MAIN side      │ `compoundShareWad` is the LP budget, `burnShareWad` runs the burn   │
    ///      │                │ cascade, and the REST goes to `mainRecipient`. Same ≤ 100% rule.    │
    ///      └────────────────┴────────────────────────────────────────────────────────────────────┘
    ///
    ///      THE BUYBACK SPLIT. The pot's OUTPUT — every unit of main a pump buys — runs the same
    ///      waterfall shape before delivery: `potCompoundShareWad` is
    ///      credited to the program's main-side compound carry (re-minted as the pool's own
    ///      liquidity at the next harvest), `potBurnShareWad` runs the burn cascade, and the EXACT
    ///      REST follows the pot's recipient exactly as an unsplit delivery would (a live address
    ///      is delivered to, `address(0)` burns). The two shares must sum to ≤ 100%; both default
    ///      to zero, which reproduces the unsplit behaviour bit-for-bit. A pool with NO program
    ///      cannot compound, so its pot output is always delivered whole.
    ///
    ///      THE COMPOUND CARRY. The compound is a mint ATTEMPT at the live price: whichever side
    ///      binds caps it, so part of the budget may not fit this time. Whatever the mint does not
    ///      consume — on either side — is SAVED on the hook ({Program.carryMain} /
    ///      {Program.carrySecondary}) and added to the NEXT harvest's compound budget: it retries
    ///      LP-ing forever and never leaks to the pot or a recipient. The buyback split's compound
    ///      leg joins {Program.carryMain} the same way. A config edit only changes how FUTURE
    ///      harvests and deliveries split; nothing already split or carried is re-touched.
    ///
    ///      Shares are WAD (1e18 = 100%). A side whose two shares sum below 100% MUST name a live
    ///      recipient (below-100% means a remainder can exist). A burn share is always legal: the
    ///      main is glueable by construction. `minMain` / `minSecondary` arm the
    ///      AUTO-harvest: a swap harvests when either side's pending fees reach its min;
    ///      `type(uint256).max` disarms a side. The same split runs on the manual {harvest}
    ///      whatever the mins say — OWNER-ONLY unless `publicHarvest` opens it (the auto-harvest
    ///      is inherently public: any swap triggers it).
    struct ProgramConfig {
        // WAD share of GROSS secondary-side fees credited to the pool's pot (+ compound ≤ 100%)
        uint64 buybackShareWad;
        // WAD share of GROSS main-side fees routed through the burn cascade (+ compound ≤ 100%)
        uint64 burnShareWad;
        // WAD share of the GROSS of BOTH sides budgeted to the compound mint
        uint64 compoundShareWad;
        // WAD share of the pot's OUTPUT (the main every pump buys) credited to the compound carry
        // (+ potBurn ≤ 100%; zero without effect when the pool has no program)
        uint64 potCompoundShareWad;
        // WAD share of the pot's OUTPUT routed through the burn cascade (+ potCompound ≤ 100%)
        uint64 potBurnShareWad;
        // True opens the manual {harvest} to anyone; false keeps it owner-only
        bool publicHarvest;
        // Receives the secondary remainder (gross − compound − buyback)
        address secondaryRecipient;
        // Receives the main remainder (gross − compound − burn)
        address mainRecipient;
        // Pending main-side fees that arm the auto-harvest (`type(uint256).max` = disarmed)
        uint256 minMain;
        // Pending secondary-side fees that arm the auto-harvest (`type(uint256).max` = disarmed)
        uint256 minSecondary;
    }

    /// @notice A pool's LP PROGRAM: the ONE hook-held liquidity position per pool, plus its split rules.
    /// @dev Created by the pot admin through {addLiquidity} (everything off) or {addLiquidityAdvanced}
    ///      (full rules at creation). TWO INDEPENDENT ROLES, both explicit parameters rather than
    ///      `msg.sender`: the OWNER holds the PROPERTY — add/remove liquidity, harvest, transferable —
    ///      while the OPERATOR edits the split rules. Each role surrenders on its own terms: the
    ///      operator can go to `address(0)` to freeze the config forever WITHOUT the owner losing the
    ///      position (nobody is ever forced to give up the pool just to lock the rules), and the owner
    ///      can go to `address(0)` — at creation or by transfer — to lock the liquidity forever, which
    ///      force-opens the manual harvest. Richer custody policy (vesting, timelocks, DAO control) is
    ///      built ON TOP by making such a contract the owner. The tick range is fixed at creation.
    ///
    ///      Slot 0 packs everything the per-swap auto-harvest gate reads (`liquidity`, the ticks,
    ///      `exists`, `publicHarvest`, `armed`, `native`): a disarmed program costs a swap ONE
    ///      storage read.
    struct Program {
        // The hook-tracked liquidity of the program's single V4 position
        uint128 liquidity;
        // Lower tick of the position (fixed at creation; sentinel (0,0) resolved to full range)
        int24 tickLower;
        // Upper tick of the position
        int24 tickUpper;
        // True once the program was created; `liquidity` may be zero while it exists
        bool exists;
        // True opens the manual {harvest} to anyone; false keeps it owner-only
        bool publicHarvest;
        // True when at least one auto-harvest min is set (not `type(uint256).max`): maintained by
        // the config write, so a disarmed program never pays the pending-fee scan on a swap
        bool armed;
        // True when the program was created by a registered Glue LP engine: owner + both remainder
        // recipients are pinned to that engine and every harvest reports to it (see the header)
        bool native;
        // The PROPERTY holder: add/remove liquidity + harvest; `address(0)` = liquidity locked forever
        address owner;
        // WAD share of GROSS secondary-side fees credited to the pool's pot
        uint64 buybackShareWad;
        // Receives the secondary remainder (gross − compound − buyback)
        address secondaryRecipient;
        // WAD share of GROSS main-side fees routed through the burn cascade
        uint64 burnShareWad;
        // Receives the main remainder (gross − compound − burn)
        address mainRecipient;
        // WAD share of the GROSS of BOTH sides budgeted to the compound mint
        uint64 compoundShareWad;
        // The SETTINGS editor: config changes only; `address(0)` = the rules are frozen forever
        address operator;
        // WAD share of the pot's OUTPUT (the main every pump buys) credited to the compound carry
        uint64 potCompoundShareWad;
        // WAD share of the pot's OUTPUT routed through the burn cascade
        uint64 potBurnShareWad;
        // Pending main-side fees that arm the auto-harvest (`type(uint256).max` = disarmed)
        uint256 minMain;
        // Pending secondary-side fees that arm the auto-harvest (`type(uint256).max` = disarmed)
        uint256 minSecondary;
        // Main-side compound budget the mint could not place yet — retried at every next harvest
        uint256 carryMain;
        // Secondary-side compound budget the mint could not place yet — retried at every next harvest
        uint256 carrySecondary;
    }

    /// @notice The hook's delivery and attribution ledgers, declared as ONE storage struct so the
    ///         resident hook and the {GlueLiquidity} delivery engine share them through a single
    ///         storage pointer.
    /// @dev Every field is a term of the hook's full-attribution accounting: {obligationOf} sums
    ///      them per asset, and the hook's balance always covers the sum. None has a withdrawal
    ///      path beyond its own documented exit ({flushDirect}, {claim}, the compound mint).
    struct Ledgers {
        // asset => total pot inventory denominated in it, summed across every pool
        mapping(address => uint256) potTotal;
        // asset => main a live recipient refused, parked on the hook
        mapping(address => uint256) parked;
        // poolId => the subset of `parked` (in that pool's main) headed for a LIVE recipient,
        // retryable through {flushDirect}
        mapping(bytes32 => uint256) parkedDirect;
        // asset => burn-intent main whose Glue burn refused, held FOREVER
        mapping(address => uint256) held;
        // asset => true once the burn probe failed; later burn intent settles straight to `held`
        mapping(address => bool) unburnable;
        // recipient => asset => harvest legs a refused push booked, claimable through {claim}
        mapping(address => mapping(address => uint256)) owed;
        // asset => Σ `owed` over all recipients
        mapping(address => uint256) owedTotal;
        // asset => Σ compound carry (both sides, every program)
        mapping(address => uint256) carryTotal;
        // main => its canonical GlueWrapper, read from the GlueStick's registry at declaration (or
        // lazily at the first burn): `glue[main] == main` means the main IS a wrapper (its burn is a
        // PARK on itself), any other non-zero value is the wrapper its burn calls `unglue` on, and
        // zero means the main is not glued yet
        mapping(address => address) glue;
        // poolId => asset => cumulative harvest legs DELIVERED to a NATIVE program's engine
        // (monotonic; an `owed` booking moves it only when the later successful push folds it in).
        // The engine's exactly-once reconcile cursor — see {deliveredCumOf}.
        mapping(bytes32 => mapping(address => uint256)) deliveredCum;
    }

    /// @notice How a delivery of main was placed.
    enum Delivery {
        // Sent straight to the pot's live recipient
        DIRECT,
        // Burned through the Glue Protocol: destroyed by a pure `unglue` (empty collateral list)
        // called on the main's GlueWrapper (`to` = the wrapper), or PARKED on the wrapper itself
        // when the main is a GlueWrapper (`to` = the main) — both verified by the hook's own
        // balance drop, both subtracted from Glue's circulating supply
        BURNED,
        // RESERVED (kept for ABI stability): the pre-Glue `0xdead` route, never emitted
        DEAD,
        // A main whose Glue burn refused: held on the hook FOREVER, with no
        // withdrawal path — out of circulation by custody ({heldOf})
        HELD,
        // A refused live-recipient delivery, parked on the hook and retryable via {flushDirect}
        PARKED,
        // The buyback split's compound leg: credited to the program's main-side compound carry,
        // re-minted as the pool's own liquidity at the next harvest
        COMPOUNDED
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice A hooked pool was initialised and its admin recorded.
    /// @param poolId The pool identifier.
    /// @param admin The address that called `PoolManager.initialize`.
    event PotOpened(bytes32 indexed poolId, address indexed admin);

    /// @notice A pot's roles were declared (one-shot).
    /// @param poolId The pool identifier.
    /// @param main The defended currency.
    /// @param secondary The buyback currency.
    /// @param recipient Where bought main is delivered.
    event PotInitialized(bytes32 indexed poolId, address main, address secondary, address recipient);

    /// @notice A pot's delivery target moved.
    /// @param poolId The pool identifier.
    /// @param recipient The new recipient (`address(0)` means burn).
    event RecipientSet(bytes32 indexed poolId, address recipient);

    /// @notice Parked main from a refused live-recipient delivery was later delivered.
    /// @param poolId The pool whose park was retried.
    /// @param to The pot's recipient at retry time.
    /// @param amount The amount delivered.
    event FlushedDirect(bytes32 indexed poolId, address indexed to, uint256 amount);

    /// @notice Secondary was added to a pot.
    /// @param poolId The pool identifier.
    /// @param donor Who funded it.
    /// @param amount Amount credited (measured, so a fee-on-transfer donation credits what arrived).
    event Donated(bytes32 indexed poolId, address indexed donor, uint256 amount);

    /// @notice The pot bought main behind a swap (a buy or a sell of main alike).
    /// @param poolId The pool identifier.
    /// @param spent Secondary spent out of the pot.
    /// @param bought Main received.
    event Pumped(bytes32 indexed poolId, uint256 spent, uint256 bought);

    /// @notice Main left the hook through the delivery/burn cascade.
    /// @param poolId The pool identifier.
    /// @param to Where it went (the recipient, the GlueWrapper it was unglued through — the main
    ///        itself when a wrapper main was parked — or the hook itself when parked or held).
    /// @param amount Amount of main.
    /// @param mode Which leg of the cascade succeeded.
    event Delivered(bytes32 indexed poolId, address indexed to, uint256 amount, Delivery mode);

    /// @notice A pool's LP program was created.
    /// @param poolId The pool identifier.
    /// @param owner The program's owner and first operator (`address(0)` = surrendered at birth).
    /// @param tickLower Lower tick of the program's position.
    /// @param tickUpper Upper tick of the program's position.
    event ProgramCreated(bytes32 indexed poolId, address indexed owner, int24 tickLower, int24 tickUpper);

    /// @notice A program's split rules were set (at creation or by the operator later).
    /// @param poolId The pool identifier.
    /// @param config The full new configuration.
    event ProgramConfigured(bytes32 indexed poolId, ProgramConfig config);

    /// @notice A program's ownership moved to a new holder.
    /// @param poolId The pool identifier.
    /// @param newOwner The new property holder (`address(0)` = liquidity locked forever).
    event ProgramOwnershipTransferred(bytes32 indexed poolId, address indexed newOwner);

    /// @notice A program's operator role moved (`address(0)` = the split rules are frozen forever).
    /// @param poolId The pool identifier.
    /// @param newOperator The new settings editor.
    event ProgramOperatorSet(bytes32 indexed poolId, address indexed newOperator);

    /// @notice Liquidity was added to a pool's program position.
    /// @param poolId The pool identifier.
    /// @param liquidity Liquidity units minted.
    /// @param amount0Used Currency0 the position consumed.
    /// @param amount1Used Currency1 the position consumed.
    event ProgramLiquidityAdded(bytes32 indexed poolId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used);

    /// @notice Liquidity was removed from a pool's program position (owner only).
    /// @param poolId The pool identifier.
    /// @param liquidity Liquidity units removed.
    /// @param amount0 Currency0 principal returned.
    /// @param amount1 Currency1 principal returned.
    /// @param to Where the principal went.
    event ProgramLiquidityRemoved(
        bytes32 indexed poolId, uint128 liquidity, uint256 amount0, uint256 amount1, address to
    );

    /// @notice A program's accrued LP fees were collected and split (auto in a swap, or manual).
    /// @param poolId The pool identifier.
    /// @param mainFees Fees collected on the main side (gross).
    /// @param secondaryFees Fees collected on the secondary side (gross).
    /// @param burned Main-side burn leg (`⌊gross · burnShareWad⌋`), routed through the burn cascade.
    /// @param fueled Secondary-side buyback leg (`⌊gross · buybackShareWad⌋`), credited to the pot.
    event Harvested(bytes32 indexed poolId, uint256 mainFees, uint256 secondaryFees, uint256 burned, uint256 fueled);

    /// @notice A compound budget (this harvest's slice + the standing carry) was re-minted into the
    ///         program's own position; what the mint did not consume stays in the carry.
    /// @param poolId The pool identifier.
    /// @param liquidity Liquidity units the compound minted.
    /// @param amount0Used Currency0 the mint consumed out of the compound budget.
    /// @param amount1Used Currency1 the mint consumed out of the compound budget.
    event Compounded(bytes32 indexed poolId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used);

    /// @notice A harvest leg (plus any backlog owed to the same recipient) was pushed successfully.
    /// @param to The recipient.
    /// @param asset The asset pushed.
    /// @param amount The amount delivered, backlog included.
    event Paid(address indexed to, address indexed asset, uint256 amount);

    /// @notice A harvest leg could not be pushed; it is booked and retryable: it folds into the next successful push to the same pair automatically, or is pulled with {claim}.
    /// @param to The recipient that refused.
    /// @param asset The asset booked.
    /// @param amount The newly booked amount (the total backlog is {owedOf}).
    event Owed(address indexed to, address indexed asset, uint256 amount);

    /// @notice A recipient pulled its booked backlog with {claim}.
    /// @param to The recipient.
    /// @param asset The asset claimed.
    /// @param amount The amount delivered.
    event Claimed(address indexed to, address indexed asset, uint256 amount);

    /// @notice A native program's harvest was reported to its engine.
    /// @param poolId The pool identifier.
    /// @param engine The native program's engine (owner + both recipients).
    /// @param deliveredMain Main-side remainder that actually landed on the engine this frame.
    /// @param deliveredSec Secondary-side remainder that actually landed on the engine this frame.
    /// @param recorded True when `recordHarvest` succeeded; false when the engine reverted or ran
    ///        out of gas (the engine reconciles from {deliveredCumOf} at its next harvest).
    event HarvestRecorded(bytes32 indexed poolId, address indexed engine, uint256 deliveredMain, uint256 deliveredSec, bool recorded);

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice The caller is not allowed to perform this action.
    error NotAllowed();
    /// @notice A reentrant call was blocked.
    error Reentrancy();
    /// @notice The pot has not been configured with {initPot} yet.
    error PotNotReady();
    /// @notice The pot has already been configured, or the pool's program already exists; both are one-shot.
    error PotAlreadyReady();
    /// @notice `main` is not one of the pool's two currencies, or the recipient is unusable.
    error BadRoles();
    /// @notice The attached value does not match the donation the caller declared.
    error BadDonation();
    /// @notice A quote and its execution disagreed, so the operation was abandoned.
    error QuoteMismatch();
    /// @notice A program config or key is invalid: a side's shares summing above 100%, a
    ///         value-bearing leg without a live recipient, a malformed liquidity request, or a
    ///         DYNAMIC-FEE pool key (this hook only serves static-fee pools).
    error BadConfig();

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Declare a hooked pool's roles. One-shot, and only the pool's initialiser may call it.
     * @dev Until this runs the hook does nothing on the pool: no pump, no reference and {donate} reverts.
     *      `main` must be one of the key's two currencies; the other becomes `secondary` automatically.
     *      `main` must be GLUEABLE — never the network token and never NATIVEWRAP (the chain's
     *      canonical wrapped native), because every burn is a pure Glue unglue. The declaration
     *      also classifies the main through the GLUE_STICK's registry (`wrapperOf`): a GlueWrapper
     *      main burns by PARKING on itself, any other main burns through its canonical wrapper,
     *      created on the spot when missing (`ensureWrapper`, best effort: a failure never blocks
     *      the pool, the glue is retried once at the first burn and later burns settle to the held
     *      ledger).
     * @param key The pool key (must already be initialised through this hook).
     * @param main The currency to defend, buy back and deliver.
     * @param recipient Where bought main goes; `address(0)` means burn.
     */
    function initPot(IPoolManagerMin.PoolKey calldata key, address main, address recipient) external;

    /**
     * @notice Launch a hooked pool in ONE transaction: initialise the pool on the PoolManager, declare
     *         the pot's roles and create the LP program with its seed liquidity.
     * @dev The caller becomes the pot admin (exactly as if they had called `PoolManager.initialize`
     *      themselves), then the {initPot} and {addLiquidityAdvanced} bodies run with the same
     *      validation, events and funding rules as the standalone entries: `key.hooks` must be this
     *      hook, `main` one of the key's two currencies and glueable (never the network token,
     *      never NATIVEWRAP — its glue is ensured best-effort at declaration),
     *      the config's per-side shares must fit, and the seed liquidity settles from the caller — an
     *      ERC20 side from their allowance to this hook, a native side (always `currency0`) from
     *      `msg.value` with the unused excess refunded. Reverts if the pool already exists. Pools that
     *      want the three steps separately (or no program at all) can still run them individually.
     * @param key The pool key (must name this hook).
     * @param sqrtPriceX96 The pool's initial sqrt price, Q64.96.
     * @param main The currency to defend, buy back and deliver.
     * @param recipient Where bought main goes; `address(0)` means burn.
     * @param tickLower Lower tick, `(0,0)` = full range.
     * @param tickUpper Upper tick.
     * @param liquidity Liquidity units to mint as the program's seed.
     * @param owner The program's owner and first operator (`address(0)` = surrendered at birth).
     * @param config The split rules (see {ProgramConfig}).
     * @return amount0 Currency0 the position consumed.
     * @return amount1 Currency1 the position consumed.
     */
    function launchPool(
        IPoolManagerMin.PoolKey calldata key,
        uint160 sqrtPriceX96,
        address main,
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address owner,
        ProgramConfig calldata config
    ) external payable returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Move where a pot delivers the main it buys.
     * @dev Admin-only. `address(0)` means burn (a pure Glue unglue); any other value is a literal
     *      delivery target.
     * @param poolId The pool identifier.
     * @param recipient The new recipient (`address(0)` = burn).
     */
    function setRecipient(bytes32 poolId, address recipient) external;

    /**
     * @notice Retry the delivery of main that a pot's live recipient refused. Permissionless.
     * @dev Sends the pool's whole direct-parked balance to the pot's CURRENT recipient. Reverts when
     *      nothing is parked for the pool, the pot has since been pointed at burn, or the recipient
     *      refuses again (the park is left intact).
     * @param poolId The pool whose direct-parked main is retried.
     * @return delivered The amount delivered to the pot's recipient.
     */
    function flushDirect(bytes32 poolId) external returns (uint256 delivered);

    // ═══════════════════════════════════════════════════════════════════════════════
    // FUNDING
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Fund a pot with its SECONDARY currency. Permissionless.
     * @dev Native secondary: attach the donation as value and pass `amount == msg.value`. ERC20
     *      secondary: attach no value and approve this hook first — the credit is the measured balance
     *      delta, so a fee-on-transfer token credits exactly what arrived. The pot's main can never be
     *      donated: the credit is always denominated in secondary.
     * @param key The pool key whose pot is funded.
     * @param amount The donation amount.
     * @return credited The amount actually added to the pot.
     */
    function donate(IPoolManagerMin.PoolKey calldata key, uint256 amount)
        external payable returns (uint256 credited);

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice A pool's pot.
    /// @param poolId The pool identifier.
    /// @return pot The full pot record.
    function potOf(bytes32 poolId) external view returns (Pot memory pot);

    /// @notice Main that a live recipient refused and that therefore sits on the hook, retryable
    ///         through {flushDirect}.
    /// @param asset The main currency.
    /// @return amount Parked amount, summed across pools.
    function parkedOf(address asset) external view returns (uint256 amount);

    /// @notice Burn-intent main whose Glue burn refused, held here FOREVER.
    /// @dev The hook's terminal sink: there is no withdrawal path, so custody IS the burn — the amount
    ///      is out of circulation as surely as a `0xdead` balance. Once an asset lands here it is
    ///      internally flagged unburnable and the wrapper unglue is never attempted again. A
    ///      GlueWrapper main never lands here through a refusal of its own: its burn is a park on
    ///      itself, which a wrapper always accepts.
    /// @param asset The main currency.
    /// @return amount Held amount.
    function heldOf(address asset) external view returns (uint256 amount);

    /// @notice The subset of {parkedOf} (in the pool's main) that a live recipient refused and that is
    ///         retryable through {flushDirect}.
    /// @param poolId The pool identifier.
    /// @return amount Parked refused-delivery amount.
    function parkedDirectOf(bytes32 poolId) external view returns (uint256 amount);

    /// @notice Everything the hook owes on an asset: every pot holding it, anything parked or held in
    ///         it, every harvest leg booked in it for a recipient, and every program's compound carry
    ///         denominated in it.
    /// @dev The hook's balance of `asset` is always at least this — every unit it holds is attributed.
    /// @param asset The asset to account.
    /// @return amount Total obligation.
    function obligationOf(address asset) external view returns (uint256 amount);

    /**
     * @notice Preview the pump a swap moving this much secondary would trigger right now.
     * @dev Mirrors the live `afterSwap` sizing at the CURRENT spot and the reference as it would
     *      stand after this block's observation: the fee ceiling, the spend bucket as it has
     *      refilled to this block PLUS the volume credit this very demand would earn it, the gated
     *      share of the demand, the haircut and the pool-exact output floor. Returns zeros for an
     *      unconfigured or empty pot.
     * @param key The pool key.
     * @param demand The secondary the carrying swap moves — paid on a buy of main, received on a
     *        sell of main — which is what the pump's demand ceiling is a share of.
     * @return spend Secondary the pot would spend.
     * @return minOut The output floor the pump would enforce on itself.
     */
    function quotePump(IPoolManagerMin.PoolKey calldata key, uint256 demand)
        external view returns (uint256 spend, uint256 minOut);

    /**
     * @notice The reference gate as it stands right now: the share of a swap's secondary the pump
     *         may match, the live tick and the reference tick it is measured against.
     * @dev The reference is projected to this block (the pending observation applied), exactly
     *      as a swap in this block would see it. Below or at the reference the share is the
     *      maximum; above it, `fee / premium` capped at the maximum.
     * @param poolId The pool identifier.
     * @return shareWad The demand share (1e18 = 100%).
     * @return spotTick The pool's live tick.
     * @return referenceTick The reference tick, floored to a whole tick.
     */
    function pumpShareOf(bytes32 poolId)
        external view returns (uint256 shareWad, int24 spotTick, int24 referenceTick);

    // ═══════════════════════════════════════════════════════════════════════════════
    // LP PROGRAM — LIQUIDITY
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Create the pool's LP program with EVERYTHING OFF and seed its liquidity. Pot-admin only.
     * @dev The normal entry: shares at zero, both recipients defaulting to `owner`, auto-harvest
     *      disarmed — a plain hook-held position whose {harvest} simply pays the owner. The owner can
     *      turn any rule on later with {setProgramConfig}. ONE program per pool; the tick range is
     *      fixed here forever (pass `(0,0)` for full range).
     *
     *      FUNDING. `liquidity` is in the pool's own liquidity units. An ERC20 side settles the EXACT
     *      amount the position needs straight from the caller's allowance to this hook; a native side
     *      (always `currency0`) is prepaid with `msg.value` and the unused excess refunded — the
     *      attached value is a hard cap, since the hook's own inventory is pot money and never funds a
     *      position.
     * @param key The pool key (pot must be configured — the roles define the split's two sides).
     * @param tickLower Lower tick, `(0,0)` = full range.
     * @param tickUpper Upper tick.
     * @param liquidity Liquidity units to mint.
     * @param owner The program's owner and first operator (must be live here: this entry's default
     *              recipients ARE the owner, and a payable leg needs a live recipient).
     * @return amount0 Currency0 the position consumed.
     * @return amount1 Currency1 the position consumed.
     */
    function addLiquidity(
        IPoolManagerMin.PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address owner
    ) external payable returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Create the pool's LP program with FULL RULES at creation and seed its liquidity.
     *         Pot-admin only.
     * @dev Same mechanics as {addLiquidity} plus the split config, validated here. The owner is
     *      also the first operator. `owner == address(0)` ships the program fully surrendered from
     *      birth: rules nobody can ever edit, liquidity nobody can ever pull, manual harvest forced
     *      public. For frozen rules WITHOUT giving up the pool, name a live owner and zero the
     *      operator afterwards ({setProgramOperator}).
     * @param key The pool key (pot must be configured).
     * @param tickLower Lower tick, `(0,0)` = full range.
     * @param tickUpper Upper tick.
     * @param liquidity Liquidity units to mint.
     * @param owner The program's owner and first operator (`address(0)` = surrendered at birth).
     * @param config The split rules (see {ProgramConfig}).
     * @return amount0 Currency0 the position consumed.
     * @return amount1 Currency1 the position consumed.
     */
    function addLiquidityAdvanced(
        IPoolManagerMin.PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address owner,
        ProgramConfig calldata config
    ) external payable returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Add liquidity to an existing program. Owner only.
     * @dev Pending fees are harvested FIRST — through the program's own split — so the add settles
     *      pure principal. Same funding mechanics as {addLiquidity}; the tick range is the program's
     *      own.
     * @param key The pool key.
     * @param liquidity Liquidity units to mint.
     * @return amount0 Currency0 the position consumed.
     * @return amount1 Currency1 the position consumed.
     */
    function addProgramLiquidity(IPoolManagerMin.PoolKey calldata key, uint128 liquidity)
        external payable returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Remove liquidity from the program and send the principal to `to`. Owner only — a live
     *         owner can ALWAYS withdraw; an ownerless program's liquidity is locked forever.
     * @dev Pending fees are harvested FIRST through the split, so the removal delta is pure principal.
     * @param key The pool key.
     * @param liquidity Liquidity units to remove.
     * @param to Receives both principal legs.
     * @return amount0 Currency0 principal returned.
     * @return amount1 Currency1 principal returned.
     */
    function removeProgramLiquidity(IPoolManagerMin.PoolKey calldata key, uint128 liquidity, address to)
        external returns (uint256 amount0, uint256 amount1);

    // ═══════════════════════════════════════════════════════════════════════════════
    // LP PROGRAM — RULES
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Replace the program's split rules. Operator only (impossible once the operator role
     *         was set to `address(0)`).
     * @dev Validated like the advanced entry: each side's shares sum to at most 100% and a live
     *      recipient stands behind every leg that can carry value. An edit only shapes FUTURE
     *      harvests — nothing already split or carried is re-touched, and the standing compound
     *      carry keeps retrying under the new rules.
     * @param poolId The pool identifier.
     * @param config The new split rules.
     */
    function setProgramConfig(bytes32 poolId, ProgramConfig calldata config) external;

    /**
     * @notice Move the operator role — the settings editor. Operator only.
     * @dev `address(0)` freezes the split rules FOREVER without touching the owner's property: the
     *      owner keeps adding, removing and harvesting under rules nobody can ever change. This is
     *      the immutable-rules promise; there is deliberately no way back, and deliberately no
     *      liquidity lock attached to it.
     * @param poolId The pool identifier.
     * @param newOperator The new settings editor (`address(0)` = frozen forever).
     */
    function setProgramOperator(bytes32 poolId, address newOperator) external;

    /**
     * @notice Transfer the program's ownership — the property itself. Owner only.
     * @dev The new owner takes the liquidity rights (add/remove/harvest); the operator role does NOT
     *      travel with it. `address(0)` surrenders the property: the liquidity locks forever and the
     *      manual harvest is forced public so an ownerless program never strands its fees. Richer
     *      custody policy — timelocks, vesting, DAO control — is built ON TOP by transferring
     *      ownership to a contract that implements it (a locker simply becomes the owner).
     * @param poolId The pool identifier.
     * @param newOwner The new property holder (`address(0)` = liquidity locked forever).
     */
    function transferProgramOwnership(bytes32 poolId, address newOwner) external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // LP PROGRAM — HARVEST & PAYOUTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Collect the program's accrued LP fees and run the split. Owner-only unless the
     *         config's `publicHarvest` opens it to anyone.
     * @dev The SAME path the auto-harvest runs — every share off the gross of its side: buyback to
     *      the pot, burn through the cascade, the compound budget (slice + carry) into the position,
     *      remainders pushed to the recipients (refusals booked for {claim} or the next push) — so
     *      the rules apply whether or not the auto-trigger is armed. Runs with the caller's full
     *      gas, which also makes it the natural path for heavy tokens. The auto-harvest stays
     *      inherently public whatever this gate says: any swap that meets the mins triggers it.
     * @param key The pool key.
     * @return mainFees Fees collected on the main side.
     * @return secondaryFees Fees collected on the secondary side.
     */
    function harvest(IPoolManagerMin.PoolKey calldata key)
        external returns (uint256 mainFees, uint256 secondaryFees);

    /**
     * @notice Pull everything booked to the caller in `asset`. Full-gas, reverting delivery.
     * @param asset The asset to claim.
     * @return amount The amount delivered.
     */
    function claim(address asset) external returns (uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════════════
    // LP PROGRAM — VIEWS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice A pool's LP program.
    /// @param poolId The pool identifier.
    /// @return program The full program record.
    function programOf(bytes32 poolId) external view returns (Program memory program);

    /// @notice Harvest legs booked to `to` in `asset` after refused pushes.
    /// @param to The recipient.
    /// @param asset The asset.
    /// @return amount The claimable backlog.
    function owedOf(address to, address asset) external view returns (uint256 amount);

    /// @notice Cumulative harvest legs DELIVERED to a native program's engine in `asset`.
    /// @dev Monotonic. The engine attributes from `recordHarvest` and reconciles any failed
    ///      callback by diffing this against its own cursor — the exactly-once source of truth.
    ///      Zero for every non-native program.
    /// @param poolId The pool identifier.
    /// @param asset The pool currency (`address(0)` = native).
    /// @return amount The cumulative delivered total.
    function deliveredCumOf(bytes32 poolId, address asset) external view returns (uint256 amount);
}
