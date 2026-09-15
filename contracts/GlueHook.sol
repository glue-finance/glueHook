// SPDX-License-Identifier: BUSL-1.1
//
// Licensed Work: GlueHook
// The Licensed Work is (c) 2026 gluefinance.eth and is owned exclusively by Glue Labs Inc. (Delaware).
// Licensor: Glue Labs Inc. (Delaware)
// Change Date: the earlier of 2030-08-05 or a date specified at gluehook-license-date.gluefinance.eth
// Change License: GNU General Public License v2.0 or later
// Full licence text: https://github.com/glue-finance/GlueHook/blob/main/LICENCE.txt

pragma solidity ^0.8.35;

import {GluedV4Core, GluedV4Callback, IPoolManagerMin} from "./libs/GluedV4Core.sol";
import {GluedMath} from "./libs/GluedMath.sol";
import {GlueLiquidity} from "./libs/GlueLiquidity.sol";
import {IGlueHook} from "./interfaces/IGlueHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 *  ██████╗ ██╗     ██╗   ██╗███████╗██╗  ██╗ ██████╗  ██████╗ ██╗  ██╗
 * ██╔════╝ ██║     ██║   ██║██╔════╝██║  ██║██╔═══██╗██╔═══██╗██║ ██╔╝
 * ██║  ███╗██║     ██║   ██║█████╗  ███████║██║   ██║██║   ██║█████╔╝
 * ██║   ██║██║     ██║   ██║██╔══╝  ██╔══██║██║   ██║██║   ██║██╔═██╗
 * ╚██████╔╝███████╗╚██████╔╝███████╗██║  ██║╚██████╔╝╚██████╔╝██║  ██╗
 *  ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝
 *
 * @title  GlueHook - Uniswap V4 buyback-and-burn hook with auto-compounding LP fee programs
 * @author @lalilulel0x - La Li Lu Le Lo
 * @notice One hook singleton hosting a permissionless donation POT for every pool that adopts it: the
 *         pot buys the pool's own asset behind every swap — buys and sells alike, sized by a
 *         reference-price gate that lets it buy dips at full size and rallies only as far as
 *         farming it would cost more than it pays — and everything it buys is delivered to the pot's
 *         recipient — `address(0)` means BURN, so the default configuration is buy-and-burn. Each pool
 *         may additionally run one LP PROGRAM: a hook-held liquidity position whose trading fees are
 *         auto-harvested inside swaps and split off the GROSS of each side — a COMPOUND share re-minted
 *         into the position (the auto-compounding concentrated-liquidity venues lack natively), a
 *         buyback share fuelling the pot, a burn share through the cascade, the rest to one recipient
 *         per side; what the compound mint cannot place is carried and retried at every next harvest.
 * @dev    ROLES. A hooked pool names one of its two currencies MAIN (the asset being defended, bought
 *         back and delivered) and the other becomes SECONDARY (the buyback currency, the only asset the
 *         pot holds and the only asset {donate} accepts). Either side may be main and either may be
 *         native, so the hook is pair-agnostic — a token quoted in ETH is one configuration, not a rule.
 *
 *         ┌──────────────────────────────────────────────────────────────────────────────────────────┐
 *         │  THE PUMP — afterSwap, behind EVERY swap of a funded pool, in either direction           │
 *         │                                                                                          │
 *         │  Once the swapper's trade has executed, the pot buys main in that same transaction and   │
 *         │  delivers it. Behind a buy it adds to the demand; behind a sell it buys the dip the sell │
 *         │  just made. The swap runs in a self-call, so a pool state that would make the pump      │
 *         │  revert skips the pump instead of breaking the carrying swap, and the swapper's own      │
 *         │  execution — output, price limit, router minimum — is never touched.                     │
 *         │                                                                                          │
 *         │  Its size is the SMALLEST of four ceilings, then an 80% haircut:                         │
 *         │    · the FEE CEILING     `f·R`   — fee × tangent depth, the un-sandwichable size         │
 *         │    · the SPEND BUCKET            — at most one fee ceiling, refilled `k×` the fee every  │
 *         │                                    swap pays plus a slow time floor: the pot's pace is   │
 *         │                                    paced to what the pool EARNS                          │
 *         │    · the DEMAND CEILING  `s·B`   — a share of the secondary the swap moved (paid on a    │
 *         │                                    buy, received on a sell)                              │
 *         │    · the REFERENCE GATE  `s(d)`  — the share itself: 60% at or below the pool's          │
 *         │                                    time-weighted reference tick, `f/d` above it, where   │
 *         │                                    `d` is main's premium over the reference              │
 *         └──────────────────────────────────────────────────────────────────────────────────────────┘
 *
 *         WHY THE PUMP CANNOT BE SANDWICHED. A pump is a market buy that somebody else's transaction
 *         triggers, which is the exact shape of a sandwich victim: buy in front of it, let it lift the
 *         price, sell behind it. That attack earns `2·X·V/R` and costs `2·f·X` in fees (`X` the
 *         attacker's size, `V` the pump's spend, `R` the pool's depth, `f` its fee), so the attacker's
 *         own size cancels and the attack pays if and only if `V > f·R`. The pump therefore refuses to
 *         spend more than `f·R` in a single pass, which closes the attack for every attacker size, pot
 *         depth and price at once.
 *
 *         WHY THE PUMP CANNOT BE FARMED. The demand ceiling is what lets a trader summon a pump by
 *         trading — and a trader who first pushes spot up by a premium `d` and then trades is
 *         summoning a pump at an inflated price, which they can sell into. Pushing costs them `2·f`
 *         per unit pushed (in and out) and the pump hands back at most `d` per unit of pump; BOTH
 *         legs of their round trip summon pumps at the premium (the push and the dump), so with the
 *         pump's spend a share `s` of each leg the round trip pays if and only if `2·s·d > 2·f`.
 *         The gate therefore sets `s(d) = min(60%, f/d)`, which puts EVERY such round trip at or
 *         below break-even before the haircut — and the haircut, the impact of their own unwind and
 *         the fee on the trade itself are all further losses on top. At or below the reference there
 *         is no premium to sell into, so the share is the full 60%: dips, ordinary trading and
 *         choppy markets are bought at full size; a genuine rally is bought at a size that shrinks
 *         with its premium and grows back as the reference catches up.
 *
 *         WHY THE PUMP CANNOT BE RUSHED. The gate has nothing to say at or below the reference —
 *         and a holder of a large bag who manufactures volume there (cheap round trips, each one
 *         summoning a pump) is compressing the pot's whole future spend into a moment they alone
 *         are positioned for. The SPEND BUCKET closes the rush by pacing the pot to what the pool
 *         EARNS: it holds at most one fee ceiling, every funded swap credits it {PUMP_FEE_LEVERAGE}
 *         times the fee that swap paid, and time credits it one ceiling per {PUMP_REFILL} as a slow
 *         floor. Over any window the pot spends at most `k ×` the LP fees earned plus the floor —
 *         a hot market is bought hard, a dead one barely, and manufactured volume unlocks only `k ×`
 *         what it cost in fees, so farming the pot needs a bag above `depth / 2k` of the pool, held
 *         the whole time, at the market's mercy and lifted no more than every other holder.
 *
 *         WHY A HELD PRICE IS SLOW TO BELIEVE. The reference may FALL freely — a dip reopens the
 *         gate at once — but may RISE at most {REFERENCE_MAX_RISE_PER_MINUTE} ticks (≈3%) a minute.
 *         Reopening the gate after a `+d` push therefore takes `d / 3%` minutes of a price held
 *         against the whole market, however the time constant is set; an attacker who controls
 *         consecutive blocks pays in blocks proportional to the move they want the pot to believe.
 *
 *         THE REFERENCE. Each funded pool's pot carries a time-weighted average of the pool's tick
 *         ({REFERENCE_TAU}, ten minutes: an observation `dt` after the last moves it `min(1, dt/τ)`
 *         of the way to the tick that stood in between), fed only by ticks that STOOD across a
 *         block boundary: an observation weights the tick left by the PREVIOUS swap by the time it
 *         stood, and a swap in the same block as the last one adds nothing. Nothing a transaction
 *         does to spot inside its own block therefore enters the reference — moving it means
 *         holding a price against the whole market for minutes, exposed to arbitrage the whole
 *         time. It is seeded from the live tick at {initPot} and whenever a donation funds an empty
 *         pot, advanced behind every swap of a funded pool, stored in the pot's own slot (so a swap
 *         reads it for free) and computed in bounded integer arithmetic that cannot revert.
 *
 *         DELIVERY & THE BUYBACK SPLIT. A pot names a recipient for the main it buys;
 *         `address(0)` means BURN. When the pool carries an LP PROGRAM, the pot's output first runs
 *         the BUYBACK SPLIT (operator-set in the program config, both shares zero by default):
 *         `potCompoundShareWad` joins the program's main-side compound carry — buy pressure becoming
 *         the pool's own liquidity at the next harvest's mint — `potBurnShareWad` joins the burn
 *         path, and the EXACT rest follows the pot's recipient as an unsplit delivery would. A
 *         live recipient is delivered to directly (a plain transfer that never reverts the swap)
 *         and a refusal parks the main here, retryable any time through {flushDirect}. A pot's MAIN
 *         must be GLUEABLE — never the network token and never {NATIVEWRAP} ({initPot} rejects
 *         both) — because a BURN is the Glue Protocol's own, in the shape the main's
 *         CLASSIFICATION dictates (read once at declaration from the {GLUE_STICK}'s registry):
 *         a glued main burns through its own GlueWrapper's pure `unglue` (an exact allowance, an
 *         empty collateral list that redeems nothing — the supply is destroyed and the glue's
 *         backing concentrates for every remaining holder); a main that IS a GlueWrapper (the
 *         ERC20 face of a wrapped ERC20 or ERC721 collection, which no unglue can burn) is PARKED
 *         — transferred to the wrapper's own address, the one custody Glue's supply oracle
 *         subtracts from circulation. Either is verified by the hook's own balance drop and NEVER
 *         able to revert the carrying swap. A main the Stick refused at declaration is glued
 *         lazily at its first burn; one whose burn refuses is flagged {unburnable} and every burn
 *         of it settles to the held ledger: the amount is HELD on the hook FOREVER, no withdrawal
 *         path exists, so custody IS the burn.
 *
 *         LP PROGRAM & AUTO-COMPOUNDING. The pot admin may create the pool's single hook-held liquidity
 *         position ({addLiquidity} plain, {addLiquidityAdvanced} with full rules at creation). Its fees
 *         are harvested automatically inside `afterSwap` once they reach the configured minimums (a
 *         try/catch self-call — a heavy harvest never reverts the carrying swap; a program with both
 *         minimums disarmed costs a swap ONE storage read and never scans) or manually through
 *         {harvest}. The collect and the compound mint are ONE `modifyLiquidity`: the fees pay the
 *         mint in the PoolManager's own netting, verified against its `feesAccrued`, with the
 *         collect-only path as the fallback. Every share is a fraction of the GROSS fees of its side (`compound + buyback` and
 *         `compound + burn` each capped at 100% at set-time): the buyback share fuels the pot, the burn
 *         share runs the cascade, and the exact remainder of each side goes to its one recipient. The
 *         COMPOUND budget — `compoundShareWad` of both sides PLUS whatever earlier mints could not
 *         place — is re-minted into the position at the live price, the auto-compounding V3/V4 never
 *         gave LPs natively, powered by the same no-keeper, no-oracle, traffic-driven trigger as the
 *         buyback. Whichever side binds caps the mint, and the unplaced rest goes back into the CARRY,
 *         retried at every next harvest — it never leaks to the pot or a recipient. A failed mint
 *         abandons the compound alone; a config edit only shapes future harvests.
 *         Two independent roles govern it — the OWNER holds the property (liquidity, harvest, transfer),
 *         the OPERATOR edits the rules — and either surrenders to `address(0)` without dragging the
 *         other down. The engine lives in the {GlueLiquidity} delegatecall library.
 *
 *         ACCOUNTING. Every unit the hook holds is attributed: {obligationOf} sums every pot denominated
 *         in an asset plus anything parked, held, or owed in it, and the hook's balance of that asset is
 *         always at least that sum. There is no withdrawal path for any of them.
 */
contract GlueHook is GluedV4Callback, IGlueHook {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS & IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Native currency sentinel — V4 keys the network token as `address(0)`.
    address private constant ETH_ADDRESS = address(0);

    /// @notice The permission bits a GlueHook address must carry: `beforeInitialize` and `afterSwap`
    ///         (0x2040).
    /// @dev The PoolManager reads a hook's permissions from the low 14 bits of its address, so the hook
    ///      must be CREATE2-mined to an address whose low bits equal EXACTLY this value.
    uint160 public constant REQUIRED_HOOK_FLAGS = GluedV4Core.BEFORE_INITIALIZE_FLAG
        | GluedV4Core.AFTER_SWAP_FLAG;

    /// @notice The time constant of the reference tick: an observation `dt` seconds after the last
    ///         moves the reference `min(1, dt / REFERENCE_TAU)` of the way to the tick that stood
    ///         in between. Moving the reference by a premium therefore means holding that premium
    ///         against the market for minutes, not for a transaction.
    uint32 public constant REFERENCE_TAU = 10 minutes;
    /// @notice The most the reference may RISE — main getting dearer — per minute, in ticks
    ///         (296 ticks ≈ 3%). A fall is never capped: a dip reopens the gate at once. Reopening
    ///         the gate after a `+d` push therefore takes `d / 3%` minutes of a HELD price, whatever
    ///         the time constant: the bigger the pump in price, the longer the pot stays cautious,
    ///         and an attacker who controls consecutive blocks pays in blocks proportional to the
    ///         move they want the pot to believe.
    uint32 public constant REFERENCE_MAX_RISE_PER_MINUTE = 296;
    /// @notice The spend bucket's TIME base: with no volume at all the pot may still spend one fee
    ///         ceiling (`f·R`) per this long — a slow floor so a dead market's rare dump is still
    ///         bought — refilling linearly.
    uint32 public constant PUMP_REFILL = GlueLiquidity.PUMP_REFILL;
    /// @notice The spend bucket's VOLUME credit: every funded swap credits the bucket with this
    ///         multiple of the fee it paid (`k · fee · secondary moved`), capped at one fee ceiling.
    ///         The pot's pace is therefore `k ×` what the pool earns: a hot market is bought hard, a
    ///         dead one barely, and manufactured volume unlocks only `k ×` what it cost — so
    ///         farming the pot needs a bag larger than `depth / 2k` of the pool.
    uint256 public constant PUMP_FEE_LEVERAGE = GlueLiquidity.PUMP_FEE_LEVERAGE;
    /// @notice The largest share of a swap's secondary the pump matches (0.6e18 = 60%), the share
    ///         at or below the reference. Above it the share is `fee / premium`, so at a 0.3% fee
    ///         the full share holds up to a 0.5% premium and halves for every doubling beyond.
    uint256 public constant PUMP_SHARE_MAX_WAD = GlueLiquidity.PUMP_SHARE_MAX_WAD;

    /// @dev Share of the capped spend the pump actually uses (8_000 = 80%). The 20% it leaves behind is
    ///      what puts the spend strictly INSIDE both break-evens — the sandwich's and the
    ///      push-and-trade farm's — rather than exactly on them, plus headroom against the sizing
    ///      quote drifting from real execution. Lives in {GlueLiquidity} with the sizing body.
    uint256 private constant PUMP_HAIRCUT_BPS = GlueLiquidity.PUMP_HAIRCUT_BPS;
    /// @dev The hook's own unlock op on top of {GluedV4Callback}'s four: the merged HARVEST
    ///      (collect + compound mint in one `modifyLiquidity`). The literal MUST match the
    ///      library's.
    uint8 private constant OP_HARVEST = 5;

    /// @notice The Glue Protocol's GlueStick singleton — the SAME address on every chain. Pool
    ///         creation CLASSIFIES the main through its registry ({IGlueStickMin.wrapperOf}: a
    ///         wrapper main resolves to itself, a glued main to its wrapper) and ensures a fresh
    ///         main's glue through it ({IGlueStickMin.ensureWrapper}, best effort). EVERY burn leg
    ///         then runs against the recorded glue — a pure {IGlueWrapperMin.unglue} on the main's
    ///         own wrapper, or a PARK on a wrapper main: the hook never destroys supply itself, the
    ///         Glue Protocol does. A program whose creator the registry reports as a REGISTERED LP
    ///         engine ({IGlueStickMin.isRegisteredEngine}) is stamped NATIVE (see {IGlueHook}).
    address public constant GLUE_STICK = 0xBe99cB426fDf30F95784337d4e8CC460AC8e8608;

    /// @notice This chain's canonical wrapped-native token — the WETH9-style wrapper Uniswap's own
    ///         periphery uses (WETH, WBNB, WPOL, WAVAX…). `address(0)` on a chain with no spendable
    ///         native coin. A pot's MAIN may never be this address (nor the network token itself):
    ///         the burn path is Glue's unglue, and the network wrapper is not glueable by design.
    address public immutable NATIVEWRAP;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev poolId => the pool's buyback pot.
    mapping(bytes32 => Pot) private _pots;
    /// @dev poolId => the pool's LP PROGRAM: the one hook-held liquidity position and its split rules.
    mapping(bytes32 => Program) private _programs;
    /// @dev The delivery and attribution ledgers ({IGlueHook.Ledgers}): pot totals, parked, held,
    ///      unburnable flags, owed backlogs and the compound-carry totals — ONE storage struct so
    ///      the {GlueLiquidity} delivery engine shares them through a single pointer. Every field
    ///      is an {obligationOf} term (or a flag), and none has a withdrawal path beyond its own
    ///      documented exit ({flushDirect}, {claim}, the compound mint).
    Ledgers private _ledgers;

    // ═══════════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Deploy the hook against a fixed PoolManager and this chain's wrapped native.
    /// @dev Must be deployed at an address whose low 14 bits equal {REQUIRED_HOOK_FLAGS}; the
    ///      constructor asserts it, so a mis-mined deployment fails at deploy time rather than at the
    ///      first `initialize`.
    /// @param _poolManager The Uniswap V4 PoolManager on this chain.
    /// @param _nativeWrap This chain's canonical wrapped native (see {NATIVEWRAP}); `address(0)` on
    ///                    a chain with no spendable native coin.
    constructor(address _poolManager, address _nativeWrap) GluedV4Callback(_poolManager) {
        // The address itself carries the hook's permissions — a wrong one is unusable
        if (uint160(address(this)) & GluedV4Core.ALL_HOOK_MASK != REQUIRED_HOOK_FLAGS) revert BadRoles();
        NATIVEWRAP = _nativeWrap;
    }

    /// @dev Transient-storage reentrancy guard, slot derived per deployment.
    modifier guarded() {
        _lockGuard();
        _;
        assembly ("memory-safe") { tstore(GUARD_SLOT, 0) }
    }

    /// @dev The transient reentrancy-guard slot: `keccak256("GlueHook.guard")` (a literal because
    ///      inline assembly only accepts direct number constants).
    bytes32 private constant GUARD_SLOT = 0x165848338463d30c17057f5abfcc323310dd08e72aea99ae6ce410ff3a16adf0;

    /// @dev The guard's entry half, shared by every guarded entry instead of inlined into each.
    function _lockGuard() private {
        assembly ("memory-safe") {
            if tload(GUARD_SLOT) {
                // Reentrancy()
                mstore(0x00, 0xab143c06)
                revert(0x1c, 0x04)
            }
            tstore(GUARD_SLOT, 1)
        }
    }

    /// @notice Accept native currency so the hook can hold a native pot and be paid by `PoolManager.take`.
    receive() external payable {}

    // ═══════════════════════════════════════════════════════════════════════════════
    // HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Record the pool's initialiser as its pot admin.
     * @dev The only way to become a pot's admin: whoever calls `PoolManager.initialize` on a pool that
     *      names this hook owns that pot's configuration. The roles themselves come later through
     *      {initPot}, because `beforeInitialize` carries no hook data to put them in. A pool launched
     *      through {launchPool} never reaches this callback at all — the PoolManager skips hook calls
     *      when the hook itself is the caller — so {launchPool} records its own caller as the admin
     *      (and runs the same dynamic-fee rejection itself).
     *
     *      DYNAMIC-FEE POOLS ARE REFUSED OUTRIGHT: this hook serves static-fee pools only. The fee
     *      is part of the pool's identity here — a million distinguishable static values per pair
     *      that creators may use as a namespace — and every price this hook quotes reads the one
     *      immutable fee the key declares.
     * @param sender The address that called `PoolManager.initialize`.
     * @param key The pool being initialised.
     * @return The callback's own selector, as the PoolManager requires.
     */
    function beforeInitialize(address sender, IPoolManagerMin.PoolKey calldata key, uint160)
        external returns (bytes4)
    {
        // Only the PoolManager may drive a hook callback
        if (msg.sender != POOL_MANAGER) revert NotAllowed();
        // Static-fee pools only: the dynamic-fee sentinel is refused at the door
        if (key.fee == GluedV4Core.DYNAMIC_FEE_FLAG) revert BadConfig();

        bytes32 id = _idOf(key);
        // A pool can only be initialised once, so this can only be written once
        _pots[id].admin = sender;
        emit PotOpened(id, sender);
        return this.beforeInitialize.selector;
    }

    /**
     * @notice After every swap on a configured pool: harvest the LP program if armed, observe the
     *         reference and pump behind the swap, then place everything in ONE batched send phase.
     * @dev Order matters and is deliberate:
     *
     *        1. AUTO-HARVEST — when the pool carries a program whose pending fees reach a min, collect
     *           and split them (the compound budget — slice + carry — re-mints into the program's own
     *           position in the same frame). Runs FIRST so the harvest's buyback share is in the pot
     *           before the pump sizes itself — a fresh fee credit is pump-able in the same swap. Behind
     *           a try/catch self-call ({executeHarvest}), so it can never revert the carrying swap.
     *        2. OBSERVE — on a funded pool, advance the reference tick with the tick that stood since
     *           the last swap, then record the tick this swap left ({_observe}). Bounded arithmetic
     *           on the pot's own slot; an empty pot skips it, so a pool that only runs a program pays
     *           nothing for a reference it does not use.
     *        3. PUMP — in EITHER direction, spend pot secondary on main. Sized by {_pumpSize}: the fee
     *           ceiling, the spend bucket, the reference-gated share of the secondary the swap just
     *           moved, the haircut.
     *           {executePump} BOOKS what it bought instead of delivering it.
     *        4. BATCHED SEND PHASE — the only external sends in the frame, after ALL bookkeeping: the
     *           harvest's burn leg and the pump's burn-intent output merge into ONE cascade walk, the
     *           pump's direct delivery and the harvest's main leg merge into ONE push when they share a
     *           recipient, and the secondary leg goes out last. A refusal parks or books, never reverts.
     *
     *      The whole callback is `guarded`: a recipient re-entering during its full-gas send hits the
     *      transient guard on every state-bearing entry, including a nested `afterSwap`.
     * @param sender The address that called `PoolManager.swap`.
     * @param key The pool key.
     * @param params The swap parameters.
     * @param delta The swapper's balance delta for the swap that just executed.
     * @return selector The callback's own selector.
     * @return hookDelta Always zero — the pump is the hook's own swap, not a delta on the swapper's.
     */
    function afterSwap(
        address sender,
        IPoolManagerMin.PoolKey calldata key,
        IPoolManagerMin.SwapParams calldata params,
        int256 delta,
        bytes calldata
    ) external guarded returns (bytes4 selector, int128 hookDelta) {
        // Only the PoolManager may drive a hook callback
        if (msg.sender != POOL_MANAGER) revert NotAllowed();
        selector = this.afterSwap.selector;
        // The pump must never pump its own pump (and a harvest collect never swaps at all)
        if (sender == address(this)) return (selector, 0);

        bytes32 id = _idOf(key);
        Pot storage p = _pots[id];
        // An unconfigured pot has no roles, so neither the harvest split nor the pump can run
        if (!p.configured) return (selector, 0);

        bool mainIsZero = p.main == key.currency0;

        // 1. AUTO-HARVEST — fires on any swap direction; credits the pot before the pump reads it
        (uint256 burnLeg, uint256 mainLeg, uint256 secLeg) = _autoHarvest(id, key, mainIsZero);

        // 2 + 3. OBSERVE and PUMP — only against a funded pot
        uint256 pumpBought;
        if (p.balance != 0) {
            // The pool's state after the swapper's trade: the tick the reference will see and the
            // price the pump is sized at
            GluedV4Core.Slot0 memory slot0 = GluedV4Core.getSlot0(POOL_MANAGER, id);
            _observe(p, slot0.tick, mainIsZero);

            // The secondary the swap moved is the yardstick the pump's demand ceiling is a share of
            uint256 demand = _demandOf(delta, mainIsZero, params.zeroForOne != mainIsZero);
            if (demand != 0) {
                (uint256 spend, uint256 minOut, uint32 bucketCredited, uint32 bucketAfter) =
                    _pumpSize(key, id, p, slot0, demand, p.referenceTickX8); // observed this block
                // The swap's volume credit lands whether or not a pump follows it
                uint32 bucket = bucketCredited;
                if (spend != 0) {
                    // Self-call: a revert in here rolls back the pump alone, never the carrying swap
                    try this.executePump(id, key, !mainIsZero, spend, minOut) returns (uint256 bought) {
                        pumpBought = bought;
                        // Only a pump that went through draws on the bucket
                        bucket = bucketAfter;
                    } catch {}
                }
                if (bucket != 0 && bucket != p.pumpBucketTimestamp) p.pumpBucketTimestamp = bucket;
            }
        }

        // 4. BATCHED SEND PHASE — nothing above pushed anything; everything below only pushes.
        // The pump's output runs the BUYBACK SPLIT inside {GlueLiquidity.place}: the compound leg
        // joins the program's carry, the burn leg and the harvest's merge into ONE cascade walk,
        // and the exact rest follows the pot's recipient.
        GlueLiquidity.place(p, _programs[id], _ledgers, id, burnLeg, mainLeg, secLeg, pumpBought);
    }

    /**
     * @notice The pump's swap, isolated in its own call frame.
     * @dev Self-only. Runs inside the swapper's unlock, so it swaps through {_swapInUnlock} rather than
     *      opening an unlock of its own. Reverting here is a valid outcome: it undoes the pot debit and
     *      the swap together and leaves the carrying transaction alone. The bought main stays on the
     *      hook — {afterSwap}'s batched send phase places it, merged with the harvest legs.
     * @param id The pool identifier.
     * @param key The pool key.
     * @param zeroForOne Direction of the pump's buy.
     * @param spend Secondary to spend.
     * @param minOut Output floor derived from the pool's own arithmetic.
     * @return bought Main acquired, held here for the caller's send phase.
     */
    function executePump(
        bytes32 id,
        IPoolManagerMin.PoolKey calldata key,
        bool zeroForOne,
        uint256 spend,
        uint256 minOut
    ) external returns (uint256 bought) {
        // Only reachable from {afterSwap}
        if (msg.sender != address(this)) revert NotAllowed();

        Pot storage p = _pots[id];
        address secondary = p.secondary;
        // Debit before spending, so nothing re-entered can see the money twice
        p.balance -= spend;
        _ledgers.potTotal[secondary] -= spend;

        uint256 used;
        (used, bought) = _swapInUnlock(key, zeroForOne, spend);

        // Return anything the pool did not take
        if (used < spend) {
            uint256 back = spend - used;
            p.balance += back;
            _ledgers.potTotal[secondary] += back;
        }

        // The floor is the pool's own quote minus a rounding allowance; missing it means the quote and
        // the execution disagree, so the whole pump is abandoned.
        if (bought < minOut) revert QuoteMismatch();

        emit Pumped(id, used, bought);
    }

    /**
     * @notice The auto-harvest's merged collect-compound-split, isolated in its own call frame.
     * @dev Self-only, delegating to {GlueLiquidity-harvest}. Runs inside the swapper's unlock, so
     *      it touches the position with ONE direct `modifyLiquidity`: the compound budget (this
     *      harvest's slice + the standing carry) is sized off the pending fees the caller already
     *      scanned and minted in the same call that collects them — only the net moves, verified
     *      against V4's own `feesAccrued` and the budget. Splits the fees off the gross of each
     *      side — buyback share into the pot, burn share and the two recipient legs RETURNED for
     *      the caller's batched send phase — but sends nothing itself. Reverting here rolls the
     *      whole frame back and leaves the carrying swap alone: the caller retries once with
     *      `mint == false` (the collect-only path, compound budget carried), and if that fails too
     *      the fees stay safely uncollected in the position.
     * @param id The pool identifier.
     * @param key The pool key.
     * @param f0 Pending currency0 fees per the caller's scan.
     * @param f1 Pending currency1 fees per the caller's scan.
     * @param mint True to run the merged compound mint; false forces the collect-only path.
     * @return burnLeg Main-side slice for the burn cascade.
     * @return mainLeg Main-side slice for the program's main recipient.
     * @return secLeg Secondary-side slice for the program's secondary recipient.
     */
    function executeHarvest(bytes32 id, IPoolManagerMin.PoolKey calldata key, uint256 f0, uint256 f1, bool mint)
        external returns (uint256 burnLeg, uint256 mainLeg, uint256 secLeg)
    {
        // Only reachable from {afterSwap}
        if (msg.sender != address(this)) revert NotAllowed();
        ( , , burnLeg, mainLeg, secLeg) =
            GlueLiquidity.harvest(_pots[id], _programs[id], _ledgers, POOL_MANAGER, id, key, f0, f1, true, mint);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Declare a hooked pool's roles. One-shot, and only the pool's initialiser may call it.
     * @dev Until this runs the hook does nothing on the pool: no pump, no reference, and {donate}
     *      reverts. `main` must be one of the key's two currencies; the other becomes `secondary`
     *      automatically. `main` must be GLUEABLE — never the network token and never {NATIVEWRAP}
     *      (the burn path is Glue's unglue, and neither can run it); the declaration also ensures
     *      the main's glue exists ({GLUE_STICK}.`ensureWrapper`, best effort — a failure never
     *      blocks the pool, later burns just settle to the held ledger). The body lives in
     *      {GlueLiquidity.initPot} (delegatecall: same storage, same `msg.sender`, so the admin
     *      gate is unchanged); the reference tick is then seeded from the pool's live tick.
     * @param key The pool key (must already be initialised through this hook).
     * @param main The currency to defend, buy back and deliver.
     * @param recipient Where bought main goes; `address(0)` means burn.
     */
    function initPot(IPoolManagerMin.PoolKey calldata key, address main, address recipient) external {
        bytes32 id = _idOf(key);
        GlueLiquidity.initPot(_pots[id], _ledgers, key, id, main, recipient, NATIVEWRAP);
        _seedReference(_pots[id], id);
    }

    /**
     * @notice Launch a hooked pool in ONE transaction: initialise the pool on the PoolManager,
     *         declare the pot's roles and create the LP program with its seed liquidity.
     * @dev The caller becomes the pot admin, exactly as if they had called `PoolManager.initialize`
     *      themselves. The capture is sound because the PoolManager SKIPS hook callbacks when the
     *      hook itself is the caller: `beforeInitialize` never runs here, a successful initialise
     *      proves the pool was fresh (so the admin slot is provably virgin — only the callback, one
     *      shot per pool, could ever have written it), and this entry records its own caller
     *      instead. The {initPot} and {addLiquidityAdvanced} bodies then run with the same
     *      validation, events and funding rules as the standalone entries: `main` must be one of
     *      the key's two currencies and glueable (never the network token, never {NATIVEWRAP} —
     *      its glue is ensured best-effort at declaration), the config's
     *      per-side shares must fit, and the seed settles from the caller — an ERC20 side from
     *      their allowance to this hook, a native side (always `currency0`) from `msg.value` with
     *      the unused excess refunded. Reverts if the pool already exists, and a failure anywhere
     *      rolls the WHOLE launch back (no pool, no pot, nothing half-created). Pools that want the
     *      three steps separately (or no program at all) can still run them individually.
     * @param key The pool key (must name this hook).
     * @param sqrtPriceX96 The pool's initial sqrt price, Q64.96.
     * @param main The currency to defend, buy back and deliver.
     * @param recipient Where bought main goes; `address(0)` means burn.
     * @param tickLower Lower tick, `(0,0)` = full range.
     * @param tickUpper Upper tick.
     * @param liquidity Liquidity units to mint as the program's seed.
     * @param owner The program's owner and first operator (`address(0)` = surrendered at birth).
     * @param config The split rules (see {IGlueHook.ProgramConfig}).
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
    ) external payable guarded returns (uint256 amount0, uint256 amount1) {
        // The key must name this hook, or the initialise below would create a pool the hook never sees
        if (key.hooks != address(this)) revert BadRoles();
        // Static-fee pools only — the same door {beforeInitialize} closes (that callback is
        // skipped when the hook itself initialises, so the launch re-checks it here)
        if (key.fee == GluedV4Core.DYNAMIC_FEE_FLAG) revert BadConfig();

        // A successful initialise proves the pool is FRESH — and since the PoolManager skips hook
        // callbacks when the hook itself is the caller, `beforeInitialize` never ran and the pot's
        // admin slot is still virgin: record the launcher directly, exactly what the callback would
        // have recorded had they initialised the pool themselves
        IPoolManagerMin(POOL_MANAGER).initialize(key, sqrtPriceX96);
        bytes32 id = _idOf(key);
        _pots[id].admin = msg.sender;
        emit PotOpened(id, msg.sender);

        // Declare the roles with the library's full one-shot validation — inside the delegatecall
        // `msg.sender` is the launcher, the admin just recorded
        GlueLiquidity.initPot(_pots[id], _ledgers, key, id, main, recipient, NATIVEWRAP);
        // The reference starts at the launch price
        _seedReference(_pots[id], id);

        // Create the program and seed its liquidity, exactly as {addLiquidityAdvanced} would
        (amount0, amount1) = GlueLiquidity.createProgram(
            _pots[id], _programs[id], POOL_MANAGER, id, key, tickLower, tickUpper, liquidity, owner, config
        );
    }

    /**
     * @notice Move where a pot delivers the main it buys.
     * @dev Admin-only. `address(0)` means burn (a pure Glue unglue); any other value is a
     *      literal delivery target. The body lives in {GlueLiquidity.setRecipient}.
     * @param poolId The pool identifier.
     * @param recipient The new recipient (`address(0)` = burn).
     */
    function setRecipient(bytes32 poolId, address recipient) external {
        GlueLiquidity.setRecipient(_pots[poolId], poolId, recipient);
    }

    /**
     * @notice Retry the delivery of main that was parked because the pot's live recipient refused it.
     *         Permissionless.
     * @dev Sends the pool's whole direct-parked balance to the pot's CURRENT recipient (the admin may
     *      have moved it since the park — the pot's recipient is always the source of truth). Reverts if
     *      there is nothing parked for the pool, the pot has since been pointed at burn, or the recipient
     *      refuses again (the park is left intact for a later attempt).
     * @param poolId The pool whose direct-parked main is retried.
     * @return delivered The amount delivered to the pot's recipient.
     */
    function flushDirect(bytes32 poolId) external guarded returns (uint256 delivered) {
        return GlueLiquidity.flushDirect(_pots[poolId], _ledgers, poolId);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FUNDING
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Fund a pot with its SECONDARY currency. Permissionless.
     * @dev Native secondary: attach the donation as value and pass `amount == msg.value`. ERC20
     *      secondary: attach no value and approve this hook first — the credit is the measured
     *      balance delta, so a fee-on-transfer token credits exactly what arrived. The pot's main
     *      can never be donated: the credit is always denominated in secondary. A donation that
     *      funds an EMPTY pot re-seeds the reference tick from the live price first — an empty pot
     *      observes nothing, so whatever it last saw is stale; the pump it now enables starts from
     *      the price the market stands at (a donor who moved that price only exposes their own
     *      donation, and every later swap corrects the reference).
     * @param key The pool key whose pot is funded.
     * @param amount The donation amount.
     * @return credited The amount actually added to the pot.
     */
    function donate(IPoolManagerMin.PoolKey calldata key, uint256 amount)
        external payable guarded returns (uint256 credited)
    {
        bytes32 id = _idOf(key);
        Pot storage p = _pots[id];
        // Nothing can be funded before the roles exist — otherwise there is no "secondary" to credit
        if (!p.configured) revert PotNotReady();

        address secondary = p.secondary;
        // A native pot is funded with value, an ERC20 pot with an allowance — never both, never neither
        if (secondary == ETH_ADDRESS ? msg.value != amount : msg.value != 0) revert BadDonation();

        // Measured credit, so a fee-on-transfer secondary books exactly what arrived
        credited = _pullToken(secondary, msg.sender, address(this), amount);
        if (credited == 0) revert BadDonation();

        // An empty pot has not been observing: restart the reference from where the market stands
        if (p.balance == 0) _seedReference(p, id);
        p.balance += credited;
        _ledgers.potTotal[secondary] += credited;
        emit Donated(id, msg.sender, credited);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // LP PROGRAM — LIQUIDITY
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Create the pool's LP program with EVERYTHING OFF and seed its liquidity. Pot-admin
     *         only.
     * @dev The normal entry: shares at zero, both recipients defaulting to `owner`, auto-harvest
     *      disarmed — a plain hook-held position whose {harvest} simply pays the owner. The owner
     *      can turn any rule on later with {setProgramConfig}. ONE program per pool; the tick range
     *      is fixed here forever (pass `(0,0)` for full range).
     *
     *      FUNDING. `liquidity` is in the pool's own liquidity units. An ERC20 side settles the
     *      EXACT amount the position needs straight from the caller's allowance to this hook; a
     *      native side (always `currency0`) is prepaid with `msg.value` and the unused excess
     *      refunded — the attached value is a hard cap, since the hook's own inventory is pot money
     *      and never funds a position. The body lives in {GlueLiquidity.createProgram}.
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
    ) external payable guarded returns (uint256 amount0, uint256 amount1) {
        bytes32 id = _idOf(key);
        return GlueLiquidity.createProgram(
            _pots[id], _programs[id], POOL_MANAGER, id, key, tickLower, tickUpper, liquidity, owner,
            // Everything off: no shares (the buyback split included — the pot's output keeps
            // following the pot's own recipient, where `address(0)` means burn), both recipients
            // the owner, auto-harvest disarmed
            ProgramConfig({
                buybackShareWad: 0,
                burnShareWad: 0,
                compoundShareWad: 0,
                potCompoundShareWad: 0,
                potBurnShareWad: 0,
                publicHarvest: false,
                secondaryRecipient: owner,
                mainRecipient: owner,
                minMain: type(uint256).max,
                minSecondary: type(uint256).max
            })
        );
    }

    /**
     * @notice Create the pool's LP program with FULL RULES at creation and seed its liquidity.
     *         Pot-admin only.
     * @dev Same mechanics as {addLiquidity} plus the split config, validated here. The owner is
     *      also the first operator. `owner == address(0)` ships the program fully surrendered from
     *      birth: rules nobody can ever edit, liquidity nobody can ever pull, manual harvest forced
     *      public. For frozen rules WITHOUT giving up the pool, name a live owner and zero the
     *      operator afterwards ({setProgramOperator}). The body lives in
     *      {GlueLiquidity.createProgram}.
     * @param key The pool key (pot must be configured).
     * @param tickLower Lower tick, `(0,0)` = full range.
     * @param tickUpper Upper tick.
     * @param liquidity Liquidity units to mint.
     * @param owner The program's owner and first operator (`address(0)` = surrendered at birth).
     * @param config The split rules (see {IGlueHook.ProgramConfig}).
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
    ) external payable guarded returns (uint256 amount0, uint256 amount1) {
        bytes32 id = _idOf(key);
        return GlueLiquidity.createProgram(
            _pots[id], _programs[id], POOL_MANAGER, id, key, tickLower, tickUpper, liquidity, owner, config
        );
    }

    /**
     * @notice Add liquidity to an existing program. Owner only.
     * @dev Pending fees are harvested FIRST — through the program's own split — so the add settles
     *      pure principal. Same funding mechanics as {addLiquidity}; the tick range is the
     *      program's own. The mint lives in {GlueLiquidity.mintLiquidity}.
     * @param key The pool key.
     * @param liquidity Liquidity units to mint.
     * @return amount0 Currency0 the position consumed.
     * @return amount1 Currency1 the position consumed.
     */
    function addProgramLiquidity(IPoolManagerMin.PoolKey calldata key, uint128 liquidity)
        external payable guarded returns (uint256 amount0, uint256 amount1)
    {
        bytes32 id = _idOf(key);
        Program storage g = _ownedProgram(id);

        // Harvest first, so the add settles pure principal and the fees route through the split
        _harvestInto(id, key);
        return GlueLiquidity.mintLiquidity(g, POOL_MANAGER, id, key, liquidity);
    }

    /**
     * @notice Remove liquidity from the program and send the principal to `to`. Owner only — a
     *         live owner can ALWAYS withdraw; an ownerless program's liquidity is locked forever.
     * @dev Pending fees are harvested FIRST through the split, so the removal delta is pure
     *      principal. Never lockable: the property always has a live holder or nobody at all.
     * @param key The pool key.
     * @param liquidity Liquidity units to remove.
     * @param to Receives both principal legs.
     * @return amount0 Currency0 principal returned.
     * @return amount1 Currency1 principal returned.
     */
    function removeProgramLiquidity(IPoolManagerMin.PoolKey calldata key, uint128 liquidity, address to)
        external guarded returns (uint256 amount0, uint256 amount1)
    {
        bytes32 id = _idOf(key);
        // Owner-gated and NEVER lockable: the property always has a live holder
        Program storage g = _ownedProgram(id);
        if (liquidity == 0 || liquidity > g.liquidity || to == address(0)) revert BadConfig();

        // Harvest first, so the removal delta is pure principal and the fees route through the split
        _harvestInto(id, key);

        // Book before moving: nothing re-entered can see the liquidity twice
        g.liquidity -= liquidity;
        GluedV4Core.RemoveLiquidityResult memory res =
            _removeLiquidityV4(key, liquidity, address(this), to, g.tickLower, g.tickUpper);
        emit ProgramLiquidityRemoved(id, liquidity, res.ethReceived, res.tokenReceived, to);
        return (res.ethReceived, res.tokenReceived);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // LP PROGRAM — RULES
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Replace the program's split rules. Operator only (impossible once the operator role
     *         was set to `address(0)`).
     * @dev Validated like the advanced entry ({GlueLiquidity.applyConfig}): each side's shares sum
     *      to at most 100% and a live recipient stands behind every leg that can carry value. An
     *      edit only shapes FUTURE harvests — nothing already split or carried is re-touched, and
     *      the standing compound carry keeps retrying under the new rules.
     * @param poolId The pool identifier.
     * @param config The new split rules.
     */
    function setProgramConfig(bytes32 poolId, ProgramConfig calldata config) external {
        Program storage g = _programs[poolId];
        if (!g.exists) revert PotNotReady();
        // The OPERATOR edits the rules; a zeroed operator role means frozen forever, since
        // `msg.sender` is never zero
        if (msg.sender != g.operator) revert NotAllowed();
        GlueLiquidity.applyConfig(g, config);
        emit ProgramConfigured(poolId, config);
    }

    /**
     * @notice Move the operator role — the settings editor. Operator only.
     * @dev `address(0)` freezes the split rules FOREVER without touching the owner's property: the
     *      owner keeps adding, removing and harvesting under rules nobody can ever change. This is
     *      the immutable-rules promise; there is deliberately no way back, and deliberately no
     *      liquidity lock attached to it. The body lives in {GlueLiquidity.setOperator}.
     * @param poolId The pool identifier.
     * @param newOperator The new settings editor (`address(0)` = frozen forever).
     */
    function setProgramOperator(bytes32 poolId, address newOperator) external {
        GlueLiquidity.setOperator(_programs[poolId], poolId, newOperator);
    }

    /**
     * @notice Transfer the program's ownership — the property itself. Owner only.
     * @dev The new owner takes the liquidity rights (add/remove/harvest); the operator role does
     *      NOT travel with it. `address(0)` surrenders the property: the liquidity locks forever
     *      and the manual harvest is forced public so an ownerless program never strands its fees.
     *      Richer custody policy — timelocks, vesting, DAO control — is built ON TOP by
     *      transferring ownership to a contract that implements it (a locker simply becomes the
     *      owner). The body lives in {GlueLiquidity.transferOwnership}.
     * @param poolId The pool identifier.
     * @param newOwner The new property holder (`address(0)` = liquidity locked forever).
     */
    function transferProgramOwnership(bytes32 poolId, address newOwner) external {
        GlueLiquidity.transferOwnership(_programs[poolId], poolId, newOwner);
    }

    /// @dev The pool's program, gated to its live owner (the property holder).
    function _ownedProgram(bytes32 poolId) private view returns (Program storage g) {
        g = _programs[poolId];
        if (!g.exists) revert PotNotReady();
        if (msg.sender != g.owner) revert NotAllowed();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // LP PROGRAM — HARVEST & PAYOUTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Collect the program's accrued LP fees and run the split. Owner-only unless the
     *         config's `publicHarvest` opens it to anyone.
     * @dev The SAME path the auto-harvest runs — every share off the gross of its side: buyback to
     *      the pot, burn through the cascade, the compound budget (slice + carry) into the
     *      position, remainders pushed to the recipients (refusals booked for {claim} or the next
     *      push) — so the rules apply whether or not the auto-trigger is armed. Runs with the
     *      caller's full gas, which also makes it the natural path for heavy tokens. The
     *      auto-harvest stays inherently public whatever this gate says: any swap that meets the
     *      mins triggers it.
     * @param key The pool key.
     * @return mainFees Fees collected on the main side.
     * @return secondaryFees Fees collected on the secondary side.
     */
    function harvest(IPoolManagerMin.PoolKey calldata key)
        external guarded returns (uint256 mainFees, uint256 secondaryFees)
    {
        bytes32 id = _idOf(key);
        Program storage g = _programs[id];
        // Nothing staked: nothing to collect
        if (g.liquidity == 0) revert PotNotReady();
        // Owner-only unless the config opened it to anyone
        if (!g.publicHarvest && msg.sender != g.owner) revert NotAllowed();
        return _harvestInto(id, key);
    }

    /**
     * @notice Pull everything booked to the caller in `asset`. Full-gas, reverting delivery.
     * @dev The claimer chose to be here, so a refusal reverts and leaves the book intact — unlike
     *      the harvest's pushes, which never revert and book refusals here.
     * @param asset The asset to claim.
     * @return amount The amount delivered.
     */
    function claim(address asset) external guarded returns (uint256 amount) {
        amount = _ledgers.owed[msg.sender][asset];
        if (amount == 0) revert PotNotReady();

        // Book first; the send below reverts on failure and undoes it
        delete _ledgers.owed[msg.sender][asset];
        _ledgers.owedTotal[asset] -= amount;
        // Full-gas, reverting delivery: the claimer chose to be here
        _sendToken(asset, msg.sender, amount);
        emit Claimed(msg.sender, asset, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice A pool's pot.
    /// @param poolId The pool identifier.
    /// @return pot The full pot record.
    function potOf(bytes32 poolId) external view returns (Pot memory pot) {
        return _pots[poolId];
    }

    /// @notice A pool's LP program.
    /// @param poolId The pool identifier.
    /// @return program The full program record.
    function programOf(bytes32 poolId) external view returns (Program memory program) {
        return _programs[poolId];
    }

    /// @notice Harvest legs booked to `to` in `asset` after refused pushes, claimable via {claim}.
    /// @param to The recipient.
    /// @param asset The asset.
    /// @return amount The claimable backlog.
    function owedOf(address to, address asset) external view returns (uint256 amount) {
        return _ledgers.owed[to][asset];
    }

    /// @notice Cumulative harvest legs DELIVERED to a native program's engine in `asset`.
    /// @dev Monotonic. The engine attributes from `recordHarvest` and reconciles any failed
    ///      callback by diffing this against its own cursor — the exactly-once source of truth.
    ///      Zero for every non-native program.
    /// @param poolId The pool identifier.
    /// @param asset The pool currency (`address(0)` = native).
    /// @return amount The cumulative delivered total.
    function deliveredCumOf(bytes32 poolId, address asset) external view returns (uint256 amount) {
        return _ledgers.deliveredCum[poolId][asset];
    }

    /// @notice Main that a live recipient refused and that therefore sits on the hook, retryable
    ///         through {flushDirect}.
    /// @param asset The main currency.
    /// @return amount Parked amount, summed across pools.
    function parkedOf(address asset) external view returns (uint256 amount) {
        return _ledgers.parked[asset];
    }

    /// @notice Burn-intent main whose Glue unglue refused, held here FOREVER.
    /// @dev The hook's terminal sink: there is no withdrawal path, so custody IS the burn — the
    ///      amount is out of circulation as surely as a `0xdead` balance. Once an asset lands here
    ///      it is flagged unburnable and the unglue is never attempted again.
    /// @param asset The main currency.
    /// @return amount Held amount.
    function heldOf(address asset) external view returns (uint256 amount) {
        return _ledgers.held[asset];
    }

    /// @notice The subset of {parkedOf} (in the pool's main) that a live recipient refused and that
    ///         is retryable through {flushDirect}.
    /// @param poolId The pool identifier.
    /// @return amount Parked refused-delivery amount.
    function parkedDirectOf(bytes32 poolId) external view returns (uint256 amount) {
        return _ledgers.parkedDirect[poolId];
    }

    /// @notice Everything the hook owes on an asset: every pot holding it, anything parked or held
    ///         in it, every harvest leg booked in it for a recipient, and every program's compound
    ///         carry denominated in it.
    /// @dev The hook's balance of `asset` is always at least this — every unit it holds is
    ///      attributed. There is no withdrawal path for any term.
    /// @param asset The asset to account.
    /// @return amount Total obligation.
    function obligationOf(address asset) external view returns (uint256 amount) {
        Ledgers storage L = _ledgers;
        return L.potTotal[asset] + L.parked[asset] + L.held[asset] + L.owedTotal[asset] + L.carryTotal[asset];
    }

    /**
     * @notice Preview the pump a swap moving this much secondary would trigger right now.
     * @dev Mirrors the live `afterSwap` sizing ({_pumpSize}) at the current spot: the fee ceiling
     *      `f·R`, the spend bucket as it has refilled to this block, the reference-gated share of
     *      the demand (the reference projected to this block), the haircut, and the pool-exact
     *      output floor.
     * @param key The pool key.
     * @param demand The secondary the carrying swap moves — paid on a buy of main, received on a
     *        sell of main.
     * @return spend Secondary the pot would spend.
     * @return minOut The output floor the pump would enforce on itself.
     */
    function quotePump(IPoolManagerMin.PoolKey calldata key, uint256 demand)
        external view returns (uint256 spend, uint256 minOut)
    {
        bytes32 id = _idOf(key);
        Pot storage p = _pots[id];
        // Mirror the live gate: an unconfigured or empty pot buys nothing
        if (!p.configured || p.balance == 0) return (0, 0);
        (int32 refX8, ) = _projectReference(p, p.main == key.currency0);
        (spend, minOut, , ) = _pumpSize(key, id, p, GluedV4Core.getSlot0(POOL_MANAGER, id), demand, refX8);
    }

    /**
     * @notice The reference gate as it stands right now: the share of a swap's secondary the pump
     *         may match, the live tick and the reference tick it is measured against.
     * @dev The reference is projected to this block exactly as {_observe} would advance it, so the
     *      share is the one a swap in this block would be sized with. The fee is the pool's live
     *      composed fee in the pump's own direction.
     * @param poolId The pool identifier.
     * @return shareWad The demand share (1e18 = 100%).
     * @return spotTick The pool's live tick.
     * @return referenceTick The reference tick, floored to a whole tick.
     */
    function pumpShareOf(bytes32 poolId)
        external view returns (uint256 shareWad, int24 spotTick, int24 referenceTick)
    {
        Pot storage p = _pots[poolId];
        // No roles, no gate
        if (!p.configured) return (0, 0, 0);
        GluedV4Core.Slot0 memory slot0 = GluedV4Core.getSlot0(POOL_MANAGER, poolId);
        // Main is currency0 exactly when it is the lower address (V4 sorts a key's currencies);
        // the pump sells secondary, so it swaps zeroForOne exactly when main is currency1
        bool mainIsZero = p.main < p.secondary;
        (int32 refX8, ) = _projectReference(p, mainIsZero);
        uint24 fee = GluedV4Core.swapFee(slot0.protocolFee, slot0.lpFee, !mainIsZero);
        shareWad = _pumpShare(slot0.tick, refX8, fee, mainIsZero);
        spotTick = slot0.tick;
        referenceTick = int24(refX8 >> 8);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL — LP PROGRAM
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @dev The auto-harvest trigger, run on every swap of a configured pool. FREE when idle: the
     *      program's first slot gates everything — no program, nothing staked, or a program whose
     *      config leaves both mins at `type(uint256).max` (the plain {addLiquidity} default) costs
     *      the swap that one read and never runs the pending-fee scan. Armed, the scan runs and the
     *      harvest fires when either side's pending fees reach its min, through the
     *      {executeHarvest} self-call so a failure skips the harvest silently rather than
     *      reverting the carrying swap: the merged collect + compound first, the collect-only path
     *      as its fallback.
     * @param id The pool identifier.
     * @param key The pool key.
     * @param mainIsZero True when the pot's main is `currency0`.
     * @return burnLeg Main-side slice for the burn cascade (placed by the caller).
     * @return mainLeg Main-side slice for the program's main recipient (placed by the caller).
     * @return secLeg Secondary-side slice for the program's secondary recipient (placed by the caller).
     */
    function _autoHarvest(bytes32 id, IPoolManagerMin.PoolKey calldata key, bool mainIsZero)
        private returns (uint256 burnLeg, uint256 mainLeg, uint256 secLeg)
    {
        Program storage g = _programs[id];
        // No program, nothing staked, or both mins disarmed: nothing to scan (one slot read)
        if (g.liquidity == 0 || !g.armed) return (0, 0, 0);

        (uint256 f0, uint256 f1) = GluedV4Core.getPendingV4Fees(
            POOL_MANAGER, id, address(this), g.tickLower, g.tickUpper, GluedV4Core.positionSalt(address(this))
        );
        (uint256 fMain, uint256 fSec) = mainIsZero ? (f0, f1) : (f1, f0);
        // Nothing pending, or neither side has reached its armed min
        if ((fMain | fSec) == 0) return (0, 0, 0);
        if (fMain < g.minMain && fSec < g.minSecondary) return (0, 0, 0);

        // Self-call: a revert in here skips the harvest alone, never the carrying swap. The merged
        // mint goes first; should its guard trip (a 1-wei round-up edge, a fee mismatch), the
        // collect-only path lands the harvest and carries the compound budget instead.
        try this.executeHarvest(id, key, f0, f1, true) returns (uint256 b, uint256 m, uint256 s) {
            return (b, m, s);
        } catch {
            try this.executeHarvest(id, key, f0, f1, false) returns (uint256 b, uint256 m, uint256 s) {
                return (b, m, s);
            } catch {}
        }
    }

    /**
     * @dev The outside-unlock harvest: scan the pending fees, run the merged collect + compound
     *      through the hook's own HARVEST unlock (collect-only as its fallback), split, place. The
     *      shared body of the public {harvest} and the harvest-first rule of the liquidity ops. A
     *      program with nothing staked is a silent no-op so the liquidity ops can call it blindly.
     * @param id The pool identifier.
     * @param key The pool key.
     * @return fMain Fees collected on the main side.
     * @return fSec Fees collected on the secondary side.
     */
    function _harvestInto(bytes32 id, IPoolManagerMin.PoolKey calldata key)
        private returns (uint256 fMain, uint256 fSec)
    {
        Program storage g = _programs[id];
        if (g.liquidity == 0) return (0, 0);

        // With a compound share or a standing carry there may be something to mint: scan the
        // pending fees first, so the mint can be sized and run in the same call that collects
        // them (we are NOT inside a swap here: the hook's own HARVEST unlock). Otherwise the
        // plain collect is the whole touch and the scan is skipped.
        uint256 f0;
        uint256 f1;
        bool mint = g.compoundShareWad != 0 || (g.carryMain | g.carrySecondary) != 0;
        if (mint) {
            (f0, f1) = GluedV4Core.getPendingV4Fees(
                POOL_MANAGER, id, address(this), g.tickLower, g.tickUpper, GluedV4Core.positionSalt(address(this))
            );
        }
        Pot storage p = _pots[id];
        uint256 burnLeg;
        uint256 mainLeg;
        uint256 secLeg;
        (fMain, fSec, burnLeg, mainLeg, secLeg) =
            GlueLiquidity.harvest(p, g, _ledgers, POOL_MANAGER, id, key, f0, f1, false, mint);

        // Placement: the SAME send phase as the in-swap frame, with no pot output to place
        GlueLiquidity.place(p, g, _ledgers, id, burnLeg, mainLeg, secLeg, 0);
    }

    /// @notice The hook's own unlock op on top of {GluedV4Callback}'s: the merged HARVEST
    ///         (collect + compound mint in one `modifyLiquidity`) for the manual path.
    /// @dev Reached only from the PoolManager's callback (the base already gated `msg.sender`),
    ///      and only for the op the hook itself encoded in {GlueLiquidity-harvest}.
    function _handleExtension(uint8 opType, bytes memory params) internal override returns (bytes memory) {
        if (opType != OP_HARVEST) revert NotAllowed();
        return GlueLiquidity.harvestCallback(POOL_MANAGER, params);
    }

    /// @dev The transient PAYER slot: `keccak256("GlueHook.payer")` (a literal because inline
    ///      assembly only accepts direct number constants). Set by the library's mint around its
    ///      unlock — the literal there MUST match this one.
    bytes32 private constant PAYER_SLOT = 0x1bde310958327eb1c8a9046a2bb97d1e21ae8a0e23960bbeb793bdf7f87b6f8b;

    /// @dev Read the transient payer.
    function _getPayer() private view returns (address payer) {
        assembly ("memory-safe") { payer := tload(PAYER_SLOT) }
    }

    /// @dev The canonical V4 pool identifier: `keccak256(abi.encode(key))`, shared by every entry.
    function _idOf(IPoolManagerMin.PoolKey calldata key) private pure returns (bytes32 id) {
        return keccak256(abi.encode(key));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL — PRICING
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @dev The secondary a swap moved, read off its delta rather than quoted — the yardstick the
     *      pump's demand ceiling is a share of. On a buy of main it is what the swapper PAID (the
     *      secondary leg a debit, the main leg a credit); on a sell of main it is what they
     *      RECEIVED (the mirror). A delta that does not have the direction's shape — which a
     *      hook-less pool cannot produce, but a zero-output dust swap can — sizes nothing.
     *
     *      A measured quantity, deliberately: converting the swap's main leg into secondary would
     *      need a quote, and a quote of a pot-sized swap divides by an average execution price
     *      rather than the marginal one — which reads a fat pot's own price impact as extra demand
     *      and would let the pump outrun the swap that triggered it by exactly that factor.
     * @param delta The swapper's balance delta.
     * @param mainIsZero True when main is `currency0`.
     * @param buy True when the swap bought main (secondary → main).
     * @return demand Secondary paid (buy) or received (sell); zero when the delta has another shape.
     */
    function _demandOf(int256 delta, bool mainIsZero, bool buy) private pure returns (uint256 demand) {
        (int128 d0, int128 d1) = _unpackDelta(delta);
        (int128 mainDelta, int128 secondaryDelta) = mainIsZero ? (d0, d1) : (d1, d0);
        if (buy) {
            // They really did receive main, and really did pay secondary for it
            if (mainDelta > 0 && secondaryDelta < 0) demand = uint256(-int256(secondaryDelta));
        } else {
            // They really did hand over main, and really were paid secondary for it
            if (mainDelta < 0 && secondaryDelta > 0) demand = uint256(int256(secondaryDelta));
        }
    }

    /**
     * @dev Size the pump and derive its own output floor.
     *
     *      FOUR ceilings, and the pump takes the smallest.
     *
     *      1. THE FEE CEILING — what makes the pump unsandwichable. A pump is a market buy somebody
     *      else's transaction triggers, which is exactly the shape of a victim in a sandwich: buy in
     *      front of it, let it push the price up, sell behind it. Run that on a constant-product pool
     *      of depth `R` with an attacker leg `X` and a pump of `V`, and the gross profit is exactly
     *      `R·u·v·(2+u+v)/((1+u)² + u·v)` for `u = X/R`, `v = V/R` — that is `2·X·V/R` at leading
     *      order. The attacker's fees are `f·X` on the way in and `f·X`-worth on the way out, so the
     *      attack pays if and only if `2·X·V/R > 2·f·X`, i.e. `V > f·R`. The attacker's own size
     *      cancels out entirely: one bound on the pump's spend closes the attack for every attacker
     *      size, pot depth and price at once. `R` is the pool's tangent depth at its live price
     *      ({GluedV4Core-tangentReserve}) and `f` its live composed fee, so a deeper pool or a fatter
     *      fee tier earns a proportionally larger pump and nothing is hardcoded.
     *
     *      2. THE SPEND BUCKET — what paces the pot to what the pool EARNS. The fee ceiling bounds
     *      ONE pump; it says nothing about a thousand of them in a block. A holder of a large bag
     *      could otherwise manufacture volume at or below the reference (cheap round trips, each
     *      summoning a pump) and compress the pot's whole spend into a moment they alone are
     *      positioned for. The bucket holds at most one fee ceiling and refills from TWO sources:
     *      every funded swap credits it `PUMP_FEE_LEVERAGE × the fee it paid` (`k·f·demand`), and
     *      time credits it one ceiling per {PUMP_REFILL} as a slow floor. A pump spends at most the
     *      bucket's level; the spend moves the level down by what it used. So over any window the
     *      pot spends at most `k × the LP fees earned + f·R × window / PUMP_REFILL`: a hot market is
     *      bought hard, a dead one barely, a single sell of `depth / k` fills the bucket by itself,
     *      and manufactured volume unlocks only `k ×` what it cost — a farmer's bag must exceed
     *      `depth / 2k` of the pool before the round trips pay, held the whole time and lifted no
     *      more than every other holder. Encoded in ONE timestamp packed with `main` (the level is
     *      the time it would have taken to refill; a credit moves the timestamp back, a spend moves
     *      it forward; a fresh pot reads as full).
     *
     *      3. THE DEMAND CEILING — gradualism: the pump never spends more than a SHARE of the
     *      secondary the carrying swap just moved (paid on a buy, received on a sell), so a dust
     *      trade unlocks a dust pump and the pot is spent in step with real flow instead of all at
     *      once.
     *
     *      4. THE REFERENCE GATE — what makes the demand ceiling unfarmable, by setting that share.
     *      A trader who pushes spot a premium `d` above the reference and then trades summons a pump
     *      at the inflated price and can sell into it; pushing costs `2·f` per unit pushed and the
     *      pump hands back at most `d` per unit of pump. Both legs of the round trip — the push and
     *      the dump — present demand at the premium, so with a share `s` of each the pumps hand back
     *      `2·s·d` per unit and the round trip pays only if `2·s·d > 2·f`. {_pumpShare} therefore
     *      returns `min(60%, f/d)`: break-even at best before the haircut, a loss after it, and the
     *      full share whenever spot is at or below the reference — where there is no premium to
     *      sell into.
     *
     *      {PUMP_HAIRCUT_BPS} then applies to whichever ceiling won, which puts the spend strictly
     *      inside both break-evens rather than exactly on them.
     *
     *      The output floor is quoted with the pool-exact step quoter, which never over-states, so a real
     *      swap cannot trip a floor the pool itself produced.
     * @param key The pool key.
     * @param id The pool identifier.
     * @param p The pool's pot (its balance, main, bucket and reference are read).
     * @param slot0 The pool's live slot0 — the state the swapper's trade left behind.
     * @param demand Secondary the carrying swap moved.
     * @return spend Secondary to spend on the pump.
     * @return minOut Output floor for the pump's own swap.
     * @return bucketCredited The bucket timestamp after this swap's volume credit, before any spend
     *         — what to store when the pump does not run or reverts.
     * @return bucketAfter The bucket timestamp after the credit AND this spend — what to store once
     *         the pump has gone through.
     */
    function _pumpSize(
        IPoolManagerMin.PoolKey calldata key,
        bytes32 id,
        Pot storage p,
        GluedV4Core.Slot0 memory slot0,
        uint256 demand,
        int32 refX8
    ) private view returns (uint256 spend, uint256 minOut, uint32 bucketCredited, uint32 bucketAfter) {
        return GlueLiquidity.pumpSize(POOL_MANAGER, key, id, p, slot0, demand, refX8);
    }

    /**
     * @dev The reference gate's share: the fraction of the carrying swap's secondary the pump may
     *      match at this spot.
     *
     *      `d` is MAIN's premium over the reference, `1.0001^Δ − 1` for the tick gap `Δ` oriented
     *      so that a positive gap is a dearer main: a V4 tick is the log-price of currency0 in
     *      currency1, so the gap is `spot − ref` when main is currency0 (main's price rises with
     *      the tick) and `ref − spot` when main is currency1 (its reciprocal). The reference is rounded to
     *      the whole tick on the side that makes the gap read a hair LARGER — the strict side. At
     *      or below the reference the share is {PUMP_SHARE_MAX_WAD}; above it, `f / d` capped
     *      there — the level at which pushing main up by `d` to farm the pump costs exactly what
     *      the pump can hand back, see {_pumpSize}. Pure and bounded: the gap is clamped to the
     *      tick range, so nothing in here can revert.
     * @param spotTick The pool's live tick.
     * @param refX8 The reference tick in 1/256ths.
     * @param fee The pool's live composed fee in millionths, in the pump's direction.
     * @param mainIsZero True when main is `currency0`.
     * @return shareWad The share (1e18 = 100%).
     */
    function _pumpShare(int24 spotTick, int32 refX8, uint24 fee, bool mainIsZero)
        private pure returns (uint256 shareWad)
    {
        return GlueLiquidity.pumpShare(spotTick, refX8, fee, mainIsZero);
    }

    /**
     * @dev The reference tick as it stands NOW: the stored value advanced by the observation this
     *      block would make. An observation moves the reference `min(1, dt / REFERENCE_TAU)` of the
     *      way from where it is to the tick that stood since the last one — `lastTick`, the tick the
     *      PREVIOUS swap left, never the current one — so a swap in the same block as the last
     *      (`dt == 0`) moves nothing, and nothing done to spot inside a block enters the reference.
     *      Wrapping, bounded integer arithmetic throughout: the step is a convex combination of two
     *      in-range ticks, so the result always fits its slot and the division is by a constant.
     * @param p The pool's pot.
     * @return refX8 The projected reference in 1/256ths of a tick.
     * @return dt Seconds since the last observation (zero when this block already observed).
     */
    function _projectReference(Pot storage p, bool mainIsZero)
        private view returns (int32 refX8, uint32 dt)
    {
        unchecked {
            dt = uint32(block.timestamp) - p.lastTimestamp;
            int256 ref = int256(p.referenceTickX8);
            if (dt != 0) {
                uint256 step = dt > REFERENCE_TAU ? REFERENCE_TAU : dt;
                int256 move =
                    ((int256(p.lastTick) << 8) - ref) * int256(step) / int256(uint256(REFERENCE_TAU));
                // The rise cap: main may not get dearer in the reference faster than
                // REFERENCE_MAX_RISE_PER_MINUTE, whatever stood. A dearer main is a HIGHER tick when
                // main is currency0 and a LOWER one when it is currency1. Falls are never capped.
                int256 maxRise =
                    int256(uint256(REFERENCE_MAX_RISE_PER_MINUTE) << 8) * int256(uint256(dt)) / 60;
                if (mainIsZero) {
                    if (move > maxRise) move = maxRise;
                } else {
                    if (move < -maxRise) move = -maxRise;
                }
                ref += move;
            }
            refX8 = int32(ref);
        }
    }

    /// @dev Record an observation behind a swap: advance the reference with the tick that stood
    ///      since the last swap ({_projectReference}), then note the tick this swap left as the one
    ///      standing from now on. A same-block swap only refreshes the standing tick, so within a
    ///      block the LAST swap's tick is the one that will count — holding a price across the block
    ///      boundary, against the whole market, is the only way into the reference.
    /// @param p The pool's pot.
    /// @param spotTick The pool's tick after the swap.
    /// @param mainIsZero True when main is `currency0` (orients the rise cap).
    function _observe(Pot storage p, int24 spotTick, bool mainIsZero) private {
        (int32 refX8, uint32 dt) = _projectReference(p, mainIsZero);
        if (dt != 0) {
            p.referenceTickX8 = refX8;
            p.lastTimestamp = uint32(block.timestamp);
            p.lastTick = spotTick;
        } else if (p.lastTick != spotTick) {
            p.lastTick = spotTick;
        }
    }

    /// @dev Start the reference from the pool's live tick: at {initPot}, and whenever a donation
    ///      funds an empty pot (an empty pot observes nothing, so whatever it last saw is stale).
    /// @param p The pool's pot.
    /// @param id The pool identifier.
    function _seedReference(Pot storage p, bytes32 id) private {
        int24 tick = GluedV4Core.getSlot0(POOL_MANAGER, id).tick;
        p.referenceTickX8 = int32(tick) << 8;
        p.lastTick = tick;
        p.lastTimestamp = uint32(block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL — EXECUTION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Reverting send of the native currency or an ERC20 — the strict outgoing primitive for the
    ///      caller's own transaction (claims, refunds, liquidity principal).
    function _sendToken(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (token == ETH_ADDRESS) {
            // A self-send is a no-op: the value is already here
            if (to == address(this)) return;
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Measured pull of the native currency (validated against `msg.value`) or an ERC20 (returns
    ///      the recipient's real balance delta, so a fee-on-transfer currency credits what ARRIVED).
    function _pullToken(address token, address from, address to, uint256 amount)
        private returns (uint256 actualAmount)
    {
        if (amount == 0) return 0;
        if (token == ETH_ADDRESS) {
            // The caller must have attached the value; it already sits on this contract
            if (msg.value < amount) revert BadDonation();
            if (to != address(this)) Address.sendValue(payable(to), amount);
            return amount;
        }
        uint256 balanceBefore = IERC20(token).balanceOf(to);
        IERC20(token).safeTransferFrom(from, to, amount);
        uint256 balanceAfter = IERC20(token).balanceOf(to);
        return balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
    }

    /// @notice How the V4 callback frame ({GluedV4Callback}) moves an ERC20 into the PoolManager.
    /// @dev While the transient PAYER is set — only ever inside a liquidity add's unlock — the leg
    ///      is pulled straight from the payer's allowance at the exact amount owed, so a position is
    ///      always funded by its caller and never by the hook's own inventory. With no payer set it
    ///      is a plain reverting send from the hook's own balance (the pump's settle path).
    function _transferToken(address token, address to, uint256 amount) internal override {
        address payer = _getPayer();
        if (payer != address(0)) {
            _pullToken(token, payer, to, amount);
            return;
        }
        _sendToken(token, to, amount);
    }
}
