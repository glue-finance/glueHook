// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {GlueHookFixture} from "./helpers/GlueHookFixture.sol";
import {IGlueHook} from "../contracts/interfaces/IGlueHook.sol";
import {GluedV4Core, IPoolManagerMin} from "../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title  GlueHookDecimals — mixed-decimals ERC20/ERC20 pools, every mechanic.
 * @notice D1–D10. V4 (and this hook) never read `decimals()` — everything is raw units — but nothing
 *         in the campaign proved it end to end until now. These pools launch at a HUMAN 1:1 price
 *         (the raw sqrtPrice carries the whole decimals gap, e.g. ×10¹² between a 6-dec and an
 *         18-dec side), so every assertion doubles as a magnitude proof: a 100-unit buy must come
 *         out as ~100 units of the other token IN ITS OWN SCALE, fee and impact aside. Covered:
 *         the pump behind buys and sells, the exact harvest split (WAD shares over 6-dec raw fee amounts),
 *         the compound mint, the reverse role assignment on an 18/8 pair, and the pump's gate and
 *         bucket in raw units — the tick-only gate under every decimals pair and orientation, the
 *         bucket's ceiling and credit in 8-dec raw, the pace bound in 6-dec raw.
 */
contract GlueHookDecimals is GlueHookFixture {
    uint256 constant PRECISION_ = 1e18;
    /// @dev 1,000,000 human units per side at launch.
    uint256 constant HUMAN_SEED = 1_000_000;

    address carol;
    address dave;

    function setUp() public {
        _deployCore();
        carol = makeAddr("carol");
        dave = makeAddr("dave");
    }

    /* ────────────────────────────── mixed-decimals pool builder ─────────────────────────── */

    /// @dev Open a hooked ERC20/ERC20 pool at a HUMAN 1:1 launch price: the raw price is
    ///      10^(dec1−dec0), so the sqrtPrice soaks up the entire decimals gap. Seeds ~1M human
    ///      units per side and funds the trading helper. Decimal deltas must be even (6/8/18 are).
    function _openMixedPool(MockERC20 main, MockERC20 secondary, address recipient)
        internal
        returns (IPoolManagerMin.PoolKey memory key, bytes32 id)
    {
        (address c0, address c1) = address(main) < address(secondary)
            ? (address(main), address(secondary))
            : (address(secondary), address(main));
        uint8 d0 = MockERC20(c0).decimals();
        uint8 d1 = MockERC20(c1).decimals();

        // human parity: raw1/raw0 = 10^(d1−d0) → √ = 10^(Δ/2) on the right side of Q96
        uint160 sqrtP = d1 >= d0
            ? uint160(GluedV4Core.Q96 * (10 ** (uint256(d1 - d0) / 2)))
            : uint160(GluedV4Core.Q96 / (10 ** (uint256(d0 - d1) / 2)));

        key = IPoolManagerMin.PoolKey({
            currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        id = keccak256(abi.encode(key));
        IPoolManagerMin(POOL_MANAGER).initialize(key, sqrtP);
        pump.initPot(key, address(main), recipient);

        // full-range L implied by 1M human units per side at that price
        uint256 amt0 = HUMAN_SEED * (10 ** uint256(d0));
        uint256 amt1 = HUMAN_SEED * (10 ** uint256(d1));
        uint256 l0 = (amt0 * uint256(sqrtP)) / GluedV4Core.Q96;
        uint256 l1 = (amt1 * GluedV4Core.Q96) / (uint256(sqrtP) - GluedV4Core.MIN_SQRT_RATIO);
        uint128 liq = uint128(l0 < l1 ? l0 : l1);

        _mintTo(c0, address(helper), amt0 * 20);
        _mintTo(c1, address(helper), amt1 * 20);
        helper.addLiquidity(key, TICK_LO, TICK_HI, liq);
    }

    /// @dev The delta the helper received on the MAIN side of a swap.
    function _mainDelta(IPoolManagerMin.PoolKey memory key, address main, int256 d0, int256 d1)
        internal pure returns (int256)
    {
        return main == key.currency0 ? d0 : d1;
    }

    /// @dev The LAST `Harvested` in a recorded window, or `found = false`.
    function _lastHarvested(Vm.Log[] memory logs)
        internal view
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
    function _lastCompounded(Vm.Log[] memory logs)
        internal view
        returns (bool found, uint128 liq, uint256 u0, uint256 u1)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pump)) continue;
            if (logs[i].topics[0] != keccak256("Compounded(bytes32,uint128,uint256,uint256)")) continue;
            found = true;
            (liq, u0, u1) = abi.decode(logs[i].data, (uint128, uint256, uint256));
        }
    }

    /* ───────────────────────────────────────── tests ────────────────────────────────────── */

    /// D1 — 6-dec main vs 18-dec secondary: a 100-unit buy delivers ~100 main units IN 6-DEC RAW
    ///      (human parity survives the decimals gap), and the pump fires alongside it, delivering
    ///      6-dec main to the recipient and debiting the pot by exactly what it spent.
    function test_D1_pumpOn6dec18decPool() public {
        MockERC20 usd6 = new MockERC20("Six", "USD6", 6);
        MockERC20 w18 = new MockERC20("Wide", "W18", 18);
        (IPoolManagerMin.PoolKey memory key, bytes32 id) = _openMixedPool(usd6, w18, carol);

        // fund the pot with the 18-dec secondary
        w18.mint(address(this), 100_000e18);
        w18.approve(address(pump), type(uint256).max);
        pump.donate(key, 1_000e18);
        assertEq(pump.potOf(id).balance, 1_000e18, "pot holds the raw 18-dec donation");

        // buy 100 human units of main with 100e18 secondary
        bool secIsZero = address(w18) == key.currency0;
        vm.recordLogs();
        (int256 d0, int256 d1) = helper.swap(key, secIsZero, -int256(100e18));
        int256 got = _mainDelta(key, address(usd6), d0, d1);

        // MAGNITUDE: ~100 units in 6-dec raw — fee (0.30%) + impact (~0.01%) only
        assertGt(got, int256(99e6), "human parity held in 6-dec raw");
        assertLt(got, int256(100e6), "fee was charged");

        (bool pumped, uint256 spent, uint256 bought) = _lastPumped(vm.getRecordedLogs());
        assertTrue(pumped, "the pump fired");
        assertLe(spent, (100e18 * 8) / 10, "spend capped at 80% of the carrying buy");
        assertEq(pump.potOf(id).balance, 1_000e18 - spent, "pot debited exactly its spend");
        assertEq(usd6.balanceOf(carol), bought, "recipient received the bought 6-dec main");
        assertGt(bought, 0, "the pump bought real units");
    }

    /// D2 — same pool, the SELL side: the pump fires BEHIND a 6-dec main sell (the dip sits below
    ///      the reference, full share), the seller's 18-dec proceeds keep human parity untouched,
    ///      the spend is capped at 48% of what the seller received, and the bought main lands with
    ///      the recipient.
    function test_D2_pumpBehindSellOn6dec18decPool() public {
        MockERC20 usd6 = new MockERC20("Six", "USD6", 6);
        MockERC20 w18 = new MockERC20("Wide", "W18", 18);
        (IPoolManagerMin.PoolKey memory key, bytes32 id) = _openMixedPool(usd6, w18, carol);

        w18.mint(address(this), 100_000e18);
        w18.approve(address(pump), type(uint256).max);
        pump.donate(key, 5_000e18);

        // sell 100 human units of the 6-dec main
        bool mainIsZero = address(usd6) == key.currency0;
        uint256 potBefore = pump.potOf(id).balance;
        vm.recordLogs();
        (int256 d0, int256 d1) = helper.swap(key, mainIsZero, -int256(100e6));
        int256 gotSec = mainIsZero ? d1 : d0;

        // MAGNITUDE: ~100 units in 18-dec raw
        assertGt(gotSec, int256(99e18), "human parity held in 18-dec raw");
        assertLt(gotSec, int256(100e18), "fee was charged");

        (bool pumped, uint256 spent, uint256 bought) = _lastPumped(vm.getRecordedLogs());
        assertTrue(pumped, "the pump fired behind the sell");
        assertGt(bought, 0, "buying real 6-dec units");
        assertLe(spent, (uint256(gotSec) * 48) / 100 + 1, "spend capped at 0.8 x 60% of the seller's proceeds");
        assertEq(pump.potOf(id).balance, potBefore - spent, "pot debited exactly what it spent");
        assertEq(usd6.balanceOf(carol), bought, "recipient received the bought main");
    }

    /// D3 — exact harvest split over MIXED-decimals fees: WAD shares over a 6-dec raw fee amount
    ///      must be exactly conservative — burn + recipient legs reassemble the main-side fees
    ///      byte-for-byte, fuel + recipient legs the 18-dec secondary side.
    function test_D3_exactSplitMixedDecimals() public {
        MockERC20 usd6 = new MockERC20("Six", "USD6", 6);
        MockERC20 w18 = new MockERC20("Wide", "W18", 18);
        (IPoolManagerMin.PoolKey memory key, bytes32 id) = _openMixedPool(usd6, w18, carol);

        usd6.mint(address(this), 10_000_000e6);
        w18.mint(address(this), 10_000_000e18);
        usd6.approve(address(pump), type(uint256).max);
        w18.approve(address(pump), type(uint256).max);

        pump.addLiquidityAdvanced(
            key, TICK_LO, TICK_HI, uint128(1e17), address(this),
            IGlueHook.ProgramConfig({
                buybackShareWad: uint64(4e17), // 40% of secondary fees → pot
                burnShareWad: uint64(25e16), // 25% of main fees → cascade (dead, for a mock)
                compoundShareWad: 0,
                potCompoundShareWad: 0,
                potBurnShareWad: 0,
                publicHarvest: false,
                secondaryRecipient: carol,
                mainRecipient: dave,
                minMain: type(uint256).max,
                minSecondary: type(uint256).max
            })
        );

        // trade both directions so BOTH fee sides accrue
        bool mainIsZero = address(usd6) == key.currency0;
        helper.swap(key, !mainIsZero, -int256(5_000e18));
        helper.swap(key, mainIsZero, -int256(4_000e6));

        uint256 potBefore = pump.potOf(id).balance;
        uint256 carolBefore = w18.balanceOf(carol);
        uint256 daveBefore = usd6.balanceOf(dave);
        uint256 deadBefore = usd6.balanceOf(DEAD);

        vm.recordLogs();
        pump.harvest(key);
        (bool found, uint256 fMain, uint256 fSec, uint256 burned, uint256 fueled) =
            _lastHarvested(vm.getRecordedLogs());

        assertTrue(found, "the harvest ran");
        assertGt(fMain, 0, "6-dec main fees accrued");
        assertGt(fSec, 0, "18-dec secondary fees accrued");
        // the WAD split is exact in each side's own raw scale
        assertEq(fueled, (fSec * 4e17) / PRECISION_, "buyback leg exact on the 18-dec side");
        assertEq(burned, (fMain * 25e16) / PRECISION_, "burn leg exact on the 6-dec side");
        assertEq(pump.potOf(id).balance - potBefore, fueled, "pot credited the fuel");
        assertEq(w18.balanceOf(carol) - carolBefore, fSec - fueled, "carol got the exact 18-dec remainder");
        assertEq(usd6.balanceOf(dave) - daveBefore, fMain - burned, "dave got the exact 6-dec remainder");
        assertEq(usd6.balanceOf(DEAD) - deadBefore, burned, "the cascade parked the burn at dead");
    }

    /// D4 — the compound mint on a mixed-decimals pool: the compound share of both raw scales
    ///      funds a real position mint and the program's liquidity grows.
    function test_D4_compoundMixedDecimals() public {
        MockERC20 usd6 = new MockERC20("Six", "USD6", 6);
        MockERC20 w18 = new MockERC20("Wide", "W18", 18);
        (IPoolManagerMin.PoolKey memory key, bytes32 id) = _openMixedPool(usd6, w18, carol);

        usd6.mint(address(this), 10_000_000e6);
        w18.mint(address(this), 10_000_000e18);
        usd6.approve(address(pump), type(uint256).max);
        w18.approve(address(pump), type(uint256).max);

        pump.addLiquidityAdvanced(
            key, TICK_LO, TICK_HI, uint128(1e17), address(this),
            IGlueHook.ProgramConfig({
                buybackShareWad: 0,
                burnShareWad: 0,
                compoundShareWad: uint64(5e17), // 50% of both sides re-invested
                potCompoundShareWad: 0,
                potBurnShareWad: 0,
                publicHarvest: false,
                secondaryRecipient: carol,
                mainRecipient: dave,
                minMain: type(uint256).max,
                minSecondary: type(uint256).max
            })
        );

        bool mainIsZero = address(usd6) == key.currency0;
        helper.swap(key, !mainIsZero, -int256(5_000e18));
        helper.swap(key, mainIsZero, -int256(4_000e6));

        uint128 liqBefore = pump.programOf(id).liquidity;
        vm.recordLogs();
        pump.harvest(key);
        (bool compounded, uint128 minted, uint256 u0, uint256 u1) = _lastCompounded(vm.getRecordedLogs());

        assertTrue(compounded, "the compound minted");
        assertGt(minted, 0, "real liquidity out of mixed-decimals fees");
        assertGt(u0 + u1, 0, "the mint consumed raw fee amounts");
        assertEq(pump.programOf(id).liquidity, liqBefore + minted, "the program's position grew");
    }

    /// D5 — roles reversed on an 18/8 pair: an 18-dec MAIN defended with an 8-dec secondary. The
    ///      pump buys 18-dec main with 8-dec fuel and delivers it; magnitudes hold in both scales.
    function test_D5_reverseRoles18dec8dec() public {
        MockERC20 w18 = new MockERC20("Wide", "W18", 18);
        MockERC20 oct8 = new MockERC20("Oct", "OCT8", 8);
        (IPoolManagerMin.PoolKey memory key, bytes32 id) = _openMixedPool(w18, oct8, carol);

        // the pot holds the 8-dec secondary
        oct8.mint(address(this), 100_000e8);
        oct8.approve(address(pump), type(uint256).max);
        pump.donate(key, 1_000e8);

        // buy 100 human units of the 18-dec main with the 8-dec secondary
        bool secIsZero = address(oct8) == key.currency0;
        vm.recordLogs();
        (int256 d0, int256 d1) = helper.swap(key, secIsZero, -int256(100e8));
        int256 got = _mainDelta(key, address(w18), d0, d1);

        assertGt(got, int256(99e18), "human parity held in 18-dec raw");
        assertLt(got, int256(100e18), "fee was charged");

        (bool pumped, uint256 spent, uint256 bought) = _lastPumped(vm.getRecordedLogs());
        assertTrue(pumped, "the pump fired on the 8-dec fuel");
        assertEq(pump.potOf(id).balance, 1_000e8 - spent, "8-dec pot debited exactly");
        assertEq(w18.balanceOf(carol), bought, "recipient received the 18-dec main");
        assertGt(bought, 0, "the pump bought real 18-dec units");
    }

    /// D6 — pot solvency across a mixed-decimals trading burst: after donations, pumps both ways and
    ///      a harvest, the hook's raw token balance covers the pot ledger exactly (no decimals
    ///      confusion between an 18-dec book and a 6-dec book).
    function test_D6_potSolvencyMixedDecimals() public {
        MockERC20 usd6 = new MockERC20("Six", "USD6", 6);
        MockERC20 w18 = new MockERC20("Wide", "W18", 18);
        (IPoolManagerMin.PoolKey memory key, bytes32 id) = _openMixedPool(usd6, w18, carol);

        usd6.mint(address(this), 10_000_000e6);
        w18.mint(address(this), 10_000_000e18);
        usd6.approve(address(pump), type(uint256).max);
        w18.approve(address(pump), type(uint256).max);
        pump.donate(key, 2_500e18);

        pump.addLiquidityAdvanced(
            key, TICK_LO, TICK_HI, uint128(1e17), address(this),
            IGlueHook.ProgramConfig({
                buybackShareWad: uint64(3e17),
                burnShareWad: uint64(2e17),
                compoundShareWad: uint64(3e17),
                potCompoundShareWad: 0,
                potBurnShareWad: 0,
                publicHarvest: true,
                secondaryRecipient: carol,
                mainRecipient: dave,
                minMain: 1,
                minSecondary: 1
            })
        );

        bool mainIsZero = address(usd6) == key.currency0;
        for (uint256 i; i < 5; ++i) {
            helper.swap(key, !mainIsZero, -int256(2_000e18));
            helper.swap(key, mainIsZero, -int256(1_500e6));
        }
        pump.harvest(key);

        // every raw unit the hook holds in the pot's currency covers the pot ledger
        assertGe(
            w18.balanceOf(address(pump)),
            pump.potOf(id).balance,
            "the 18-dec pot is fully backed by raw balance"
        );
    }

    /* ─────────────────────────── the gate and the bucket, in raw units ──────────────────── */

    /// @dev Main's premium over the reference in WAD from the gate's own ticks, oriented by which
    ///      side main sits on (currency0: dearer main = higher tick; currency1: lower) and rounded
    ///      to the strict side exactly as the gate does.
    function _premiumWad(bytes32 id, bool mainIsZero) internal view returns (uint256) {
        ( , int24 spot, int24 ref) = pump.pumpShareOf(id);
        IGlueHook.Pot memory p = pump.potOf(id);
        int256 gap;
        if (mainIsZero) {
            gap = int256(spot) - int256(ref); // floor of the reference: the strict side here
        } else {
            int256 refC = int256(ref);
            if (p.referenceTickX8 & 0xFF != 0) ++refC;
            gap = refC - int256(spot);
        }
        if (gap <= 0) return 0;
        uint256 sq = GluedV4Core.getSqrtRatioAtTick(int24(gap));
        return (((sq * sq) / GluedV4Core.Q96) * 1e18) / GluedV4Core.Q96 - 1e18;
    }

    /// @dev The fee ceiling on the SECONDARY side of a pool, in the secondary's raw units.
    function _feeCapOf(bytes32 id, bool secIsZero) internal view returns (uint256) {
        GluedV4Core.Slot0 memory s = GluedV4Core.getSlot0(POOL_MANAGER, id);
        return (GluedV4Core.tangentReserve(
            s.sqrtPriceX96, GluedV4Core.getPoolLiquidity(POOL_MANAGER, id), secIsZero
        ) * FEE) / 1e6;
    }

    /// D7 — THE GATE IS DECIMALS-BLIND. On a 6-dec main / 18-dec secondary pool, pushes of 1%, 10%
    ///      and 40% of the human depth lift main a premium the gate reads from TICKS alone: the
    ///      share is `min(60%, f/d)` to the tick whichever side of the key main landed on, and the
    ///      same push on the reversed 18/8 pair reads the same share.
    function test_D7_gateShareMixedDecimalsBothOrientations() public {
        (IPoolManagerMin.PoolKey memory kA, bytes32 idA, bool mainIsZeroA) = _fundedPool(6, 18);
        (IPoolManagerMin.PoolKey memory kB, bytes32 idB, bool mainIsZeroB) = _fundedPool(18, 8);

        uint256[3] memory humanPushes = [uint256(10_000), 100_000, 400_000]; // of 1M human depth
        for (uint256 i; i < humanPushes.length; ++i) {
            uint256 snap = vm.snapshotState();
            (uint256 shareA, uint256 dA) = _pushAndCheck(kA, idA, mainIsZeroA, humanPushes[i] * 1e18);
            (uint256 shareB, ) = _pushAndCheck(kB, idB, mainIsZeroB, humanPushes[i] * 1e8);
            // The same human push reads (nearly) the same premium and share on both pools
            assertApproxEqRel(shareA, shareB, 0.02e18, "decimals do not enter the gate");
            emit log_named_uint("human push (units)", humanPushes[i]);
            emit log_named_uint("  premium 6/18 (bps)", dA / 1e14);
            emit log_named_uint("  share 6/18 (bps)", shareA / 1e14);
            emit log_named_uint("  share 18/8 (bps)", shareB / 1e14);
            vm.revertToState(snap);
        }
    }

    /// @dev A hooked pool with a `dm`-dec main and a `ds`-dec secondary, its pot funded with 1,000
    ///      human units of secondary.
    function _fundedPool(uint8 dm, uint8 ds)
        internal returns (IPoolManagerMin.PoolKey memory key, bytes32 id, bool mainIsZero)
    {
        MockERC20 main = new MockERC20("M", "M", dm);
        MockERC20 sec = new MockERC20("S", "S", ds);
        (key, id) = _openMixedPool(main, sec, carol);
        sec.mint(address(this), 10_000_000 * (10 ** uint256(ds)));
        sec.approve(address(pump), type(uint256).max);
        pump.donate(key, 1_000 * (10 ** uint256(ds)));
        mainIsZero = address(main) == key.currency0;
    }

    /// @dev Buy main with `secIn` raw secondary, then check the gate's share against `min(60%, f/d)`
    ///      from the ticks it read. Returns the share and the premium.
    function _pushAndCheck(IPoolManagerMin.PoolKey memory key, bytes32 id, bool mainIsZero, uint256 secIn)
        internal returns (uint256 share, uint256 d)
    {
        helper.swap(key, !mainIsZero, -int256(secIn));
        (share, , ) = pump.pumpShareOf(id);
        d = _premiumWad(id, mainIsZero);
        assertLe(share, 0.6e18, "never above the maximum");
        if (d == 0) {
            assertEq(share, 0.6e18, "at or below the reference: whole");
        } else {
            uint256 expected = (uint256(FEE) * 1e12 * 1e18) / d;
            if (expected > 0.6e18) expected = 0.6e18;
            assertApproxEqRel(share, expected, 1e14, "share = min(60%, f/d) from ticks");
        }
    }

    /// D8 — THE BUCKET IN RAW UNITS, 8-dec secondary. On the 18-dec main / 8-dec secondary pool the
    ///      pot, the fee ceiling and the volume credit are all 8-dec raw: a first dip drains the
    ///      bucket with a pump of 0.8·f·R (in 8-dec raw), a second smaller dip in the same block
    ///      gets 0.8·(what was left + k·f·D), and a dip of depth/k refills it for a full pump again.
    function test_D8_bucketCreditRaw8dec() public {
        MockERC20 w18 = new MockERC20("Wide", "W18", 18);
        MockERC20 oct8 = new MockERC20("Oct", "OCT8", 8);
        (IPoolManagerMin.PoolKey memory key, bytes32 id) = _openMixedPool(w18, oct8, carol);
        oct8.mint(address(this), 10_000_000e8);
        oct8.approve(address(pump), type(uint256).max);
        pump.donate(key, 1_000_000e8); // a rich pot: only the ceilings bind
        bool mainIsZero = address(w18) == key.currency0;
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);

        // 1. A dip of 8,000 human units (60% of its proceeds exceeds f·R): full pump, 8-dec raw
        vm.recordLogs();
        helper.swap(key, mainIsZero, -int256(8_000e18));
        ( , uint256 first, ) = _lastPumped(vm.getRecordedLogs());
        uint256 feeCap = _feeCapOf(id, !mainIsZero);
        assertApproxEqRel(first, (feeCap * 8) / 10, 0.02e18, "first dip: 80% of f.R in 8-dec raw");
        assertGt(first, 1e8, "and that is real 8-dec money (> 1 unit)");
        assertLt(first, 10_000e8, "of the right magnitude (0.3% of ~1M)");

        // 2. A smaller dip (2,000 units, still over the demand ceiling): what was left plus its
        //    own credit
        uint256 left = feeCap - first;
        uint256 secBefore = oct8.balanceOf(address(helper));
        vm.recordLogs();
        helper.swap(key, mainIsZero, -int256(2_000e18));
        ( , uint256 second, ) = _lastPumped(vm.getRecordedLogs());
        uint256 demand = oct8.balanceOf(address(helper)) - secBefore;
        uint256 level = left + (pump.PUMP_FEE_LEVERAGE() * FEE * demand) / 1e6;
        assertApproxEqRel(second, (level * 8) / 10, 0.03e18, "second dip: 80% of (left + k.f.D), 8-dec raw");

        // 3. A dip of depth/k human units refills the bucket by itself
        uint256 depth = (_feeCapOf(id, !mainIsZero) * 1e6) / FEE;
        uint256 bigHuman = (depth / pump.PUMP_FEE_LEVERAGE()) / 1e8 + 1_000; // in human units, a margin
        vm.recordLogs();
        helper.swap(key, mainIsZero, -int256(bigHuman * 1e18));
        ( , uint256 third, ) = _lastPumped(vm.getRecordedLogs());
        assertApproxEqRel(third, (_feeCapOf(id, !mainIsZero) * 8) / 10, 0.03e18, "a depth/k dip: full pump again");
    }

    /// D9 — THE PACE IN 6-DEC RAW. An 18-dec main defended with a 6-dec secondary: thirty 1,000-unit
    ///      round trips a minute apart spend at most `k·f·volume + f·R·(1 + 30min/PUMP_REFILL)`, every
    ///      term in 6-dec raw, and the live quote for a trade matches the pump it carries.
    function test_D9_paceBoundRaw6dec() public {
        MockERC20 w18 = new MockERC20("Wide", "W18", 18);
        MockERC20 usd6 = new MockERC20("Six", "USD6", 6);
        (IPoolManagerMin.PoolKey memory key, bytes32 id) = _openMixedPool(w18, usd6, carol);
        usd6.mint(address(this), 10_000_000e6);
        usd6.approve(address(pump), type(uint256).max);
        pump.donate(key, 500_000e6);
        bool mainIsZero = address(w18) == key.currency0;
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);

        // The quote for a 1,000-unit buy equals the pump it carries (to the post-swap depth)
        (uint256 quoted, ) = pump.quotePump(key, 1_000e6);
        vm.recordLogs();
        helper.swap(key, !mainIsZero, -int256(1_000e6));
        ( , uint256 live, ) = _lastPumped(vm.getRecordedLogs());
        assertApproxEqRel(quoted, live, 0.02e18, "quote = live pump, 6-dec raw");

        uint256 potBefore = pump.potOf(id).balance;
        uint256 feeCap = _feeCapOf(id, !mainIsZero);
        uint256 volume;
        for (uint256 i; i < 30; ++i) {
            vm.warp(block.timestamp + 1 minutes);
            vm.roll(block.number + 1);
            uint256 s0 = usd6.balanceOf(address(helper));
            (int256 d0, int256 d1) = helper.swap(key, !mainIsZero, -int256(1_000e6));
            int256 got = _mainDelta(key, address(w18), d0, d1);
            helper.swap(key, mainIsZero, -got);
            volume += 1_000e6 + (usd6.balanceOf(address(helper)) + 1_000e6 - s0);
        }
        uint256 spent = potBefore - pump.potOf(id).balance;
        uint256 bound_ = (pump.PUMP_FEE_LEVERAGE() * FEE * volume) / 1e6 + feeCap
            + (feeCap * 30 minutes) / pump.PUMP_REFILL();
        assertLe(spent, bound_ + bound_ / 50, "pace bound holds in 6-dec raw");
        assertGt(spent, bound_ / 2, "and the pace was used");
        assertGe(usd6.balanceOf(address(pump)), pump.potOf(id).balance, "6-dec pot fully backed");
    }

    /// D10 — the gate under FUZZED decimals and orientation: any (6|8|18)-dec main against any
    ///       (6|8|18)-dec secondary, either side of the key, any push — the share is `min(60%, f/d)`
    ///       from ticks and never above the maximum.
    function testFuzz_D10_gateShareAnyDecimals(uint8 dm, uint8 ds, uint256 push) public {
        uint8[3] memory decs = [uint8(6), 8, 18];
        dm = decs[dm % 3];
        ds = decs[ds % 3];
        push = bound(push, 1, 600_000); // human units of secondary, against 1M of depth
        (IPoolManagerMin.PoolKey memory key, bytes32 id, bool mainIsZero) = _fundedPool(dm, ds);
        _pushAndCheck(key, id, mainIsZero, push * (10 ** uint256(ds)));
    }

}
