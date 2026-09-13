// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {GlueHookFixture} from "./helpers/GlueHookFixture.sol";
import {IGlueHook} from "../contracts/interfaces/IGlueHook.sol";
import {GluedV4Core, IPoolManagerMin} from "../contracts/libs/GluedV4Core.sol";
import {V4PoolHelper} from "./helpers/V4PoolHelper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {BlockingERC20, ReentrantDonorERC20} from "./mocks/HostileTokens.sol";

/**
 * @title  GlueHookAdversarial — every attack shape the design claims to close, attempted.
 * @notice A1–A14. The pump moves donors' money inside strangers' swaps, so each test here IS one of
 *         the ways a stranger would try to make that money theirs: sell into a rich pot and check
 *         the seller got exactly the hookless twin's price (the pump never touches their trade),
 *         sandwich the pump, push spot before dumping into the pot (the reference gate), wedge
 *         hostile tokens and recipients into the delivery path, and re-enter the funding path
 *         from inside its own token pull, sandwich a stranger's credited full pump, manufacture
 *         volume with no bag, and hold a pushed price across blocks. The full push-and-farm
 *         economics live in {GlueHookMev}.
 */
contract GlueHookAdversarial is GlueHookFixture {
    MockERC20 token;
    IPoolManagerMin.PoolKey key;
    bytes32 id;

    function setUp() public {
        _deployCore();
        token = new MockERC20("Main", "MAIN", 18);
        (key, id) = _openEthPool(address(token), address(0));
    }

    /// A1 — THE PARITY PROOF. A sell into a hooked pool with a RICH pot pays the seller the IDENTICAL
    ///      amount a hookless twin pool would — same currencies, fee, spacing, price and liquidity —
    ///      because the pump runs AFTER the seller's trade, in its own frame, and never touches
    ///      their execution. Each size is measured under a state snapshot and reverted, so both
    ///      pools are always at a bit-identical launch price when they trade. The pump then fires
    ///      behind the sell (spot dipped below the reference: full share) and lifts the price back
    ///      up — but never above where the sell started, since it spends at most 48% of what the
    ///      seller received.
    function test_A1_sellerPaidPoolEquivalent() public {
        IPoolManagerMin.PoolKey memory twin = _openTwinPool(address(token));
        _donateEth(key, 100 ether);

        uint256[3] memory sizes = [uint256(500e18), 7_777e18, 42_000e18];
        for (uint256 i; i < sizes.length; ++i) {
            // Path A: the hooked pool, from the launch price
            uint256 snap = vm.snapshotState();
            uint256 ethBefore = address(helper).balance;
            uint160 priceBefore = _sqrtPrice(id);
            vm.recordLogs();
            helper.swap(key, false, -int256(sizes[i]));
            (bool pumped, uint256 spent, ) = _lastPumped(vm.getRecordedLogs());
            uint256 hookedPayout = address(helper).balance - ethBefore;
            assertTrue(pumped, "the pump fired behind the sell");
            assertLe(spent, (hookedPayout * 48) / 100 + 1, "spending at most 0.8 x 60% of what the seller got");
            // Main is currency1 here, so a dearer main is a LOWER sqrt ratio: the sell lifted the
            // ratio, the pump pulled it back, and it must still sit above where the sell started
            assertGt(_sqrtPrice(id), priceBefore, "so main's price ends below where the sell started");
            vm.revertToState(snap);

            // Path B: the identical sell against the hookless twin, from the identical launch price
            ethBefore = address(helper).balance;
            helper.swap(twin, false, -int256(sizes[i]));
            uint256 twinPayout = address(helper).balance - ethBefore;
            vm.revertToState(snap);

            assertEq(hookedPayout, twinPayout, "the seller got exactly what the hookless pool pays");
        }
    }

    /// A2 — THE PUMP CANNOT BE SANDWICHED ON ITS OWN. The attacker's OWN buy triggers the pump; the
    ///      attacker then sells the whole bag back, trying to farm the pump's price impact. This is the
    ///      attack the fee ceiling `V ≤ f·R` closes: the pump spends at most `0.8·f·R`, so the price
    ///      impact the attacker can recapture is strictly less than the fees they paid to open and
    ///      close the position. Across attacker sizes from dust to pool-scale, the round trip LOSES.
    /// @dev One related surface lives OUTSIDE this test and is written up in AUDIT.md (GH-1): a
    ///      third-party sandwich of an UNRELATED large buy captures a bounded slice of the pump's
    ///      buy pressure — that victim was sandwichable with or without the hook. The other shape
    ///      — pushing spot first and dumping into the pumps the dump itself summons — is what the
    ///      reference gate closes; A3 shows it losing and {GlueHookMev} maps it.
    function test_A2_pumpNotSelfSandwichable() public {
        _donateEth(key, 200 ether); // fat pot, so the fee ceiling (not the pot) binds the pump

        uint256[5] memory legs = [uint256(0.05 ether), 0.5 ether, 2 ether, 8 ether, 40 ether];
        for (uint256 i; i < legs.length; ++i) {
            uint256 snap = vm.snapshotState();

            uint256 ethBefore = address(helper).balance;
            uint256 tokBefore = token.balanceOf(address(helper));

            // The attacker buys — their OWN buy is what carries the pump
            (, int256 gotTok) = helper.swap(key, true, -int256(legs[i]));
            // …then dumps the entire bag back, trying to sell into the pump's price bump
            helper.swap(key, false, -gotTok);

            assertEq(token.balanceOf(address(helper)), tokBefore, "attacker is token-flat");
            assertLe(address(helper).balance, ethBefore,
                "farming the pump with your own buy must lose to fees, at every size");

            vm.revertToState(snap);
        }
    }

    /// A3 — spot manipulation before dumping into the pot buys the attacker nothing. With a rich pot
    ///      funded, the attacker pushes the price up 30 ETH deep, dumps into the pumps their own
    ///      trades summon, and unwinds. Above the reference the gate shrinks the pump's share to
    ///      `f/d`, so what the pumps hand back is less than the fees the push cost — the round
    ///      trip ends token-flat and ETH-NEGATIVE, and the pot spent a bounded sliver of itself.
    function test_A3_spotManipulationLoses() public {
        _donateEth(key, 100 ether);
        uint256 ethBefore = address(helper).balance;
        uint256 tokBefore = token.balanceOf(address(helper));

        // Push: +30 ETH into a 100 ETH pool lifts spot ~69% over the reference
        (, int256 gotTok) = helper.swap(key, true, -int256(30 ether));
        (uint256 share, int24 spot, int24 ref) = pump.pumpShareOf(id);
        // Main is currency1: a dearer main is a LOWER tick, so spot now sits under the reference tick
        assertLt(spot, ref, "main sits above the reference");
        assertLt(share, 0.02e18, "so the gate leaves the pump under 2% of any trade");

        // Dump a slice into the pumped price, then unwind the rest
        helper.swap(key, false, -int256(10_000e18));
        helper.swap(key, false, -(gotTok - int256(10_000e18)));

        assertEq(token.balanceOf(address(helper)), tokBefore, "attacker is token-flat");
        assertLt(address(helper).balance, ethBefore, "and strictly poorer in ETH");
        assertGt(pump.potOf(id).balance, 99 ether, "while the pot gave up under 1% of itself");
    }

    /// A4 — a hostile RECIPIENT cannot brick the venue: a token that blocks the named recipient makes
    ///      the delivery park on the hook (accounted), and the carrying swap still succeeds.
    function test_A4_hostileRecipientParks() public {
        BlockingERC20 blocky = new BlockingERC20();
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openEthPool(address(blocky), address(0));
        address treasury = makeAddr("treasury");
        pump.setRecipient(id2, treasury);
        blocky.setBlocked(treasury, true);

        pump.donate{value: 10 ether}(k2, 10 ether);

        vm.recordLogs();
        helper.swap(k2, true, -int256(1 ether)); // the swap must survive the failed delivery
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool pumped, , uint256 bought) = _lastPumped(logs);
        (bool delivered, address to, uint256 amount, IGlueHook.Delivery mode) = _lastDelivered(logs);
        assertTrue(pumped && delivered, "the pump ran and the delivery resolved");
        assertEq(to, address(pump), "onto the hook itself");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.PARKED), "as a park");
        assertEq(pump.parkedOf(address(blocky)), amount, "fully accounted");
        assertEq(pump.parkedDirectOf(id2), amount, "booked per-pool, retryable via flushDirect");
        assertEq(pump.heldOf(address(blocky)), 0, "but NOT as a burn-park (the intent was delivery)");
        assertEq(blocky.balanceOf(address(pump)), bought, "and the hook really holds it");
    }

    /// A5 — re-entering `donate` from inside the donation's own token pull bounces off the transient
    ///      guard, so a hostile secondary cannot double-credit itself.
    function test_A5_reentrantDonateBlocked() public {
        MockERC20 main2 = new MockERC20("Main2", "MN2", 18);
        ReentrantDonorERC20 rnt = new ReentrantDonorERC20();
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) =
            _openErc20Pool(address(main2), address(rnt), address(0), false);

        rnt.mint(address(this), 100e18);
        rnt.approve(address(pump), type(uint256).max);
        rnt.arm(address(pump), abi.encodeCall(IGlueHook.donate, (k2, 1e18)));

        uint256 credited = pump.donate(k2, 10e18);

        assertTrue(rnt.reentered(), "the token really did attempt the re-entry");
        assertFalse(rnt.reentrySucceeded(), "and the guard rejected it");
        assertEq(credited, 10e18, "the outer donation credited once");
        assertEq(pump.potOf(id2).balance, 10e18, "and the pot booked it once");
    }

    /// A6 — a zero-fee pool can never host a pump: with `f = 0` the sandwich break-even `V > f·R`
    ///      is every V, so the fee ceiling collapses to nothing and the pot simply never spends.
    function test_A6_zeroFeePoolNeverPumps() public {
        MockERC20 zf = new MockERC20("ZeroFee", "ZRF", 18);
        IPoolManagerMin.PoolKey memory k2 = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(zf), fee: 0, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        bytes32 id2 = keccak256(abi.encode(k2));
        IPoolManagerMin(POOL_MANAGER).initialize(k2, LAUNCH_SQRT);
        pump.initPot(k2, address(zf), address(0));
        zf.mint(address(helper), 20_000_000e18);
        helper.addLiquidity(k2, TICK_LO, TICK_HI, _launchLiquidity());

        pump.donate{value: 10 ether}(k2, 10 ether);

        (uint256 spend, ) = pump.quotePump(k2, 5 ether);
        assertEq(spend, 0, "the quote refuses a zero-fee pool");

        vm.recordLogs();
        helper.swap(k2, true, -int256(5 ether));
        (bool pumped, , ) = _lastPumped(vm.getRecordedLogs());
        assertFalse(pumped, "and so does the live path");
        assertEq(pump.potOf(id2).balance, 10 ether, "the pot never spends into a sandwich-open pool");
    }

    /// A7 — a donation that arrives as NOTHING (a 100% fee-on-transfer) is refused outright: no
    ///      zero-credit entries pollute the books.
    function test_A7_hundredPercentFoTDonationRefused() public {
        MockERC20 main2 = new MockERC20("Main2", "MN2", 18);
        MockFeeOnTransferERC20 vampire = new MockFeeOnTransferERC20("Vampire", "VMP", 18, 10_000);
        (IPoolManagerMin.PoolKey memory k2, ) =
            _openErc20Pool(address(main2), address(vampire), address(0), false);

        vampire.mint(address(this), 100e18);
        vampire.approve(address(pump), type(uint256).max);
        vm.expectRevert(IGlueHook.BadDonation.selector);
        pump.donate(k2, 10e18);
    }

    /// A8 — direction discipline: the pump BUYS main behind a buy and behind a sell alike, and never
    ///      sells it. Both directions leave the pot lighter in secondary and the hook's delivery
    ///      ledger heavier in main; the pool's price moves the pump's way (up) relative to where
    ///      the swapper's own trade left it.
    function test_A8_directionDiscipline() public {
        _donateEth(key, 20 ether);

        // Behind a buy
        vm.recordLogs();
        helper.swap(key, true, -int256(1 ether));
        (bool pumpedOnBuy, uint256 spentOnBuy, uint256 boughtOnBuy) = _lastPumped(vm.getRecordedLogs());
        assertTrue(pumpedOnBuy, "the pump fires behind a buy");
        assertGt(spentOnBuy, 0, "spending secondary");
        assertGt(boughtOnBuy, 0, "for main");

        // Behind a sell (a refill later: the bucket, not the direction, is what would stop a second
        // full pump in the same block)
        _refill();
        uint256 potMid = pump.potOf(id).balance;
        vm.recordLogs();
        helper.swap(key, false, -int256(1_000e18));
        (bool pumpedOnSell, uint256 spentOnSell, uint256 boughtOnSell) = _lastPumped(vm.getRecordedLogs());
        assertTrue(pumpedOnSell, "the pump fires behind a sell");
        assertGt(spentOnSell, 0, "spending secondary");
        assertGt(boughtOnSell, 0, "for main");
        assertEq(pump.potOf(id).balance, potMid - spentOnSell, "the pot only ever goes down");
        assertEq(pump.potOf(id).balance, 20 ether - spentOnBuy - spentOnSell, "by exactly what it spent");
    }

    /// A9 — pot isolation: two pools sharing the SAME secondary cannot see each other's money. One
    ///      pot spending to zero leaves the other's balance and the global obligation intact.
    function test_A9_potIsolation() public {
        MockERC20 tokenB = new MockERC20("MainB", "MNB", 18);
        (IPoolManagerMin.PoolKey memory kB, bytes32 idB) = _openEthPool(address(tokenB), address(0));

        _donateEth(key, 0.05 ether); // pot A: thin, will be drained
        _donateEth(kB, 30 ether);    // pot B: fat, must be untouched

        // A sell far larger than pot A: the pot itself binds the pump, and 80% of it goes
        helper.swap(key, false, -int256(60_000e18));
        uint256 potA = pump.potOf(id).balance;
        assertEq(potA, 0.01 ether, "pot A spent 80% of itself (the haircut keeps the rest)");

        assertEq(pump.potOf(idB).balance, 30 ether, "pot B never moved");
        assertEq(pump.obligationOf(ETH), 30 ether + potA, "and the obligation ledger agrees");
        assertGe(address(pump).balance, 30 ether + potA, "with the ETH really there");
    }

    /// A10 — the pump degrades to a no-op, never to a griefing vector: with pool liquidity so thin the
    ///       pump's own swap would be worthless, the buy still lands and the pot is not corrupted.
    function test_A10_pumpFailureNeverBreaksTheBuy() public {
        // A fresh pool with dust liquidity and a pot far larger than the venue
        MockERC20 thin = new MockERC20("Thin", "THN", 18);
        IPoolManagerMin.PoolKey memory k2 = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(thin), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        bytes32 id2 = keccak256(abi.encode(k2));
        IPoolManagerMin(POOL_MANAGER).initialize(k2, LAUNCH_SQRT);
        pump.initPot(k2, address(thin), address(0));
        thin.mint(address(helper), 20_000_000e18);
        helper.addLiquidity(k2, TICK_LO, TICK_HI, 1e6); // dust depth

        pump.donate{value: 50 ether}(k2, 50 ether);

        // The buy must land regardless of what the pump does with a dust pool
        helper.swap(k2, true, -int256(0.001 ether));

        // Whatever happened inside, the books close: balance covers obligation, pot never overdrawn
        assertLe(pump.potOf(id2).balance, 50 ether, "the pot cannot grow from a failed pump");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "the hook covers everything it owes");
    }

    /// A11 — a HARVEST RECIPIENT that re-enters during its own bounded push gets nowhere: the guard
    ///       rejects the re-entry, its receive reverts, the leg books as owed (state was final before
    ///       the send), and the carrying harvest lands. The backlog stays claimable afterwards.
    function test_A11_reentrantHarvestRecipientBooked() public {
        ReentrantHarvester evil = new ReentrantHarvester(pump, key);
        token.mint(address(this), 1_000_000e18);
        token.approve(address(pump), type(uint256).max);
        pump.addLiquidityAdvanced{value: 50 ether}(
            key, TICK_LO, TICK_HI, 1e21, address(this),
            IGlueHook.ProgramConfig({
                buybackShareWad: 0,
                burnShareWad: 0,
                compoundShareWad: 0,
                potCompoundShareWad: 0,
                potBurnShareWad: 0,
                publicHarvest: false,
                secondaryRecipient: address(evil),
                mainRecipient: address(this),
                minMain: type(uint256).max,
                minSecondary: type(uint256).max
            })
        );
        helper.swap(key, true, -int256(5 ether));
        helper.swap(key, false, -int256(4_000e18));

        pump.harvest(key); // the push into `evil` re-enters, reverts, books
        uint256 owed = pump.owedOf(address(evil), ETH);
        assertGt(owed, 0, "the re-entering recipient was booked, not paid");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "and the books cover it");

        // Disarmed, the backlog comes out through the pull path like anybody else's
        evil.disarm();
        vm.prank(address(evil));
        uint256 pulled = pump.claim(ETH);
        assertEq(pulled, owed, "claimable once it behaves");
        assertEq(address(evil).balance, owed, "for real");
    }

    /// A12 — SANDWICHING A STRANGER'S CREDITED PUMP. A victim dumps `depth/k` of main — a sell whose
    ///       volume credit fills the bucket by itself, so a FULL pump (0.8·f·R) rides behind it. The
    ///       attacker buys main just before the victim and sells just after the pump, at sizes from
    ///       dust to pool-scale. Two things make this lose: the pump runs inside the victim's own
    ///       transaction, so the only way to be in front of it is to be in front of the victim's
    ///       DUMP and eat its impact; and the fee ceiling makes the pump's lift worth less than
    ///       `2f` of any attacker leg even on its own. The victim's execution is what it is with or
    ///       without the hook (A1).
    function test_A12_sandwichingACreditedPumpLoses() public {
        _donateEth(key, 200 ether);
        vm.warp(block.timestamp + 1 hours); // bucket full, reference settled at launch
        vm.roll(block.number + 1);
        // The victim trades through its own helper so the two P&Ls never mix
        V4PoolHelper victim = new V4PoolHelper(POOL_MANAGER);
        token.mint(address(victim), 100_000e18);

        uint256[4] memory legs = [uint256(0.1 ether), 2 ether, 10 ether, 40 ether];
        for (uint256 i; i < legs.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 ethBefore = address(helper).balance;
            uint256 tokBefore = token.balanceOf(address(helper));
            uint256 potBefore = pump.potOf(id).balance;

            (, int256 gotTok) = helper.swap(key, true, -int256(legs[i])); // front-run: buy main
            // The victim's dump, carrying a full pump (its own credit refilled the bucket)
            vm.recordLogs();
            victim.swap(key, false, -int256(15_000e18));
            (bool pumped, uint256 spent, ) = _lastPumped(vm.getRecordedLogs());
            helper.swap(key, false, -gotTok); // back-run: sell into the pump's lift

            assertTrue(pumped, "a pump rode behind the victim");
            assertEq(token.balanceOf(address(helper)), tokBefore, "attacker token-flat");
            assertLt(address(helper).balance, ethBefore, "the sandwich of a full pump loses at every size");
            assertLe(spent, potBefore - pump.potOf(id).balance, "the pump is the pot's only spend");
            emit log_named_uint("attacker leg (wei)", legs[i]);
            emit log_named_uint("  sandwich loss (wei)", ethBefore - address(helper).balance);
            emit log_named_uint("  pump behind the victim (wei)", spent);
            vm.revertToState(snap);
        }
    }

    /// A13 — BAG-LESS VOLUME MANUFACTURING. An attacker with NO position runs round trips at the
    ///       reference to drain the pot: each leg credits `k·f` of itself to the bucket and the pump
    ///       behind the buy leg lifts the price the sell leg then enjoys. The pot spends at most
    ///       `k·f × volume` plus the opening bucket, and the attacker gets back under a tenth of the
    ///       fees they paid: the pot is drained only into the pool, at the attacker's expense.
    function test_A13_baglessManufacturingPaysTheAttackerNothing() public {
        _donateEth(key, 100 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        uint256 ethBefore = address(helper).balance;
        uint256 potBefore = pump.potOf(id).balance;
        uint256 volume;
        for (uint256 i; i < 20; ++i) {
            (, int256 got) = helper.swap(key, true, -int256(1 ether));
            uint256 e = address(helper).balance;
            helper.swap(key, false, -got);
            volume += 1 ether + (address(helper).balance - e);
        }
        uint256 potSpent = potBefore - pump.potOf(id).balance;
        uint256 feesPaid = (volume * FEE) / 1e6;
        uint256 loss = ethBefore - address(helper).balance;

        uint256 feeCap;
        {
            GluedV4Core.Slot0 memory s = GluedV4Core.getSlot0(POOL_MANAGER, id);
            feeCap = (GluedV4Core.tangentReserve(
                s.sqrtPriceX96, GluedV4Core.getPoolLiquidity(POOL_MANAGER, id), true
            ) * FEE) / 1e6;
        }
        assertLe(potSpent, feeCap + (pump.PUMP_FEE_LEVERAGE() * feesPaid * 102) / 100,
            "pot spend <= opening bucket + k x fees paid");
        assertGe(loss, (feesPaid * 90) / 100, "the attacker recovered under a tenth of their fees");
        emit log_named_uint("attacker loss (wei)", loss);
        emit log_named_uint("fees paid (wei)", feesPaid);
        emit log_named_uint("pot spent (wei)", potSpent);
    }

    /// A14 — A BLOCK-CONTROLLER HOLDS A PUSHED PRICE. An attacker who can keep spot wherever they
    ///       like for consecutive blocks pushes main +69% and holds it, touching the pool each block
    ///       so the reference observes. After a full τ the gate has reopened only as far as the
    ///       rise cap allowed — ~2,900 ticks of 5,250 — and the share on their trades is still under
    ///       2%; the pot spent on their touches over those ten minutes is a rounding error of itself.
    function test_A14_blockControllerHoldingPriceStaysGated() public {
        _donateEth(key, 100 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        ( , , int24 ref0) = pump.pumpShareOf(id);
        helper.swap(key, true, -int256(30 ether));
        uint256 potAfterPush = pump.potOf(id).balance;

        // Fifty blocks, twelve seconds apart: the controller keeps the price with a dust touch
        for (uint256 b; b < 50; ++b) {
            vm.warp(block.timestamp + 12);
            vm.roll(block.number + 1);
            helper.swap(key, true, -1);
        }
        (uint256 share, , int24 refNow) = pump.pumpShareOf(id);
        uint256 rose = uint256(int256(ref0) - int256(refNow));
        assertLe(rose, 296 * 10 + 1, "the reference rose at most ten minutes of cap");
        // The cap binds until the remaining gap falls to tau's worth of it (2,960 ticks); the EMA
        // takes over for the last few blocks, a hair slower
        assertGe(rose, 2_800, "and it did run at the cap for most of the way");
        assertLt(share, 0.02e18, "still gated under 2% after a full tau of holding (a 26% premium remains)");
        assertLt(potAfterPush - pump.potOf(id).balance, 0.001 ether, "and the hold cost the pot nothing");
    }
}

/// @dev A harvest recipient that re-enters the hook from inside its full-gas push.
contract ReentrantHarvester {
    IGlueHook immutable pump;
    IPoolManagerMin.PoolKey key;
    bool armed = true;

    constructor(IGlueHook p, IPoolManagerMin.PoolKey memory k) {
        pump = p;
        key = k;
    }

    function disarm() external {
        armed = false;
    }

    receive() external payable {
        if (armed) {
            // Any of these would let it double-dip if the guard were absent
            pump.harvest(key);
        }
    }
}
