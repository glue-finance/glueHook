// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {GlueHookFixture} from "./helpers/GlueHookFixture.sol";
import {IGlueHook} from "../contracts/interfaces/IGlueHook.sol";
import {GluedV4Core, IPoolManagerMin} from "../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title  GlueHookMev — the pump's MEV surface, attacked.
 * @notice The pump is a market buy that somebody else's swap triggers, in either direction. Four
 *         ceilings size it: the fee ceiling `f·R`; the spend bucket, which holds at most one fee
 *         ceiling and is credited `k·f·B` by every funded swap of demand `B` plus one ceiling per
 *         PUMP_REFILL of time; the demand ceiling `s·B`; and the reference gate that sets
 *         `s = min(60%, f/d)` from main's premium `d` over a reference tick that follows the market
 *         with a time constant τ and may rise at most 296 ticks (≈3%) a minute. This suite runs the
 *         attacks those ceilings exist for and pins down the mechanics they rest on:
 *
 *           M1  manipulate–dump–unwind loses at every push size, and the pot gives up a sliver
 *           M2  a pre-positioned bag farmed with round trips inside the block loses
 *           M3  the reference: seeded at init, deaf inside a block, linear in standing time on a
 *               fall, re-seeded when a donation funds an empty pot, asleep while the pot is empty
 *           M4  the gate's share table: `min(60%, f/d)` at every premium, to the tick
 *           M5  a dip gets the full share whatever the history
 *           M6  the pace bound on a PATIENT bag holder at the reference: the pot spends no more than
 *               `k ×` the fees the farm paid plus the time floor, a bag under `depth/(1.6k)` loses,
 *               and a bag above it gains strictly less than the pot spent
 *           M7  the bucket: bounded inside a block by the ceiling plus the credits, linear time
 *               refill, `k·f·volume + floor` over time, a single sell of `depth/k` fills it, a dust
 *               pump leaves it nearly full, and the quote mirrors it credit included
 *           M8  revert-freeness: no sequence of trades and time skips, and no pool parked at the
 *               edge of the tick range, can make the hook revert a swap
 *           M9  the reference and the bucket are per pool
 *           M10 the gate reads the premium the right way round when main is currency0
 *           M11 the rise cap: a held +69% opens the gate at 3% a minute, not at τ; a held +300%
 *               takes most of an hour; a fall is never capped
 */
contract GlueHookMev is GlueHookFixture {
    MockERC20 token;
    IPoolManagerMin.PoolKey key;
    bytes32 id;

    uint256 constant HAIRCUT = 8_000; // bps

    function setUp() public {
        _deployCore();
        token = new MockERC20("Main", "MAIN", 18);
        (key, id) = _openEthPool(address(token), address(0));
        token.approve(address(pump), type(uint256).max);
        // A realistic clock: the campaign's seeds and buckets are timestamps
        vm.warp(1_800_000_000);
    }

    // ── helpers ────────────────────────────────────────────────────────────────────

    /// @dev The pool's tangent depth on the ETH side, at the live price.
    function _depth() internal view returns (uint256) {
        GluedV4Core.Slot0 memory s = GluedV4Core.getSlot0(POOL_MANAGER, id);
        return GluedV4Core.tangentReserve(
            s.sqrtPriceX96, GluedV4Core.getPoolLiquidity(POOL_MANAGER, id), true
        );
    }

    /// @dev The pool's fee ceiling `f·R` on the ETH side, at the live price.
    function _feeCap() internal view returns (uint256) {
        return (_depth() * FEE) / 1e6;
    }

    /// @dev The bucket credit a swap moving `demand` ETH earns: `k·f·demand`.
    function _credit(uint256 demand) internal view returns (uint256) {
        return (pump.PUMP_FEE_LEVERAGE() * FEE * demand) / 1e6;
    }

    /// @dev Main's premium over the reference in WAD, from the gate's own ticks (main is currency1
    ///      here, so a dearer main is a LOWER tick and the gap reads `ref − spot`).
    function _premiumWad() internal view returns (uint256) {
        ( , int24 spot, int24 ref) = pump.pumpShareOf(id);
        // The reference the gate uses is the strict (ceiling) side of the stored 1/256ths
        IGlueHook.Pot memory p = pump.potOf(id);
        int256 refC = int256(p.referenceTickX8) >> 8;
        if (p.referenceTickX8 & 0xFF != 0) ++refC;
        // Projected vs stored can differ; use the view's whole tick plus the strict rounding
        int256 gap = int256(ref) - int256(spot);
        if (refC > int256(ref)) gap += 1;
        if (gap <= 0) return 0;
        uint256 sq = GluedV4Core.getSqrtRatioAtTick(int24(gap));
        uint256 ratioWad = (((sq * sq) / GluedV4Core.Q96) * 1e18) / GluedV4Core.Q96;
        return ratioWad - 1e18;
    }

    /// @dev `f/d` in WAD for a premium `d` in WAD, capped at the maximum share.
    function _gateShare(uint256 premiumWad) internal view returns (uint256 s) {
        if (premiumWad == 0) return pump.PUMP_SHARE_MAX_WAD();
        s = (uint256(FEE) * 1e12 * 1e18) / premiumWad;
        if (s > pump.PUMP_SHARE_MAX_WAD()) s = pump.PUMP_SHARE_MAX_WAD();
    }

    /// @dev A pump behind a swap: its spend and what it bought.
    function _swapPumped(bool zeroForOne, int256 amount) internal returns (uint256 spent, uint256 bought) {
        vm.recordLogs();
        helper.swap(key, zeroForOne, amount);
        ( , spent, bought) = _lastPumped(vm.getRecordedLogs());
    }

    /// @dev Buy a bag of main and let the reference settle on the pushed price (bucket full too).
    function _bagAndSettle(uint256 eth) internal returns (int256 bag) {
        (, bag) = helper.swap(key, true, -int256(eth));
        _settleReference(key);
    }

    /// @dev `trips` round trips of `leg` ETH each: buy, then sell exactly what the buy bought, with
    ///      `gap` seconds (a new block when non-zero) before each trip. Returns the pot's spend.
    function _roundTrips(uint256 trips, uint256 leg, uint256 gap) internal returns (uint256 potSpent) {
        uint256 potBefore = pump.potOf(id).balance;
        for (uint256 i; i < trips; ++i) {
            if (gap != 0) {
                vm.warp(block.timestamp + gap);
                vm.roll(block.number + 1);
            }
            (, int256 got) = helper.swap(key, true, -int256(leg));
            helper.swap(key, false, -got);
        }
        potSpent = potBefore - pump.potOf(id).balance;
    }

    // ── M1 ─────────────────────────────────────────────────────────────────────────

    /// M1 — push spot up, dump into the pumps the dump itself summons, unwind: at EVERY push size
    ///      the round trip is ETH-negative and token-flat, and the pot gives up a sliver. Both
    ///      legs summon pumps at the premium — the push and each slice of the dump — which is why
    ///      the gate is `f/d` and not `2f/d`: the pumps hand back at most `d` per unit and the
    ///      attacker presents `2X` of demand for `2f·X` of fees, so `s = f/d` is the break-even and
    ///      the haircut the loss. Each leg's pump is also inside one haircut ceiling: the pot gives
    ///      up at most four of them, under 1% of itself.
    function test_M1_manipulateDumpUnwindLosesAtEverySize() public {
        _donateEth(key, 100 ether);
        uint256[5] memory pushes = [uint256(0.5 ether), 2 ether, 8 ether, 30 ether, 90 ether];

        for (uint256 i; i < pushes.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 ethBefore = address(helper).balance;
            uint256 tokBefore = token.balanceOf(address(helper));
            uint256 potBefore = pump.potOf(id).balance;
            uint256 feeCap = _feeCap();

            (, int256 gotTok) = helper.swap(key, true, -int256(pushes[i]));
            (uint256 share, int24 spot, int24 ref) = pump.pumpShareOf(id);
            assertLt(spot, ref, "the push put main above the reference");
            uint256 premium = _premiumWad();
            assertGt(premium, 0, "a positive premium");
            assertLe(share, _gateShare(premium) + 1e12, "share <= f/d");

            // Dump in three slices — each summons a pump at the inflated price — then unwind
            int256 slice = gotTok / 3;
            helper.swap(key, false, -slice);
            helper.swap(key, false, -slice);
            helper.swap(key, false, -(gotTok - 2 * slice));

            uint256 potSpent = potBefore - pump.potOf(id).balance;
            assertEq(token.balanceOf(address(helper)), tokBefore, "token-flat");
            assertLt(address(helper).balance, ethBefore, "ETH-negative");
            assertLe(potSpent, (4 * feeCap * HAIRCUT) / 10_000, "at most four haircut ceilings");
            assertLt(potSpent, potBefore / 100, "the pot gave up under 1% of itself");
            emit log_named_uint("push (ETH, 1e18)", pushes[i]);
            emit log_named_uint("  premium over reference (bps)", premium / 1e14);
            emit log_named_uint("  gate share (bps)", share / 1e14);
            emit log_named_uint("  attacker loss (wei)", ethBefore - address(helper).balance);
            emit log_named_uint("  pot spent (wei)", potSpent);
            vm.revertToState(snap);
        }
    }

    // ── M2 ─────────────────────────────────────────────────────────────────────────

    /// M2 — a pre-positioned bag farmed INSIDE the block loses. The attacker buys a 20 ETH bag
    ///      (main +44% over the reference), runs thirty 1 ETH round trips — each leg summons a
    ///      pump — then dumps the bag. Above the reference the gate leaves each pump `f/d` of the
    ///      leg, so the pumps hand the bag back at most `f` per unit of round-trip volume while
    ///      the trips cost `2f`: the farm loses, and every wei the pot lost is a pump the attacker
    ///      paid more than for.
    function test_M2_prePositionedBagFarmInsideBlockLoses() public {
        _donateEth(key, 100 ether);
        uint256 ethBefore = address(helper).balance;
        uint256 tokBefore = token.balanceOf(address(helper));

        (, int256 bag) = helper.swap(key, true, -int256(20 ether));
        uint256 potAfterBag = pump.potOf(id).balance;
        (uint256 share, , ) = pump.pumpShareOf(id);
        uint256 dBag = _premiumWad();
        assertLt(share, 0.01e18, "the bag put the gate under 1%");

        uint256 pumps;
        for (uint256 i; i < 30; ++i) {
            (uint256 s1, ) = _swapPumped(true, -int256(1 ether));
            // Sell exactly what the leg bought so the bag is untouched
            int256 t = int256(token.balanceOf(address(helper))) - int256(tokBefore) - bag;
            (uint256 s2, ) = _swapPumped(false, -t);
            pumps += s1 + s2;
        }
        uint256 potBeforeDump = pump.potOf(id).balance;
        helper.swap(key, false, -bag);

        assertEq(token.balanceOf(address(helper)), tokBefore, "token-flat");
        assertLt(address(helper).balance, ethBefore, "ETH-negative");
        assertEq(potAfterBag - potBeforeDump, pumps, "every wei the pot lost to the farm is a pump");
        // Σ pumps · d ≤ haircut · f · Σ legs (the sell legs sit a hair under the bag's premium, so
        // their share is a hair larger: 10% of slack)
        uint256 legs = 60 ether;
        assertLe((pumps * dBag) / 1e18, (((HAIRCUT * FEE * 1e12) / 10_000) * legs / 1e18) * 11 / 10,
            "the pumps handed back at most the haircut of f per unit of volume");
        emit log_named_uint("attacker loss (wei)", ethBefore - address(helper).balance);
        emit log_named_uint("pot spent across 60 farmed pumps (wei)", pumps);
    }

    // ── M3 ─────────────────────────────────────────────────────────────────────────

    /// M3a — the reference is seeded from the live tick at `initPot`, with the seeding time.
    function test_M3a_referenceSeededAtInit() public view {
        IGlueHook.Pot memory p = pump.potOf(id);
        int24 tick = GluedV4Core.getSlot0(POOL_MANAGER, id).tick;
        assertEq(p.referenceTickX8, int32(tick) << 8, "reference = live tick");
        assertEq(p.lastTick, tick, "standing tick = live tick");
        // Seeded in setUp's block, before the warp
        assertEq(p.lastTimestamp, 1, "seeded when the pot was configured");
        ( , int24 spot, int24 ref) = pump.pumpShareOf(id);
        assertEq(spot, ref, "the gate reads spot at the reference");
    }

    /// M3b — nothing done to spot inside a block enters the reference: two large pushes in the
    ///       seeding block move the standing tick, not the reference.
    function test_M3b_sameBlockPushesNeverMoveReference() public {
        _donateEth(key, 10 ether);
        ( , , int24 ref0) = pump.pumpShareOf(id);

        helper.swap(key, true, -int256(30 ether));
        ( , int24 spot1, int24 ref1) = pump.pumpShareOf(id);
        helper.swap(key, true, -int256(30 ether));
        ( , int24 spot2, int24 ref2) = pump.pumpShareOf(id);

        assertEq(ref1, ref0, "first push: reference untouched");
        assertEq(ref2, ref0, "second push: reference untouched");
        assertLt(spot2, spot1, "while spot ran away (main dearer = lower tick)");
        // The standing tick is the one the LAST swapper's trade left — read before the pump behind
        // it lifted main a little further, so the pot's own buying never enters the reference
        int24 standing = pump.potOf(id).lastTick;
        assertGe(standing, spot2, "standing tick: the swapper's, before the pump's lift");
        assertLt(standing - spot2, 100, "and within the pump's own small move of it");
    }

    /// M3c — on a FALL (never capped) the reference moves `min(1, dt/τ)` of the way to the tick
    ///       that STOOD: half a time constant later it is halfway, a full one later it is there.
    function test_M3c_referenceLinearInStandingTime() public {
        _donateEth(key, 10 ether);
        ( , int24 t0, ) = pump.pumpShareOf(id);
        helper.swap(key, false, -int256(30_000e18)); // main cheaper: a higher tick
        int24 t1 = pump.potOf(id).lastTick; // the tick that will stand (the swapper's, pre-pump)
        assertGt(t1, t0, "spot fell for main");

        // Half a time constant: halfway (the dust trade in the new block is the observation)
        vm.warp(block.timestamp + uint256(pump.REFERENCE_TAU()) / 2);
        vm.roll(block.number + 1);
        helper.swap(key, true, -1);
        ( , , int24 refHalf) = pump.pumpShareOf(id);
        int256 mid = (int256(t0) + int256(t1)) / 2;
        assertApproxEqAbs(int256(refHalf), mid, 1, "halfway after tau/2");

        // A full time constant more: all the way to the standing tick (the dust trade's own)
        int24 standing = pump.potOf(id).lastTick;
        vm.warp(block.timestamp + uint256(pump.REFERENCE_TAU()));
        vm.roll(block.number + 1);
        helper.swap(key, true, -1);
        ( , , int24 refFull) = pump.pumpShareOf(id);
        assertEq(refFull, standing, "converged after tau");
        assertEq(pump.potOf(id).referenceTickX8, int32(standing) << 8, "to the 1/256th");
    }

    /// M3d — an EMPTY pot observes nothing (a pool that only runs a program pays nothing for a
    ///       reference it does not use), and a donation that funds it re-seeds from the live tick.
    function test_M3d_emptyPotAsleepAndReseededOnFunding() public {
        IGlueHook.Pot memory seed = pump.potOf(id);

        // Trades and time with no pot: nothing observed
        helper.swap(key, true, -int256(30 ether));
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        helper.swap(key, true, -int256(10 ether));
        IGlueHook.Pot memory asleep = pump.potOf(id);
        assertEq(asleep.referenceTickX8, seed.referenceTickX8, "reference untouched");
        assertEq(asleep.lastTick, seed.lastTick, "standing tick untouched");
        assertEq(asleep.lastTimestamp, seed.lastTimestamp, "clock untouched");

        // Funding re-seeds at the live tick, so the stale seed cannot mis-gate the first pumps
        _donateEth(key, 1 ether);
        IGlueHook.Pot memory woke = pump.potOf(id);
        int24 live = GluedV4Core.getSlot0(POOL_MANAGER, id).tick;
        assertEq(woke.referenceTickX8, int32(live) << 8, "re-seeded at the live tick");
        assertEq(woke.lastTimestamp, uint32(block.timestamp), "now");
        (uint256 share, , ) = pump.pumpShareOf(id);
        assertEq(share, pump.PUMP_SHARE_MAX_WAD(), "gate wide open at the reference");
    }

    // ── M4 ─────────────────────────────────────────────────────────────────────────

    /// M4 — the share table. With the reference settled at the live price, each push lifts main a
    ///      premium `d`; the gate reads exactly `min(60%, f/d)`, with `d` from whole ticks on the
    ///      strict side.
    function test_M4_shareTable() public {
        _donateEth(key, 100 ether);
        _settleReference(key);
        uint256[7] memory pushes =
            [uint256(0.05 ether), 0.25 ether, 0.5 ether, 1.5 ether, 5 ether, 20 ether, 100 ether];
        bool sawMax; bool sawUnderPct;

        for (uint256 i; i < pushes.length; ++i) {
            uint256 snap = vm.snapshotState();
            helper.swap(key, true, -int256(pushes[i]));
            (uint256 share, , ) = pump.pumpShareOf(id);
            uint256 d = _premiumWad();
            assertApproxEqRel(share, _gateShare(d), 1e14, "share = min(60%, f/d)");
            if (share == pump.PUMP_SHARE_MAX_WAD()) sawMax = true;
            if (share < 0.01e18) sawUnderPct = true;
            emit log_named_uint("premium (bps)", d / 1e14);
            emit log_named_uint("  share (bps)", share / 1e14);
            vm.revertToState(snap);
        }
        assertTrue(sawMax, "small premiums (under 0.5%) keep the full share");
        assertTrue(sawUnderPct, "large premiums fall under 1%");
    }

    // ── M5 ─────────────────────────────────────────────────────────────────────────

    /// M5 — a dip gets the full share whatever came before: after a 20 ETH rally that the
    ///      reference has settled on, a sell that drops main below it summons a pump at the full
    ///      share, sized by the smaller of the fee ceiling and 60% of what the seller received.
    function test_M5_dipsGetFullShareRegardlessOfHistory() public {
        _donateEth(key, 100 ether);
        helper.swap(key, true, -int256(20 ether));
        _settleReference(key);
        (uint256 shareAt, , ) = pump.pumpShareOf(id);
        assertEq(shareAt, pump.PUMP_SHARE_MAX_WAD(), "settled: full share at the reference");

        uint256 feeCap = _feeCap();
        uint256 ethBefore = address(helper).balance;
        (uint256 spent, ) = _swapPumped(false, -int256(2_000e18));
        uint256 received = address(helper).balance - ethBefore;
        (uint256 shareAfter, int24 spot, int24 ref) = pump.pumpShareOf(id);

        assertEq(shareAfter, pump.PUMP_SHARE_MAX_WAD(), "the dip is under the reference: full share");
        assertGt(spot, ref, "main below the reference reads as a higher tick");
        uint256 ceiling = feeCap < (received * 6) / 10 ? feeCap : (received * 6) / 10;
        // The pump is sized at the post-sell depth, ~2% under the pre-sell one measured here
        assertApproxEqRel(spent, (ceiling * HAIRCUT) / 10_000, 0.04e18, "spent 80% of the binding ceiling");
    }

    // ── M6 ─────────────────────────────────────────────────────────────────────────

    /// M6a — THE PACE BOUND. A patient bag holder: buys a bag, lets the reference settle on the
    ///       pushed price (gate wide open — this is what the bucket is for), then farms 1 ETH round
    ///       trips a minute apart for half an hour. The pot spends at most `k·f × the volume the
    ///       farm pushed through` plus the time floor plus the bucket it started with — and the
    ///       farmer's ETH result, whatever the bag, is strictly less than the pot spent: the pot's
    ///       money went into the pool, and every holder was lifted alongside the farmer.
    function test_M6a_patientBagFarmBoundedByPace() public {
        _donateEth(key, 100 ether);
        uint256 ethBefore = address(helper).balance;
        uint256 tokBefore = token.balanceOf(address(helper));
        int256 bag = _bagAndSettle(20 ether);
        uint256 feeCap = _feeCap();

        uint256 trips = 30;
        uint256 potSpent = _roundTrips(trips, 1 ether, 1 minutes);
        helper.swap(key, false, -bag);

        assertEq(token.balanceOf(address(helper)), tokBefore, "token-flat");
        // The pace: k·f per unit of volume, the time floor, plus the full bucket it started with
        uint256 volume = 2 * trips * 1 ether;
        uint256 bound = _credit(volume) + feeCap + (feeCap * trips * 1 minutes) / pump.PUMP_REFILL();
        assertLe(potSpent, (bound * 102) / 100, "the pot spent at most k.f.volume + floor + opening bucket");
        uint256 ethAfter = address(helper).balance;
        if (ethAfter > ethBefore) {
            assertLt(ethAfter - ethBefore, potSpent, "any gain is strictly less than the pot spent");
            emit log_named_uint("patient farmer gain (wei)", ethAfter - ethBefore);
        } else {
            emit log_named_uint("patient farmer loss (wei)", ethBefore - ethAfter);
        }
        emit log_named_uint("pot spent over 30 minutes (wei)", potSpent);
        emit log_named_uint("pace bound (wei)", bound);
    }

    /// M6b — a bag UNDER `depth / (1.6·k)` (≈15.6% of depth at k = 4) loses to the farm even with
    ///       the gate wide open: the pumps its volume unlocks are worth `k·f·volume` to the pot but
    ///       only `2·(bag/depth)` of that to the bag, less than the `2f·volume` the trips cost.
    function test_M6b_bagUnderThresholdLoses() public {
        _donateEth(key, 100 ether);
        uint256 ethBefore = address(helper).balance;
        int256 bag = _bagAndSettle(4 ether); // 4% of depth
        uint256 potSpent = _roundTrips(30, 1 ether, 1 minutes);
        helper.swap(key, false, -bag);

        assertLt(address(helper).balance, ethBefore, "a 4% bag loses to its own farm");
        emit log_named_uint("loss (wei)", ethBefore - address(helper).balance);
        emit log_named_uint("pot spent (wei)", potSpent);
    }

    /// M6c — the documented residual, measured: a bag OVER the threshold (25% of depth) farming at
    ///       the reference gains, but strictly less than the pot spent, and its gain per unit of pot
    ///       spend is at most `2·bag/depth` — what any holder of that size is lifted by.
    function test_M6c_bagOverThresholdGainsLessThanPotSpent() public {
        _donateEth(key, 100 ether);
        uint256 ethBefore = address(helper).balance;
        int256 bag = _bagAndSettle(25 ether);
        uint256 potSpent = _roundTrips(30, 1 ether, 1 minutes);
        helper.swap(key, false, -bag);

        uint256 ethAfter = address(helper).balance;
        if (ethAfter > ethBefore) {
            uint256 gain = ethAfter - ethBefore;
            assertLt(gain, potSpent, "the gain is strictly less than the pot spent");
            assertLe(gain, (potSpent * 2 * 25) / 100, "and at most 2.bag/depth of it");
            emit log_named_uint("over-threshold farmer gain (wei)", gain);
        } else {
            emit log_named_uint("over-threshold farmer loss (wei)", ethBefore - ethAfter);
        }
        emit log_named_uint("pot spent (wei)", potSpent);
    }

    // ── M7 ─────────────────────────────────────────────────────────────────────────

    /// M7a — inside one block the bucket is the ceiling plus the credits: the first full pump takes
    ///       80% of the ceiling, each next one at most 80% of what is left plus what its own swap
    ///       credited, and the block's total never exceeds one ceiling plus the credits earned.
    function test_M7a_bucketBoundedInsideBlock() public {
        _donateEth(key, 100 ether);
        _refill();
        uint256 feeCap = _feeCap();

        uint256 total;
        uint256 credits;
        for (uint256 i; i < 8; ++i) {
            // Sells: each is a dip under the reference, so the gate stays wide open and only the
            // bucket can bind (600 token ≈ 0.6 ETH received, 60% of which exceeds the ceiling)
            uint256 ethBefore = address(helper).balance;
            (uint256 s, ) = _swapPumped(false, -int256(600e18));
            uint256 received = address(helper).balance - ethBefore;
            credits += _credit(received);
            if (i == 0) assertApproxEqRel(s, (feeCap * HAIRCUT) / 10_000, 0.02e18, "first pump: 80% of the ceiling");
            // Level before this pump ≤ ceiling − Σ earlier spends + Σ credits so far
            uint256 level = feeCap + credits - total;
            if (level > feeCap) level = feeCap;
            assertLe(s, ((level * HAIRCUT) / 10_000) * 103 / 100, "each pump within 80% of its level");
            total += s;
        }
        assertLe(total, feeCap + credits, "the block's pumps sum to at most one ceiling plus the credits");
        assertGt(total, feeCap, "and the credits were actually spent");
        emit log_named_uint("8 in-block pumps (wei)", total);
        emit log_named_uint("ceiling (wei)", feeCap);
        emit log_named_uint("credits earned (wei)", credits);
    }

    /// M7b — the bucket refills linearly with time: after a full pump, the quote for a 1 ETH trade
    ///       reads 80% of (what was left + that trade's own credit + the time refill so far), half a
    ///       PUMP_REFILL later it has half a ceiling more, and a full one later it is whole again.
    function test_M7b_bucketRefillsLinearly() public {
        _donateEth(key, 100 ether);
        _refill();
        // A sell: under the reference the gate is open, so the bucket alone sizes the pump
        (uint256 first, ) = _swapPumped(false, -int256(2_000e18));
        uint256 feeCap = _feeCap();
        assertApproxEqRel(first, (feeCap * HAIRCUT) / 10_000, 0.02e18, "full pump");
        uint256 left = feeCap - first;
        uint256 credit = _credit(1 ether);

        (uint256 q0, ) = pump.quotePump(key, 1 ether);
        assertApproxEqRel(q0, ((left + credit) * HAIRCUT) / 10_000, 0.02e18, "same block: 80% of (left + credit)");

        vm.warp(block.timestamp + uint256(pump.PUMP_REFILL()) / 2);
        vm.roll(block.number + 1);
        (uint256 qHalf, ) = pump.quotePump(key, 1 ether);
        assertApproxEqRel(qHalf, ((left + credit + feeCap / 2) * HAIRCUT) / 10_000, 0.02e18,
            "half a refill later: half a ceiling more");

        vm.warp(block.timestamp + uint256(pump.PUMP_REFILL()));
        vm.roll(block.number + 1);
        (uint256 qFull, ) = pump.quotePump(key, 1 ether);
        assertApproxEqRel(qFull, (feeCap * HAIRCUT) / 10_000, 0.02e18, "a refill later: the whole ceiling again");
    }

    /// M7c — over time the pot spends `k·f × volume` plus the floor: fifty 2 ETH round trips twelve
    ///       seconds apart for ten minutes spend within a few percent of `k·f·200 ETH + f·R·(1 +
    ///       10min/PUMP_REFILL)` — a hot market is bought at k times what it earns the LPs.
    function test_M7c_paceIsLeveragedFees() public {
        _donateEth(key, 100 ether);
        _refill();
        uint256 feeCap = _feeCap();
        uint256 potBefore = pump.potOf(id).balance;

        uint256 volume;
        for (uint256 i; i < 50; ++i) {
            vm.warp(block.timestamp + 12);
            vm.roll(block.number + 1);
            uint256 ethBefore = address(helper).balance;
            (, int256 got) = helper.swap(key, true, -int256(2 ether));
            helper.swap(key, false, -got);
            volume += 2 ether + (address(helper).balance + 2 ether - ethBefore);
        }
        uint256 spent = potBefore - pump.potOf(id).balance;
        uint256 bound = _credit(volume) + feeCap + (feeCap * 600) / pump.PUMP_REFILL();
        assertLe(spent, (bound * 102) / 100, "at most k.f.volume plus the floor and the opening bucket");
        assertGe(spent, (bound * 80) / 100, "and the pace was actually used");
        emit log_named_uint("spent over 10 minutes of continuous trading (wei)", spent);
        emit log_named_uint("k.f.volume (wei)", _credit(volume));
    }

    /// M7d — a dust pump barely touches the bucket: a dust trade's pump leaves a full-size pump for
    ///       the real trade behind it in the same block. Manufactured dust cannot mute the pot.
    function test_M7d_dustPumpLeavesBucketFull() public {
        _donateEth(key, 100 ether);
        _refill();
        uint256 feeCap = _feeCap();

        (uint256 dust, ) = _swapPumped(true, -int256(1e12));
        assertLt(dust, feeCap / 1000, "a dust trade unlocked a dust pump");
        // The dust pump cost the bucket almost nothing; the sell moves the depth ~2% — the real
        // trade's pump is still within a few percent of a full one
        (uint256 real, ) = _swapPumped(false, -int256(2_000e18));
        assertGt(real, (feeCap * HAIRCUT) / 10_000 * 95 / 100, "the real trade still got a (nearly) full pump");
        assertLe(real, (feeCap * HAIRCUT) / 10_000, "and never more than one");
    }

    /// M7e — the quote is the live sizing, bucket and credit included: what `quotePump` says in a
    ///       block is what the pump spends in it, up to the depth the carrying swap itself moves.
    function test_M7e_quoteMirrorsBucket() public {
        _donateEth(key, 100 ether);
        _refill();
        helper.swap(key, false, -int256(2_000e18)); // draws the bucket down inside this block

        (uint256 quoted0, ) = pump.quotePump(key, 0);
        assertEq(quoted0, 0, "no demand, no pump");

        // Run a sell, read what the seller received and what the pump spent, rewind, and check the
        // quote for exactly that demand — in the same block, from the same drawn-down bucket. The
        // quote prices the pre-swap depth, the pump the post-swap one: a ~1% difference at most.
        uint256 snap = vm.snapshotState();
        uint256 ethBefore = address(helper).balance;
        (uint256 spent, ) = _swapPumped(false, -int256(1_000e18));
        uint256 received = address(helper).balance - ethBefore;
        vm.revertToState(snap);

        (uint256 quoted, ) = pump.quotePump(key, received);
        assertGt(quoted, 0, "a real pump");
        assertApproxEqRel(quoted, spent, 0.02e18, "the quote is the live sizing, bucket included");
        // And it is the drawn-down bucket that sized both: well under a full pump
        assertLt(quoted, (_feeCap() * HAIRCUT) / 10_000 / 2, "far below a fresh bucket's pump");
    }

    /// M7f — a single sell of `depth / k` fills the bucket by itself: right after a full pump
    ///       emptied it, a 12.5%-of-depth sell in the same block gets a full pump again. Real dumps
    ///       are bought at full size however busy the block has been.
    function test_M7f_bigSellFillsBucketAlone() public {
        _donateEth(key, 100 ether);
        _refill();
        (uint256 first, ) = _swapPumped(false, -int256(2_000e18));
        uint256 feeCap = _feeCap();
        assertApproxEqRel(first, (feeCap * HAIRCUT) / 10_000, 0.02e18, "first: a full pump");

        // A small sell now: a fraction of a pump (what was left plus its own small credit)
        (uint256 small, ) = _swapPumped(false, -int256(1_000e18));
        assertLt(small, (feeCap * HAIRCUT) / 10_000 / 2, "a small sell gets a fraction");

        // A sell worth depth/k of ETH: credits a whole ceiling, so a full pump behind it
        uint256 depth = _depth();
        uint256 ethBefore = address(helper).balance;
        (uint256 big, ) = _swapPumped(false, -int256(40_000e18));
        uint256 received = address(helper).balance - ethBefore;
        assertGe(received, depth / pump.PUMP_FEE_LEVERAGE(), "the sell moved at least depth/k");
        assertApproxEqRel(big, (_feeCap() * HAIRCUT) / 10_000, 0.03e18, "a full pump behind the big sell");
    }

    /// M7g — QUIET-MARKET MANUFACTURING: a 4% bag holder at the reference, in ONE block, runs twenty
    ///       1 ETH round trips. The bucket starts full (a one-off ceiling) and each leg adds `k·f`
    ///       of itself; the pot spends at most that, and the farmer loses — the volume they bought
    ///       unlocked `k×` its fee for the pot, `2·4%` of which reached their bag.
    function test_M7g_quietMarketManufacturingLoses() public {
        _donateEth(key, 100 ether);
        uint256 ethBefore = address(helper).balance;
        int256 bag = _bagAndSettle(4 ether);
        uint256 feeCap = _feeCap();

        uint256 potSpent = _roundTrips(20, 1 ether, 0);
        helper.swap(key, false, -bag);

        assertLe(potSpent, feeCap + _credit(40 ether), "pot spend <= the opening bucket + k.f.volume");
        assertLt(address(helper).balance, ethBefore, "the manufacturer lost");
        emit log_named_uint("pot spent in the block (wei)", potSpent);
        emit log_named_uint("manufacturer loss (wei)", ethBefore - address(helper).balance);
    }

    // ── M8 ─────────────────────────────────────────────────────────────────────────

    /// M8a — no sequence of trades and time skips makes the hook revert a swap. Random sizes in
    ///       both directions, random waits up to several time constants and a decade in one jump.
    function testFuzz_M8a_neverReverts(uint256 seed) public {
        _donateEth(key, 30 ether);
        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 wait = r % 4 == 0 ? 0 : (r >> 8) % (3 * uint256(pump.REFERENCE_TAU()));
            if (r % 97 == 0) wait = 10 * 365 days;
            vm.warp(block.timestamp + wait);
            vm.roll(block.number + (wait == 0 ? 0 : 1));
            if (r % 2 == 0) {
                uint256 eth = 1 + (r >> 16) % 40 ether;
                helper.swap(key, true, -int256(eth));
            } else {
                uint256 tok = 1 + (r >> 16) % 40_000e18;
                uint256 have = token.balanceOf(address(helper));
                if (tok > have) tok = have;
                if (tok != 0) helper.swap(key, false, -int256(tok));
            }
        }
        // Whatever happened, the books close
        assertGe(address(pump).balance, pump.obligationOf(ETH), "the hook covers what it owes");
    }

    /// M8b — a pool parked at the edge of the tick range still trades: the gate's clamps and the
    ///       pump's quiet exits hold where the arithmetic is most extreme.
    function test_M8b_extremeTickPoolSurvives() public {
        MockERC20 edge = new MockERC20("Edge", "EDGE", 18);
        IPoolManagerMin.PoolKey memory k2 = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(edge), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        bytes32 id2 = keccak256(abi.encode(k2));
        // Near MAX tick: currency1 (main) is almost worthless per ETH
        IPoolManagerMin(POOL_MANAGER).initialize(k2, GluedV4Core.getSqrtRatioAtTick(887_000));
        pump.initPot(k2, address(edge), address(0));
        edge.mint(address(helper), type(uint128).max);
        helper.addLiquidity(k2, TICK_LO, TICK_HI, 1e9);
        pump.donate{value: 1 ether}(k2, 1 ether);

        // Both directions, and the views, without a revert
        helper.swap(k2, true, -int256(1e9));
        helper.swap(k2, false, -int256(1e30));
        pump.pumpShareOf(id2);
        pump.quotePump(k2, 1 ether);
        assertGe(address(pump).balance, pump.obligationOf(ETH), "books closed");
    }

    // ── M9 ─────────────────────────────────────────────────────────────────────────

    /// M9 — the reference and the bucket are per pool: pushing and pumping pool A leaves pool B's
    ///      gate open and its bucket full.
    function test_M9_referenceAndBucketArePerPool() public {
        MockERC20 tokenB = new MockERC20("MainB", "MNB", 18);
        (IPoolManagerMin.PoolKey memory kB, bytes32 idB) = _openEthPool(address(tokenB), address(0));
        _donateEth(key, 50 ether);
        _donateEth(kB, 50 ether);
        _refill();

        helper.swap(key, true, -int256(30 ether)); // push A and draw A's bucket
        (uint256 shareA, , ) = pump.pumpShareOf(id);
        (uint256 shareB, int24 spotB, int24 refB) = pump.pumpShareOf(idB);
        assertLt(shareA, 0.01e18, "A is gated");
        assertEq(shareB, pump.PUMP_SHARE_MAX_WAD(), "B is wide open");
        assertEq(spotB, refB, "B's spot sits at its reference");

        // A 1 ETH quote on B: its credit is 8% of a ceiling, so a full bucket shows as a full pump
        (uint256 qB, ) = pump.quotePump(kB, 1 ether);
        uint256 feeCapB;
        {
            GluedV4Core.Slot0 memory s = GluedV4Core.getSlot0(POOL_MANAGER, idB);
            feeCapB = (GluedV4Core.tangentReserve(
                s.sqrtPriceX96, GluedV4Core.getPoolLiquidity(POOL_MANAGER, idB), true
            ) * FEE) / 1e6;
        }
        assertApproxEqRel(qB, (feeCapB * HAIRCUT) / 10_000, 0.02e18, "B's bucket is full");
        // While A's own quote for the same trade is the gated sliver
        (uint256 qA, ) = pump.quotePump(key, 1 ether);
        assertLt(qA, qB / 10, "A's is gated to a sliver");
    }

    // ── M10 ────────────────────────────────────────────────────────────────────────

    /// M10 — orientation when main is currency0: a dearer main is a HIGHER tick there, and the
    ///       gate must read the premium as `spot − ref`. Push main up: gated. Push it down: open.
    ///       And the rise cap must point the same way: a held push there opens at 3% a minute too.
    function test_M10_gateOrientationMainIsCurrency0() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 main, MockERC20 sec) = address(a) < address(b) ? (a, b) : (b, a);
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) =
            _openErc20Pool(address(main), address(sec), address(0), true);
        sec.mint(address(this), 1_000_000e18);
        sec.approve(address(pump), type(uint256).max);
        pump.donate(k2, 10_000e18);
        assertEq(k2.currency0, address(main), "main is currency0");

        // Buying main (currency0) with secondary (currency1) is oneForZero: a big push, +200%-ish
        ( , , int24 ref0) = pump.pumpShareOf(id2);
        helper.swap(k2, false, -int256(100_000e18));
        (uint256 shareUp, int24 spotUp, int24 refUp) = pump.pumpShareOf(id2);
        assertGt(spotUp, refUp, "a dearer main is a higher tick");
        assertLt(shareUp, 0.01e18, "and the gate closed on it");

        // Hold it 5 minutes: the reference rose by exactly the cap, upward in tick space here
        vm.warp(block.timestamp + 5 minutes);
        vm.roll(block.number + 1);
        helper.swap(k2, false, -1);
        ( , , int24 ref5) = pump.pumpShareOf(id2);
        assertApproxEqAbs(int256(ref5) - int256(ref0), int256(uint256(pump.REFERENCE_MAX_RISE_PER_MINUTE())) * 5, 1,
            "rose by five minutes of cap");

        // Sell main back below the reference: open again
        helper.swap(k2, true, -int256(300_000e18));
        (uint256 shareDown, int24 spotDown, int24 refDown) = pump.pumpShareOf(id2);
        assertLt(spotDown, refDown, "main below its reference");
        assertEq(shareDown, pump.PUMP_SHARE_MAX_WAD(), "full share");
    }

    // ── M11 ────────────────────────────────────────────────────────────────────────

    /// M11a — THE RISE CAP. A 30 ETH push (+69%, ~5,250 ticks) is HELD: uncapped, the reference
    ///        would be halfway after τ/2 and there after τ; capped, it rises exactly 296 ticks a
    ///        minute — 1,480 after five, 2,960 and still short after ten, there only once a full τ
    ///        has passed with the remaining gap under the cap's reach.
    function test_M11a_heldPushOpensAtCapNotTau() public {
        _donateEth(key, 100 ether);
        ( , , int24 ref0) = pump.pumpShareOf(id);
        helper.swap(key, true, -int256(30 ether));
        int24 pushed = pump.potOf(id).lastTick;
        uint256 gap = uint256(int256(ref0) - int256(pushed)); // main dearer = lower tick
        assertGt(gap, 296 * 10, "a push the cap, not tau, governs");
        uint256 cap = pump.REFERENCE_MAX_RISE_PER_MINUTE();

        vm.warp(block.timestamp + 5 minutes);
        vm.roll(block.number + 1);
        helper.swap(key, true, -1);
        ( , , int24 ref5) = pump.pumpShareOf(id);
        assertApproxEqAbs(int256(ref0) - int256(ref5), int256(cap * 5), 1, "five minutes: 5 x 296 ticks");
        (uint256 share5, , ) = pump.pumpShareOf(id);
        assertLt(share5, 0.01e18, "still gated hard");

        vm.warp(block.timestamp + 5 minutes);
        vm.roll(block.number + 1);
        helper.swap(key, true, -1);
        ( , , int24 ref10) = pump.pumpShareOf(id);
        assertApproxEqAbs(int256(ref0) - int256(ref10), int256(cap * 10), 1, "ten minutes: 10 x 296 ticks");
        assertLt(uint256(int256(ref0) - int256(ref10)), gap, "and NOT yet at the pushed price, though tau has passed");

        vm.warp(block.timestamp + uint256(pump.REFERENCE_TAU()));
        vm.roll(block.number + 1);
        helper.swap(key, true, -1);
        ( , , int24 ref20) = pump.pumpShareOf(id);
        int24 standing = pump.potOf(id).lastTick;
        assertApproxEqAbs(int256(ref20), int256(standing), 2, "twenty minutes: there");
        (uint256 share20, , ) = pump.pumpShareOf(id);
        assertEq(share20, pump.PUMP_SHARE_MAX_WAD(), "gate open");
    }

    /// M11b — a multi-block holder: 100 ETH pushes main x4 (+300%, ~13,860 ticks). Held for a
    ///        full τ the reference has moved 2,960 ticks — under a quarter of the way — and the
    ///        gate still reads a ~150% premium; the pushed price has to be held for 47 minutes,
    ///        blocks proportional to the move, before the pot believes it.
    function test_M11b_multiBlockHolderPaysInMinutes() public {
        _donateEth(key, 100 ether);
        ( , , int24 ref0) = pump.pumpShareOf(id);
        helper.swap(key, true, -int256(100 ether));
        int24 pushed = pump.potOf(id).lastTick;
        uint256 gap = uint256(int256(ref0) - int256(pushed));
        assertGt(gap, 13_000, "a x4 move");

        vm.warp(block.timestamp + uint256(pump.REFERENCE_TAU()));
        vm.roll(block.number + 1);
        helper.swap(key, true, -1);
        (uint256 shareTau, , int24 refTau) = pump.pumpShareOf(id);
        assertApproxEqAbs(int256(ref0) - int256(refTau), int256(296 * 10), 1, "tau later: only ten minutes of cap");
        assertGt(_premiumWad(), 1.4e18, "the gate still reads a >140% premium");
        assertLt(shareTau, 0.003e18, "share under 0.3%");

        // Enough minutes for the whole gap: gap / 296 rounded up
        uint256 minutesNeeded = (gap + 295) / 296;
        vm.warp(block.timestamp + (minutesNeeded - 10) * 60);
        vm.roll(block.number + 1);
        helper.swap(key, true, -1);
        (uint256 shareDone, , ) = pump.pumpShareOf(id);
        assertEq(shareDone, pump.PUMP_SHARE_MAX_WAD(), "believed only after gap/296 minutes");
        emit log_named_uint("minutes the x4 push had to be held", minutesNeeded);
    }

    /// M11c — a FALL is never capped: a 30,000-token dump (main −40%) is fully in the reference
    ///        after τ, and the gate is wide open the whole way — dips are believed at once.
    function test_M11c_fallIsNeverCapped() public {
        _donateEth(key, 100 ether);
        ( , , int24 ref0) = pump.pumpShareOf(id);
        helper.swap(key, false, -int256(30_000e18));
        int24 dropped = pump.potOf(id).lastTick;
        assertGt(uint256(int256(dropped) - int256(ref0)), 296 * 10, "a fall larger than tau's worth of cap");
        (uint256 share0, , ) = pump.pumpShareOf(id);
        assertEq(share0, pump.PUMP_SHARE_MAX_WAD(), "open on the dip");

        vm.warp(block.timestamp + uint256(pump.REFERENCE_TAU()));
        vm.roll(block.number + 1);
        helper.swap(key, true, -1);
        ( , , int24 refTau) = pump.pumpShareOf(id);
        assertApproxEqAbs(int256(refTau), int256(dropped), 1, "tau later the whole fall is in the reference");
    }
}
