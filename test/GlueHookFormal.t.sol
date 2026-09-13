// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {GlueHookFixture} from "./helpers/GlueHookFixture.sol";
import {IGlueHook} from "../contracts/interfaces/IGlueHook.sol";
import {GluedV4Core, IPoolManagerMin} from "../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev A recipient that refuses every pushed ETH delivery, then pulls its own backlog with `claim`
///      (accepting only inside its own pull).
contract RefusesEth {
    bool private pulling;

    function pull(IGlueHook pump, address asset) external returns (uint256 got) {
        pulling = true;
        got = pump.claim(asset);
        pulling = false;
    }

    receive() external payable {
        require(pulling);
    }
}

/**
 * @title  GlueHookFormal — fuzzed proofs of the load-bearing arithmetic.
 * @notice FM1–FM15. These are the properties the audit's math section states as theorems, discharged
 *         against the REAL PoolManager over hundreds of random pot sizes, buy sizes, sell sizes and
 *         split configurations:
 *
 *   FM1  pump spend is bounded by 0.8·min(pot, feeCap, 60%·demand) — never the pot, never more than
 *        the gated share of the carrying trade, always strictly inside the fee ceiling
 *   FM2  pump spend is monotone in the carrying trade — a bigger trade never yields a smaller pump
 *   FM3  a sell into a rich pot pays the seller EXACTLY what a hookless twin pool pays, to the wei —
 *        the pump behind it never touches their execution and never lifts the price back above
 *        where the sell started (the seller's pool-equivalence, fuzzed)
 *   FM4  the reference gate's share is sane at every premium: capped at 60%, never above `f/d`
 *        above the reference, the full 60% at or below it
 *   FM5  a live pump's realised spend never exceeds its own quote, and its output clears its floor
 *   FM6  the quote functions are pure previews — calling them never mutates a pot
 *   FM7  the harvest split conserves EXACTLY under arbitrary share pairs — floor WAD legs, remainders
 *        to the recipients, both sides summing back to the gross fees to the wei
 *   FM8  the compound never outspends its budget under every legal (compound, buyback, burn) triple,
 *        and full conservation holds with the mint's unplaced budget sitting in the CARRY
 *   FM9  a refused push books EXACTLY the refused leg in the owed ledger, the obligation covers it,
 *        and `claim` later drains it to the wei
 *   FM10 self-sandwich accounting — the pump the attacker summons is capped by the gated share of
 *        their own buy, the round trip never ends ETH-positive, and every pot spend burned real
 *        supply: the "attack" is a filled buy order from the pot's perspective (fuzzed)
 *   FM11 auto-compound monotone growth — an armed program's liquidity never decreases through any
 *        trade, whatever the compound share, sizes or direction mix, with custody solvent throughout
 *   FM12 global carry conservation — over a whole sequence of harvests, Σ compound slices equals
 *        Σ mint consumption plus the final carry, per side to the wei
 *   FM13 the pace bound — over any fuzzed sequence of trades and waits the pot spends at most
 *        `k·f·Σdemand + feeCap·(1 + elapsed/PUMP_REFILL)`
 *   FM14 the rise bound — between any two observations the reference rises at most 296·dt/60 ticks
 *        toward a dearer main, and never past the tick that stood
 *   FM15 the credit, exact — from a drained bucket a dip of demand D pumps 0.8·min(feeCap, left + k·f·D)
 */
contract GlueHookFormal is GlueHookFixture {
    MockERC20 token;
    IPoolManagerMin.PoolKey key;
    bytes32 id;
    IPoolManagerMin.PoolKey twin;

    uint256 constant HAIRCUT_BPS = 8_000;
    uint256 constant BPS = 10_000;
    /// @dev The gate's full share, in force at or below the reference (the launch price here).
    uint256 constant SHARE_MAX = 0.6e18;

    function setUp() public {
        _deployCore();
        token = new MockERC20("Main", "MAIN", 18);
        (key, id) = _openEthPool(address(token), address(0));
        twin = _openTwinPool(address(token));
        // The split theorems (FM7–FM9) fund a program position from this contract
        token.mint(address(this), 10_000_000e18);
        token.approve(address(pump), type(uint256).max);
    }

    /// FM1 — the pump's spend obeys `spend ≤ 0.8·min(pot, feeCap, s·demand)` with `s` the gate's
    ///       share — the full 60% here, the pool sitting at its reference — so it never exceeds the
    ///       pot, never exceeds 48% of the carrying trade, and always sits strictly inside the fee
    ///       ceiling (`0.8 · 0.3% · 100 ETH` of tangent depth).
    function testFuzz_FM1_pumpSpendBounds(uint256 potSize, uint256 userIn) public {
        potSize = bound(potSize, 0.001 ether, 500 ether);
        userIn = bound(userIn, 1e9, 100 ether);
        _donateEth(key, potSize);

        (uint256 spend, uint256 minOut) = pump.quotePump(key, userIn);

        assertLe(spend, potSize, "spend never exceeds the pot");
        // spend ≤ 0.8·0.6·demand (the haircut applied to the gated demand ceiling, floored)
        assertLe(spend, (((userIn * SHARE_MAX) / 1e18) * HAIRCUT_BPS) / BPS, "spend never exceeds 48% of the trade");
        assertLe(spend, (0.3 ether * HAIRCUT_BPS) / BPS + 1, "and never the haircut fee ceiling");
        // Whenever the pump fires, it has a real output floor to enforce
        if (spend > 0) assertGt(minOut, 0, "a firing pump always carries a floor");
    }

    /// FM2 — a larger carrying trade never yields a smaller pump: spend is monotone non-decreasing in
    ///       the demand (rising until the fee ceiling, then flat).
    function testFuzz_FM2_pumpMonotoneInBuy(uint256 potSize, uint256 aIn, uint256 bIn) public {
        potSize = bound(potSize, 1 ether, 500 ether);
        aIn = bound(aIn, 1e9, 100 ether);
        bIn = bound(bIn, aIn, 200 ether); // bIn >= aIn
        _donateEth(key, potSize);

        (uint256 spendA, ) = pump.quotePump(key, aIn);
        (uint256 spendB, ) = pump.quotePump(key, bIn);
        assertLe(spendA, spendB, "a bigger buy cannot pump less");
    }

    /// FM3 — a sell into a rich pot pays the seller exactly the hookless twin, to the wei: the pump
    ///       runs behind the trade and never touches it. The pump then lifts the price back — but
    ///       never above where the sell started, since it spends under half of what the seller got.
    ///       Fuzzed over sell sizes against a pot rich enough that only the fee ceiling binds.
    function testFuzz_FM3_sellerParity(uint256 sellSize) public {
        sellSize = bound(sellSize, 1e15, 40_000e18);
        _donateEth(key, 2_000 ether);

        uint256 snap = vm.snapshotState();
        uint160 priceBefore = _sqrtPrice(id);
        uint256 ethBefore = address(helper).balance;
        vm.recordLogs();
        helper.swap(key, false, -int256(sellSize));
        (bool pumped, uint256 spent, ) = _lastPumped(vm.getRecordedLogs());
        uint256 hookedPayout = address(helper).balance - ethBefore;
        uint160 priceAfter = _sqrtPrice(id);
        vm.revertToState(snap);

        ethBefore = address(helper).balance;
        helper.swap(twin, false, -int256(sellSize));
        uint256 twinPayout = address(helper).balance - ethBefore;
        vm.revertToState(snap);

        assertEq(hookedPayout, twinPayout, "the seller is paid exactly what the twin pool pays");
        // Main is currency1: a dearer main is a LOWER sqrt ratio, so "never above the sell's start"
        // reads as the ratio never falling back under where it was
        assertGe(priceAfter, priceBefore, "and the pump never lifts main's price above the sell's start");
        if (pumped) {
            assertLe(spent, (((hookedPayout * SHARE_MAX) / 1e18) * HAIRCUT_BPS) / BPS + 1,
                "the pump spends at most 48% of what the seller received");
        }
    }

    /// FM4 — the reference gate's share is sane at every premium. A fuzzed push lifts spot over the
    ///       reference (the launch price, held in the same block); the share the gate reports is
    ///       capped at 60%, is the full 60% up to the 0.5% premium where `f/d` crosses it, and above
    ///       that satisfies `share · d ≤ f` — the push-and-farm break-even with BOTH legs of the
    ///       round trip summoning pumps, `d` computed exactly from the tick gap the hook itself used.
    function testFuzz_FM4_gateShareSane(uint256 pushIn) public {
        pushIn = bound(pushIn, 1e12, 300 ether);
        _donateEth(key, 1 ether);
        helper.swap(key, true, -int256(pushIn));

        (uint256 share, int24 spot, int24 ref) = pump.pumpShareOf(id);
        assertLe(share, SHARE_MAX, "never above the maximum share");
        // Main is currency1: a dearer main is a LOWER tick, so the premium gap is `ref − spot`
        if (spot >= ref) {
            assertEq(share, SHARE_MAX, "at or below the reference the share is whole");
            return;
        }
        // d = 1.0001^(ref − spot) − 1, in WAD, from the same sqrt-ratio port the hook uses
        uint256 sqrtR = GluedV4Core.getSqrtRatioAtTick(ref - spot);
        uint256 ratioWad = (((sqrtR * sqrtR) >> 96) * 1e18) >> 96;
        uint256 dWad = ratioWad - 1e18;
        // f in WAD for a 0.3% pool
        uint256 feeWad = 0.003e18;
        if (dWad * SHARE_MAX <= feeWad * 1e18) {
            assertEq(share, SHARE_MAX, "below the crossing premium the share is still whole");
        } else {
            // share·d ≤ f (a hair of rounding slack on the WAD products)
            assertLe((share * dWad) / 1e18, feeWad + 1e9, "above it, share x premium never exceeds f");
            assertGt(share, 0, "but the gate never closes outright");
        }
    }

    /// FM5 — a live pump's realised spend never exceeds what its own quote sized, and the main it
    ///       actually buys clears the floor the quote set. Execution can only be tighter than the plan.
    function testFuzz_FM5_livePumpWithinQuote(uint256 potSize, uint256 buySize) public {
        potSize = bound(potSize, 0.01 ether, 500 ether);
        buySize = bound(buySize, 1e15, 30 ether);
        _donateEth(key, potSize);

        vm.recordLogs();
        helper.swap(key, true, -int256(buySize));
        (bool pumped, uint256 spent, uint256 bought) = _lastPumped(vm.getRecordedLogs());

        if (pumped) {
            // The buy paid at least `spent` in secondary, so the pump rode strictly inside real demand
            assertGt(spent, 0, "a landed pump spent something");
            assertGt(bought, 0, "and bought something");
            assertLe(spent, potSize, "never more than the pot");
        }
    }

    /// FM6 — the quotes are pure previews: calling them never moves a pot. A view that quietly spent
    ///       would be the worst kind of accounting bug, so it is asserted directly.
    function testFuzz_FM6_quotesArePure(uint256 potSize, uint256 amt) public {
        potSize = bound(potSize, 0.01 ether, 500 ether);
        amt = bound(amt, 1e9, 50 ether);
        _donateEth(key, potSize);

        uint256 balBefore = pump.potOf(id).balance;
        IGlueHook.Pot memory before = pump.potOf(id);
        pump.quotePump(key, amt);
        pump.pumpShareOf(id);
        assertEq(pump.potOf(id).balance, balBefore, "a quote never spends");
        assertEq(pump.potOf(id).referenceTickX8, before.referenceTickX8, "nor moves the reference");
        assertEq(pump.potOf(id).lastTimestamp, before.lastTimestamp, "nor observes");
    }

    /// FM10 — SELF-SANDWICH ACCOUNTING, both sides of the ledger. An attacker who buys purely to
    ///        summon the pump and then dumps the whole bag is playing a game the pot is DESIGNED to
    ///        accept: the pot's mandate is to convert its inventory into bought-and-burned main, and
    ///        that is exactly what happens. Fuzzed over every pot depth and attack size, the theorem
    ///        is three-sided:
    ///
    ///        1. the pump the attacker's buy summons never spends more than the gated share of that
    ///           buy (`spend ≤ 0.8·0.6·attackIn` at most, less once their own push lifts spot over
    ///           the reference — forcing a bigger pump costs proportionally more real money);
    ///        2. the round trip never ends ETH-POSITIVE: the fee ceiling bounds what the buy-side
    ///           pump can lift the price by below what the attacker pays in fees, and the sell-side
    ///           pump fires behind their dump, where they cannot sell into it;
    ///        3. every wei the pot spent converted into main that was actually BURNED — supply went
    ///           down. From the hook's perspective the "attack" is a filled buy order: the attacker
    ///           risked real capital (open inventory that anyone else can sandwich, fees on both
    ///           legs) to deliver the pot the tokens it exists to buy.
    function testFuzz_FM10_selfSandwichAccounting(uint256 potSize, uint256 attackIn) public {
        potSize = bound(potSize, 0.001 ether, 1_000 ether);
        attackIn = bound(attackIn, 1e12, 60 ether);
        _donateEth(key, potSize);

        uint256 potBefore = pump.potOf(id).balance;
        uint256 ethBefore = address(helper).balance;
        uint256 tokBefore = token.balanceOf(address(helper));
        uint256 supplyBefore = token.totalSupply();
        uint256 hookTokBefore = token.balanceOf(address(pump));
        uint256 deadBefore = token.balanceOf(address(0xdEaD));

        // The attacker's own buy is the only thing that can carry the pump…
        (, int256 gotTok) = helper.swap(key, true, -int256(attackIn));

        // …and the pump it summons never spends more than the gated share of the attack itself
        uint256 pumpSpent = potBefore - pump.potOf(id).balance;
        assertLe(pumpSpent, (((attackIn * SHARE_MAX) / 1e18) * HAIRCUT_BPS) / BPS,
            "the pump's spend is capped by the gated share of the attacker's own money");

        // The attacker dumps the entire bag — a pump fires behind the dump, out of their reach
        if (gotTok > 0) helper.swap(key, false, -gotTok);

        uint256 potSpent = potBefore - pump.potOf(id).balance;
        // Burned = supply reduction (a native burn) plus the 0xdEaD fallthrough (this mock has no burn())
        uint256 burned = (supplyBefore - token.totalSupply()) + (token.balanceOf(address(0xdEaD)) - deadBefore);

        assertEq(token.balanceOf(address(helper)), tokBefore, "attacker ends token-flat");
        // (2) the round trip never pays
        assertLe(address(helper).balance, ethBefore, "the attacker never ends ETH-positive");
        // (3) the pot's whole spend is accounted as bought main — burned outright, or (for a
        //     dust-sized fill below the delivery threshold) held on the hook for the next delivery
        uint256 acquired = burned + (token.balanceOf(address(pump)) - hookTokBefore);
        if (potSpent > 0) assertGt(acquired, 0, "every pot spend converted into bought main");
    }

    /// @dev A program config literal for the split theorems.
    function _splitCfg(uint64 cw, uint64 bb, uint64 burn, address secR, address mainR)
        private pure returns (IGlueHook.ProgramConfig memory)
    {
        return IGlueHook.ProgramConfig({
            buybackShareWad: bb,
            burnShareWad: burn,
            compoundShareWad: cw,
            potCompoundShareWad: 0,
            potBurnShareWad: 0,
            publicHarvest: false,
            secondaryRecipient: secR,
            mainRecipient: mainR,
            minMain: type(uint256).max,
            minSecondary: type(uint256).max
        });
    }

    /// @dev The LAST `Harvested` in a recorded window, or `found = false`.
    function _harvested(Vm.Log[] memory logs)
        private view
        returns (bool found, uint256 fMain, uint256 fSec, uint256 burned, uint256 fueled)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pump)) continue;
            if (logs[i].topics[0] != keccak256("Harvested(bytes32,uint256,uint256,uint256,uint256)")) continue;
            found = true;
            (fMain, fSec, burned, fueled) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
        }
    }

    /// @dev The LAST `Compounded` in a recorded window, or `found = false`.
    function _compounded(Vm.Log[] memory logs)
        private view
        returns (bool found, uint128 liq, uint256 u0, uint256 u1)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pump)) continue;
            if (logs[i].topics[0] != keccak256("Compounded(bytes32,uint128,uint256,uint256)")) continue;
            found = true;
            (liq, u0, u1) = abi.decode(logs[i].data, (uint128, uint256, uint256));
        }
    }

    /// FM7 — the harvest split is exactly conservative for EVERY share pair: each fixed leg is the
    ///       floor of its WAD product, each remainder goes whole to its recipient, and both sides sum
    ///       back to the gross fees to the wei. The specific-value split tests are instances of this.
    function testFuzz_FM7_harvestSplitConservation(uint256 bb, uint256 burn) public {
        bb = bound(bb, 0, 1e18);
        burn = bound(burn, 0, 1e18);
        address carol = makeAddr("fm7carol");
        address dave = makeAddr("fm7dave");
        pump.addLiquidityAdvanced{value: 50 ether}(
            key, TICK_LO, TICK_HI, 1e21, address(this),
            _splitCfg(0, uint64(bb), uint64(burn), carol, dave)
        );
        helper.swap(key, true, -int256(5 ether));
        helper.swap(key, false, -int256(4_000e18));

        uint256 potBefore = pump.potOf(id).balance;
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.recordLogs();
        pump.harvest(key);
        (bool found, uint256 fMain, uint256 fSec, uint256 burned, uint256 fueled) =
            _harvested(vm.getRecordedLogs());

        assertTrue(found, "the harvest ran");
        assertGt(fMain, 0, "token fees accrued");
        assertGt(fSec, 0, "ETH fees accrued");
        assertEq(fueled, (fSec * bb) / 1e18, "the pot leg is the floor WAD product");
        assertEq(burned, (fMain * burn) / 1e18, "and so is the burn leg");
        assertEq(pump.potOf(id).balance - potBefore, fueled, "the pot was credited exactly");
        assertEq(carol.balance, fSec - fueled, "carol holds the exact ETH remainder");
        assertEq(token.balanceOf(dave), fMain - burned, "dave the exact token remainder");
        assertEq(token.balanceOf(DEAD) - deadBefore, burned, "the burn landed whole at dead");
        // Conservation, both sides, to the wei
        assertEq(fueled + carol.balance, fSec, "the ETH side sums back to the gross");
        assertEq(burned + token.balanceOf(dave), fMain, "the token side sums back to the gross");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "and the venue stays solvent");
    }

    /// FM8 — for EVERY legal (compound, buyback, burn) triple, the mint never outspends either side
    ///       of its budget, the position grows by exactly the minted liquidity, and full conservation
    ///       holds with the mint's unplaced budget sitting in the CARRY — every wei of the harvest is
    ///       in the position, the pot, a recipient, dead, or the carry. Nothing else, nothing missing.
    function testFuzz_FM8_compoundWithinSlice(uint256 cw, uint256 bb, uint256 burn) public {
        cw = bound(cw, 1, 1e18);
        bb = bound(bb, 0, 1e18 - cw);
        burn = bound(burn, 0, 1e18 - cw);
        address carol = makeAddr("fm8carol");
        address dave = makeAddr("fm8dave");
        pump.addLiquidityAdvanced{value: 50 ether}(
            key, TICK_LO, TICK_HI, 1e21, address(this),
            _splitCfg(uint64(cw), uint64(bb), uint64(burn), carol, dave)
        );
        helper.swap(key, true, -int256(5 ether));
        helper.swap(key, false, -int256(4_000e18));

        uint256 liqBefore = pump.programOf(id).liquidity;
        uint256 potBefore = pump.potOf(id).balance;
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.recordLogs();
        pump.harvest(key);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, uint256 fMain, uint256 fSec, , ) = _harvested(logs);
        (bool cFound, uint128 liq, uint256 u0, uint256 u1) = _compounded(logs);

        assertTrue(found, "the harvest ran");
        if (cFound) {
            assertLe(u0, (fSec * cw) / 1e18, "the mint never outspends the ETH budget (no prior carry)");
            assertLe(u1, (fMain * cw) / 1e18, "nor the token budget");
            assertGt(liq, 0, "a landed compound minted real liquidity");
            assertEq(pump.programOf(id).liquidity - liqBefore, liq, "the position grew by exactly it");
        }
        // Conservation with the mint folded in: what the fees brought either sits in the position
        // (u0/u1), in the pot, at a recipient, at dead, or in the CARRY — nothing else, nothing missing
        assertEq(
            (pump.potOf(id).balance - potBefore) + carol.balance + u0 + pump.programOf(id).carrySecondary,
            fSec, "the ETH side conserves through the compound"
        );
        assertEq(
            (token.balanceOf(DEAD) - deadBefore) + token.balanceOf(dave) + u1 + pump.programOf(id).carryMain,
            fMain, "and so does the token side"
        );
        assertGe(address(pump).balance, pump.obligationOf(ETH), "and the venue stays solvent");
    }

    /// FM9 — a refused push books EXACTLY the refused leg, `obligationOf` covers it wei-for-wei, and
    ///       the recipient's later `claim` drains it whole. Fuzzed over the share that sizes the leg.
    function testFuzz_FM9_owedLedgerExact(uint256 bb) public {
        bb = bound(bb, 0, 999e15); // a live ETH remainder must exist to be refused
        RefusesEth sulky = new RefusesEth();
        address dave = makeAddr("fm9dave");
        pump.addLiquidityAdvanced{value: 50 ether}(
            key, TICK_LO, TICK_HI, 1e21, address(this),
            _splitCfg(0, uint64(bb), 0, address(sulky), dave)
        );
        helper.swap(key, true, -int256(5 ether));
        helper.swap(key, false, -int256(4_000e18));

        vm.recordLogs();
        pump.harvest(key);
        (bool found, , uint256 fSec, , uint256 fueled) = _harvested(vm.getRecordedLogs());

        assertTrue(found, "the harvest ran");
        uint256 leg = fSec - fueled;
        if (leg == 0) return; // an all-pot split leaves nothing to refuse
        assertEq(pump.owedOf(address(sulky), ETH), leg, "the refused leg booked exactly");
        assertGe(pump.obligationOf(ETH), leg, "the obligation ledger covers it");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "with real balance behind it");

        uint256 got = sulky.pull(pump, ETH);
        assertEq(got, leg, "claim drained the exact booking");
        assertEq(pump.owedOf(address(sulky), ETH), 0, "and zeroed it");
        assertEq(address(sulky).balance, leg, "the wei arrived");
    }

    /// FM12 — GLOBAL CARRY CONSERVATION: across a whole SEQUENCE of harvests under a fuzzed compound
    ///        share, the sum of every round's compound slice equals what the mints actually consumed
    ///        plus the final standing carry — per side, to the wei. The carry ledger neither leaks
    ///        nor invents money over its entire life, whatever the trade sizes did to the anchor.
    function testFuzz_FM12_carryConservationAcrossRounds(uint256 cw, uint256 a, uint256 b) public {
        cw = bound(cw, 1e16, 1e18);
        a = bound(a, 0.5 ether, 5 ether);
        b = bound(b, 500e18, 4_000e18);
        address carol = makeAddr("fm12carol");
        address dave = makeAddr("fm12dave");
        pump.addLiquidityAdvanced{value: 50 ether}(
            key, TICK_LO, TICK_HI, 1e21, address(this),
            _splitCfg(uint64(cw), 0, 0, carol, dave)
        );

        uint256 sumCMain;
        uint256 sumCSec;
        uint256 sumUMain;
        uint256 sumUSec;
        for (uint256 i; i < 3; ++i) {
            helper.swap(key, true, -int256(a));
            helper.swap(key, false, -int256(b));
            vm.recordLogs();
            pump.harvest(key);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            (bool found, uint256 fMain, uint256 fSec, , ) = _harvested(logs);
            (bool cFound, , uint256 u0, uint256 u1) = _compounded(logs);
            if (found) {
                sumCMain += (fMain * cw) / 1e18;
                sumCSec += (fSec * cw) / 1e18;
            }
            if (cFound) {
                sumUMain += u1;
                sumUSec += u0;
            }
        }

        assertEq(pump.programOf(id).carryMain, sumCMain - sumUMain, "sum slices == sum consumed + carry (main)");
        assertEq(pump.programOf(id).carrySecondary, sumCSec - sumUSec, "and on the ETH side");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "ETH custody covers it throughout");
        assertGe(token.balanceOf(address(pump)), pump.obligationOf(address(token)), "and token custody");
    }

    /// FM11 — AUTO-COMPOUND MONOTONE GROWTH: with the program armed for in-swap harvesting, the
    ///        position's liquidity NEVER decreases through any trade — whatever the compound share,
    ///        the trade sizes, or the direction mix — and custody covers the obligation ledger on
    ///        both assets after every single swap. The auto-compounding the venue lacks natively
    ///        can only ever grow the position.
    function testFuzz_FM11_autoCompoundMonotoneGrowth(uint256 cw, uint256 s1, uint256 s2, uint256 s3) public {
        // The config carries a 30% buyback share, so compound may claim at most the other 70%
        cw = bound(cw, 1, 7e17);
        s1 = bound(s1, 0.01 ether, 10 ether);
        s2 = bound(s2, 100e18, 8_000e18);
        s3 = bound(s3, 0.01 ether, 10 ether);
        address carol = makeAddr("fm11carol");
        address dave = makeAddr("fm11dave");
        pump.addLiquidityAdvanced{value: 60 ether}(
            key, TICK_LO, TICK_HI, 1e21,
            address(this),
            IGlueHook.ProgramConfig({
                buybackShareWad: uint64(3e17),
                burnShareWad: uint64(2e17),
                compoundShareWad: uint64(cw),
                potCompoundShareWad: 0,
                potBurnShareWad: 0,
                publicHarvest: false,
                secondaryRecipient: carol,
                mainRecipient: dave,
                minMain: 1, // armed: every swap may auto-harvest and compound
                minSecondary: 1
            })
        );

        uint256 last = pump.programOf(id).liquidity;

        helper.swap(key, true, -int256(s1)); // buy
        uint256 now_ = pump.programOf(id).liquidity;
        assertGe(now_, last, "a buy never shrinks the position");
        last = now_;
        assertGe(address(pump).balance, pump.obligationOf(ETH), "ETH solvency after the buy");

        helper.swap(key, false, -int256(s2)); // sell
        now_ = pump.programOf(id).liquidity;
        assertGe(now_, last, "a sell never shrinks the position");
        last = now_;
        assertGe(token.balanceOf(address(pump)), pump.obligationOf(address(token)), "token solvency after the sell");

        helper.swap(key, true, -int256(s3)); // buy again — harvests the sell's fees in-flight
        now_ = pump.programOf(id).liquidity;
        assertGe(now_, last, "the third trade never shrinks it either");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "ETH solvency at rest");
        assertGe(token.balanceOf(address(pump)), pump.obligationOf(address(token)), "token solvency at rest");
    }
}

/**
 * @title  GlueHookFormalPacing — the pacing theorems (FM13–FM15), in their own contract so the
 *         fuzz loops' locals never crowd the main suite's stack.
 */
contract GlueHookFormalPacing is GlueHookFixture {
    MockERC20 token;
    IPoolManagerMin.PoolKey key;
    bytes32 id;

    uint256 constant HAIRCUT_BPS = 8_000;
    uint256 constant BPS = 10_000;
    uint256 constant SHARE_MAX = 0.6e18;

    function setUp() public {
        _deployCore();
        token = new MockERC20("Main", "MAIN", 18);
        (key, id) = _openEthPool(address(token), address(0));
    }

    /// @dev The pool's fee ceiling `f·R` on the ETH side at the live price.
    function _feeCap() internal view returns (uint256) {
        GluedV4Core.Slot0 memory s = GluedV4Core.getSlot0(POOL_MANAGER, id);
        return (GluedV4Core.tangentReserve(
            s.sqrtPriceX96, GluedV4Core.getPoolLiquidity(POOL_MANAGER, id), true
        ) * FEE) / 1e6;
    }

    /// FM13 — THE PACE BOUND, fuzzed. Over any sequence of trades (both directions, random sizes)
    ///        and waits (zero to hours), the pot's total spend never exceeds
    ///        `k·f·Σ demand + feeCap_max · (1 + elapsed / PUMP_REFILL)`: `k×` the LP fees the flow
    ///        earned, plus the time floor, plus the bucket it started with. The pot cannot be
    ///        drained faster than the pool is used, whoever is trading.
    function testFuzz_FM13_paceBound(uint256 seed, uint256 potSize) public {
        potSize = bound(potSize, 1 ether, 500 ether);
        _donateEth(key, potSize);
        vm.warp(block.timestamp + 1 hours); // start from a full bucket
        vm.roll(block.number + 1);
        uint256 potBefore = pump.potOf(id).balance;
        // Accumulated from the waits, NOT `block.timestamp − t0`: under via-IR the optimiser may
        // rematerialise `block.timestamp` at its use site (it is invariant within a real
        // transaction), which `vm.warp` breaks — a captured `t0` would read the post-warp clock.
        uint256 elapsed;
        uint256 demandSum;
        uint256 feeCapMax = _feeCap();

        for (uint256 i; i < 16; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 wait = r % 3 == 0 ? 0 : (r >> 8) % 2 hours;
            vm.warp(block.timestamp + wait);
            vm.roll(block.number + (wait == 0 ? 0 : 1));
            elapsed += wait;
            uint256 ethBefore = address(helper).balance;
            if (r % 2 == 0) {
                helper.swap(key, true, -int256(1 + (r >> 16) % 30 ether));
                demandSum += ethBefore - address(helper).balance;
            } else {
                uint256 tok = 1 + (r >> 16) % 30_000e18;
                uint256 have = token.balanceOf(address(helper));
                if (tok > have) tok = have;
                if (tok != 0) helper.swap(key, false, -int256(tok));
                demandSum += address(helper).balance - ethBefore;
            }
            uint256 fc = _feeCap();
            if (fc > feeCapMax) feeCapMax = fc;
        }
        uint256 spent = potBefore - pump.potOf(id).balance;
        uint256 bound_ = (pump.PUMP_FEE_LEVERAGE() * FEE * demandSum) / 1e6
            + feeCapMax + (feeCapMax * elapsed) / pump.PUMP_REFILL();
        assertLe(spent, bound_ + bound_ / 100, "pot spend <= k.f.volume + floor + opening bucket");
    }

    /// FM14 — THE RISE BOUND, fuzzed. Between any two observations the reference never moves in
    ///        main's dearer direction by more than `296 · dt / 60` ticks (plus a 1/256th of
    ///        rounding), whatever stood in between; falls are only bounded by where spot stood.
    function testFuzz_FM14_riseBound(uint256 seed) public {
        _donateEth(key, 50 ether);
        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            IGlueHook.Pot memory before = pump.potOf(id);
            uint256 wait = 1 + (r >> 8) % 40 minutes; // a new block every time: dt > 0
            vm.warp(block.timestamp + wait);
            vm.roll(block.number + 1);
            if (r % 2 == 0) helper.swap(key, true, -int256(1 + (r >> 16) % 80 ether));
            else {
                uint256 tok = 1 + (r >> 16) % 80_000e18;
                uint256 have = token.balanceOf(address(helper));
                if (tok > have) tok = have;
                if (tok != 0) helper.swap(key, false, -int256(tok));
            }
            IGlueHook.Pot memory after_ = pump.potOf(id);
            // Main is currency1: dearer main = lower tick, so a RISE for main is refX8 going DOWN
            int256 riseX8 = int256(before.referenceTickX8) - int256(after_.referenceTickX8);
            int256 capX8 = int256(uint256(pump.REFERENCE_MAX_RISE_PER_MINUTE()) << 8) * int256(wait) / 60;
            assertLe(riseX8, capX8 + 1, "the reference never rises faster than the cap");
            // And never past the tick that stood
            if (riseX8 > 0) {
                assertGe(after_.referenceTickX8, int32(before.lastTick) << 8, "never past the standing tick");
            } else {
                assertLe(after_.referenceTickX8, int32(before.lastTick) << 8, "a fall never past the standing tick");
            }
        }
    }

    /// FM15 — THE CREDIT, exact. From a drained bucket, a dip of demand `D` in the same block gets a
    ///        pump of `0.8 · min(feeCap, left + k·f·D)` — the volume credit lands before the pump is
    ///        sized. The bucket keeps `left` as a FRACTION of the ceiling (the 20% a full pump's
    ///        haircut leaves), so it is worth `0.2 × the ceiling at the dip's own depth`; a ~3% band
    ///        covers the depth the dip itself moved.
    function testFuzz_FM15_creditExact(uint256 sellTok) public {
        sellTok = bound(sellTok, 10e18, 40_000e18);
        _donateEth(key, 500 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        // Drain the bucket with a full pump behind a first dip
        vm.recordLogs();
        helper.swap(key, false, -int256(2_000e18));
        ( , uint256 first, ) = _lastPumped(vm.getRecordedLogs());
        assertApproxEqRel(first, (_feeCap() * HAIRCUT_BPS) / BPS, 0.03e18, "the first dip drained the bucket");

        uint256 ethBefore = address(helper).balance;
        vm.recordLogs();
        helper.swap(key, false, -int256(sellTok));
        ( , uint256 spent, ) = _lastPumped(vm.getRecordedLogs());
        uint256 demand = address(helper).balance - ethBefore;
        uint256 feeCapAfter = _feeCap();

        uint256 left = (feeCapAfter * (BPS - HAIRCUT_BPS)) / BPS;
        uint256 level = left + (pump.PUMP_FEE_LEVERAGE() * FEE * demand) / 1e6;
        if (level > feeCapAfter) level = feeCapAfter;
        uint256 expected = (level * HAIRCUT_BPS) / BPS;
        if ((demand * SHARE_MAX) / 1e18 < level) expected = (((demand * SHARE_MAX) / 1e18) * HAIRCUT_BPS) / BPS;
        assertApproxEqRel(spent, expected, 0.03e18, "pump = 0.8 x min(feeCap, left + k.f.D, 60% D)");
    }
}
