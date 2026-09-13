// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {ExtBase} from "./ExtBase.sol";
import {IGlueHook} from "../../contracts/interfaces/IGlueHook.sol";
import {IPoolManagerMin, GluedV4Core} from "../../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlockingERC20} from "../mocks/HostileTokens.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title  ExtPAN — Panther skills, transposed to the hook.
 * @notice NOT an official audit: Panther did not review, endorse or sign this suite. It is the hook's
 *         own integration of the firm's PUBLISHED, chain-agnostic DeFi vectors
 *         (`pantheraudits/move-auditor`, `defi/defi-slippage.md` + `defi/defi-math-precision.md`)
 *         transposed to Solidity: DEFI-43/46 (a real, self-referential output floor), DEFI-47 (LP
 *         add settles the exact position amounts), DEFI-36 (rounding to zero on dust), DEFI-37
 *         (decimals: raw units), DEFI-39 (rounding direction: always against the pot), DEFI-38/41
 *         (the uint32 clock across its wrap), DEFI-86 (observation liveness under a failing leg),
 *         DEFI-92 (check and settlement share one value basis), DEFI-35 (share formula exact).
 *         DEFI-44/45 are N/A: the hook takes no user deadline or slippage parameter — every pump is
 *         sized inside the carrying swap's own frame. Check table: audit/external/panther.md.
 */
contract ExtPAN is ExtBase {
    uint256 constant HAIRCUT_BPS = 8_000;
    uint256 constant SHAVE = 1e6;

    /// @dev The pump's spend as {GlueLiquidity.pumpSize} defines it at a FULL bucket and an OPEN gate:
    ///      `floor(min(pot, f·R, 60%·demand) · 80%)`, `R` the tangent reserve on the secondary side.
    function _expectedSpend(bytes32 poolId, uint256 pot, uint256 demand, bool secondaryIsZero)
        internal view returns (uint256 spend)
    {
        GluedV4Core.Slot0 memory s = GluedV4Core.getSlot0(POOL_MANAGER, poolId);
        uint256 depth = GluedV4Core.tangentReserve(
            s.sqrtPriceX96, GluedV4Core.getPoolLiquidity(POOL_MANAGER, poolId), secondaryIsZero
        );
        uint256 feeCap = depth * FEE / 1_000_000;
        uint256 demandCap = demand * pump.PUMP_SHARE_MAX_WAD() / WAD;
        spend = pot;
        if (feeCap < spend) spend = feeCap;
        if (demandCap < spend) spend = demandCap;
        spend = spend * HAIRCUT_BPS / 10_000;
    }

    // ── DEFI-43 / DEFI-46 — output floor ────────────────────────────────────────────

    /// PAN1 — the pump never runs without a floor, and the floor is REAL: `minOut` is the pool's own
    ///        step quote for the spend, shaved by one millionth — tight, self-referential to the pool's
    ///        arithmetic at the same instant, never zero while the spend is not.
    function test_PAN1_floorIsThePoolsOwnQuote() public {
        _donateEth(key, 20 ether);
        (uint256 spend, uint256 minOut) = pump.quotePump(key, 1 ether);
        assertGt(spend, 0);
        assertGt(minOut, 0, "a spend always carries a floor");
        ( , uint256 out) = GluedV4Core.quoteSwapStep(POOL_MANAGER, key, true, -int256(spend));
        assertEq(minOut, out - out / SHAVE, "the floor is the step quote minus 1e-6");
        assertGt(minOut, out * 999_998 / 1_000_000, "and not a decorative one");
    }

    // ── DEFI-47 — LP operation slippage ─────────────────────────────────────────────

    /// PAN2 — the add settles EXACTLY the amounts the liquidity implies at the live price — V4's own
    ///        `getAmount0Delta` / `getAmount1Delta` rounded UP, recomputed here from first principles —
    ///        refunds the native excess to the wei and pulls the token leg to the wei: nothing more,
    ///        nothing left behind.
    function test_PAN2_addSettlesExactPositionAmounts() public {
        uint160 sqrtP = GluedV4Core.getSlot0(POOL_MANAGER, id).sqrtPriceX96;
        uint160 sqrtL = GluedV4Core.getSqrtRatioAtTick(TICK_LO);
        uint160 sqrtU = GluedV4Core.getSqrtRatioAtTick(TICK_HI);
        // amount0 = ceil( ceil(L·2^96·(sqrtU − sqrtP) / sqrtU) / sqrtP ); amount1 = ceil(L·(sqrtP − sqrtL) / 2^96)
        uint256 e0 = Math.ceilDiv(
            Math.mulDiv(uint256(SEED_LIQ) << 96, uint256(sqrtU) - uint256(sqrtP), sqrtU, Math.Rounding.Ceil), sqrtP
        );
        uint256 e1 = Math.mulDiv(SEED_LIQ, uint256(sqrtP) - uint256(sqrtL), GluedV4Core.Q96, Math.Rounding.Ceil);
        uint256 eth = address(this).balance;
        uint256 tok = token.balanceOf(address(this));
        uint256 hookEth = address(pump).balance;

        (uint256 a0, uint256 a1) = _openProgram(_plainCfg(address(this)));

        assertEq(a0, e0, "ETH leg: V4's round-up formula to the wei");
        assertEq(a1, e1, "token leg: same");
        _assertHelperIsTheFloorForm(a0, a1);
        assertEq(eth - address(this).balance, a0, "the excess of the 50 ETH came back to the wei");
        assertEq(tok - token.balanceOf(address(this)), a1, "the token leg pulled to the wei");
        assertEq(address(pump).balance, hookEth, "nothing left on the hook");
    }

    /// @dev The library's own `getAmountsForLiquidity` is the FLOOR form of V4's formula: never above
    ///      the settled (rounded-up) amount, never more than one wei under it, on both legs.
    function _assertHelperIsTheFloorForm(uint256 a0, uint256 a1) internal view {
        (uint256 h0, uint256 h1) = GluedV4Core.getAmountsForLiquidity(
            GluedV4Core.getSlot0(POOL_MANAGER, id).sqrtPriceX96,
            GluedV4Core.getSqrtRatioAtTick(TICK_LO),
            GluedV4Core.getSqrtRatioAtTick(TICK_HI),
            SEED_LIQ
        );
        assertTrue(a0 == h0 || a0 == h0 + 1, "helper amount0 = settled, floor form");
        assertTrue(a1 == h1 || a1 == h1 + 1, "helper amount1 = settled, floor form");
    }

    // ── DEFI-36 — rounding to zero ──────────────────────────────────────────────────

    /// PAN3 — dust: a one-wei buy and a one-wei sell carry no pump (a spend that floors to zero is no
    ///        spend, not a zero-output swap), and leave the pot and the bucket exactly as they were.
    function test_PAN3_dustCarriesNoPump() public {
        _donateEth(key, 20 ether);
        _open();
        uint32 bucket = pump.potOf(id).pumpBucketTimestamp;
        vm.recordLogs();
        _buy(1);
        _sell(1);
        assertEq(_countPumped(vm.getRecordedLogs()), 0, "no pump behind dust");
        assertEq(pump.potOf(id).balance, 20 ether, "pot untouched");
        assertEq(pump.potOf(id).pumpBucketTimestamp, bucket, "bucket untouched");
    }

    // ── DEFI-37 — decimals ──────────────────────────────────────────────────────────

    /// PAN4 — the pump is denominated in RAW secondary units whatever the decimals: on a 6-decimal
    ///        secondary a 1,000-unit pot facing a 1,000-unit demand spends exactly
    ///        `floor(60% · 1e9) · 80% = 4.8e8` raw — the same formula an 18-decimal pot obeys.
    function test_PAN4_rawUnitsWhateverTheDecimals() public {
        MockERC20 main2 = new MockERC20("Main2", "MN2", 18);
        MockERC20 usdc = new MockERC20("USD", "USD", 6);
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openErc20Pool(address(main2), address(usdc), address(0), true);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(pump), MAX);
        pump.donate(k2, 1_000e6);

        (uint256 spend, ) = pump.quotePump(k2, 1_000e6);
        assertEq(spend, 4.8e8, "raw: floor(0.6e9)*0.8");
        assertEq(spend, _expectedSpend(id2, 1_000e6, 1_000e6, address(usdc) < address(main2)), "and the general formula agrees");
    }

    // ── DEFI-39 — rounding direction ────────────────────────────────────────────────

    /// PAN5 — every floor rounds AGAINST the pot: at a full bucket and an open gate the quote equals
    ///        `floor(min(pot, f·R, 60%·demand) · 80%)` exactly — once fee-capped (1 ETH of demand),
    ///        once demand-capped (0.1 ETH), once pot-capped (a 0.01 ETH pot).
    function test_PAN5_spendIsTheFlooredMinimum() public {
        _donateEth(key, 20 ether);
        (uint256 s1, ) = pump.quotePump(key, 1 ether);
        assertEq(s1, _expectedSpend(id, 20 ether, 1 ether, true), "fee-capped");
        (uint256 s2, ) = pump.quotePump(key, 0.1 ether);
        assertEq(s2, _expectedSpend(id, 20 ether, 0.1 ether, true), "demand-capped");
        assertEq(s2, 0.048 ether, "= floor(0.06e18 * 0.8)");

        MockERC20 token2 = new MockERC20("Main2", "MN2", 18);
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openEthPool(address(token2), address(0));
        pump.donate{value: 0.01 ether}(k2, 0.01 ether);
        (uint256 s3, ) = pump.quotePump(k2, 1 ether);
        assertEq(s3, _expectedSpend(id2, 0.01 ether, 1 ether, true), "pot-capped");
        assertEq(s3, 0.008 ether, "= 0.01 * 0.8");
    }

    // ── DEFI-38 / DEFI-41 — the uint32 clock ────────────────────────────────────────

    /// PAN6 — the bucket and the reference live on a wrapping uint32 clock: a pot funded 100 seconds
    ///        before the 2^32 wrap, settled and pumped across it, refills and observes exactly as one
    ///        far from the wrap — a full-size pump on both sides of the wrap, the clock stamped with
    ///        the wrapped timestamp, the gate fully open.
    function test_PAN6_uint32ClockWrapsCleanly() public {
        vm.warp((uint256(1) << 32) - 100);
        vm.roll(block.number + 1);
        _donateEth(key, 20 ether); // seeds the reference just before the wrap
        assertEq(pump.potOf(id).lastTimestamp, uint32((uint256(1) << 32) - 100));

        vm.recordLogs();
        _buy(1 ether); // stamps the bucket before the wrap
        (bool p1, uint256 spent1, ) = _lastPumped(vm.getRecordedLogs());
        assertTrue(p1);

        _open(); // crosses the wrap: block.timestamp > 2^32 now
        assertGt(block.timestamp, uint256(1) << 32);
        (uint256 share, , ) = pump.pumpShareOf(id);
        assertEq(share, pump.PUMP_SHARE_MAX_WAD(), "the reference settled across the wrap: gate open");

        vm.recordLogs();
        _buy(1 ether);
        (bool p2, uint256 spent2, ) = _lastPumped(vm.getRecordedLogs());
        assertTrue(p2);
        assertEq(pump.potOf(id).lastTimestamp, uint32(block.timestamp), "the clock is the wrapped timestamp");
        assertApproxEqRel(spent2, spent1, 0.02e18, "a full-size pump on both sides of the wrap");
    }

    // ── DEFI-86 — accumulator liveness ──────────────────────────────────────────────

    /// PAN7 — a failing pump never blocks the observation: with a MAIN that refuses to be delivered to
    ///        the hook, the pump's self-call reverts and is caught (no `Pumped`, pot undebited), while
    ///        the swap lands and the reference clock and standing tick still advance.
    function test_PAN7_failingPumpKeepsObserving() public {
        BlockingERC20 blocky = new BlockingERC20();
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openEthPool(address(blocky), address(0));
        pump.donate{value: 20 ether}(k2, 20 ether);
        _settleReference(k2);
        _refill();
        blocky.setBlocked(address(pump), true); // the pump's `take` to the hook now reverts

        vm.recordLogs();
        helper.swap(k2, true, -int256(1 ether));
        assertEq(_countPumped(vm.getRecordedLogs()), 0, "the pump failed");
        IGlueHook.Pot memory p = pump.potOf(id2);
        assertEq(p.balance, 20 ether, "and its debit rolled back with it");
        assertEq(p.lastTimestamp, uint32(block.timestamp), "the clock advanced anyway");
        assertEq(p.lastTick, GluedV4Core.getSlot0(POOL_MANAGER, id2).tick, "the standing tick is the swap's");
        assertEq(address(pump).balance, 20 ether, "the hook holds exactly the pot");
    }

    // ── DEFI-92 — check vs settlement value basis ───────────────────────────────────

    /// PAN8 — the pump sizes against the SECONDARY the swap actually moved (read off the delta), never
    ///        against `amountSpecified`: an exact-input sell of 300 MAIN pumps exactly
    ///        `floor(floor(60% · ETH received) · 80%)` — the same basis the quote uses.
    function test_PAN8_settlementUsesTheDeltaBasis() public {
        _donateEth(key, 20 ether);
        _open();
        vm.recordLogs();
        (int256 d0, ) = _sell(300e18);
        uint256 received = uint256(d0);
        (bool pumped, uint256 spent, ) = _lastPumped(vm.getRecordedLogs());
        assertTrue(pumped);
        uint256 expected = (received * pump.PUMP_SHARE_MAX_WAD() / WAD) * HAIRCUT_BPS / 10_000;
        assertEq(spent, expected, "sized on the ETH received, not on the 300e18 specified");
        assertLt(spent, 300e18 * 48 / 100, "and nowhere near a token-denominated reading");
    }

    // ── DEFI-35 — formula exactness ─────────────────────────────────────────────────

    /// PAN9 — the gate's share equals `min(60%, f/d)` computed INDEPENDENTLY from the tick gap the view
    ///        reports (`d = 1.0001^gap − 1` via the sqrt-ratio table), at three premiums.
    function test_PAN9_shareFormulaExact() public {
        _donateEth(key, 20 ether);
        _open();
        uint256[3] memory pushes = [uint256(0.5 ether), 2 ether, 10 ether];
        for (uint256 i; i < 3; ++i) {
            _buy(pushes[i]); // main dearer: spot tick falls below the reference (main is currency1)
            (uint256 share, int24 spot, int24 ref) = pump.pumpShareOf(id);
            int24 gap = ref - spot;
            assertGt(gap, 0, "a premium");
            uint256 sqrtR = GluedV4Core.getSqrtRatioAtTick(gap);
            uint256 ratioWad = (uint256(sqrtR) * uint256(sqrtR) / (1 << 96)) * WAD / (1 << 96);
            uint256 dWad = ratioWad - WAD;
            uint256 expected = uint256(FEE) * WAD * WAD / 1_000_000 / dWad;
            if (expected > pump.PUMP_SHARE_MAX_WAD()) expected = pump.PUMP_SHARE_MAX_WAD();
            assertApproxEqRel(share, expected, 1e12, "f/d from the reported gap");
            assertLt(share, pump.PUMP_SHARE_MAX_WAD(), "gated");
        }
    }

    // ── DEFI-48 — token vs value confusion ──────────────────────────────────────────

    /// PAN10 — both directions denominate the demand in the pot's currency: a buy of main pumps at
    ///         most 48% of the ETH paid, a sell of main at most 48% of the ETH received — never a share
    ///         of the token amount.
    function test_PAN10_demandIsAlwaysSecondary() public {
        _donateEth(key, 20 ether);
        _open();
        vm.recordLogs();
        (int256 b0, ) = _buy(1 ether);
        (bool p1, uint256 s1, ) = _lastPumped(vm.getRecordedLogs());
        assertTrue(p1);
        assertLe(s1, uint256(-b0) * 48 / 100, "buy: <= 48% of the ETH paid");
        _refill();
        vm.recordLogs();
        (int256 d0, ) = _sell(5_000e18);
        (bool p2, uint256 s2, ) = _lastPumped(vm.getRecordedLogs());
        assertTrue(p2);
        assertLe(s2, uint256(d0) * 48 / 100, "sell: <= 48% of the ETH received");
        assertLt(s2, 5_000e18 / 100, "and not a share of the 5,000 tokens sold");
    }
}
