// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {ExtBase, ProbeRecipient, ProbeEngine} from "./ExtBase.sol";
import {V4PoolHelper} from "../helpers/V4PoolHelper.sol";
import {IGlueHook} from "../../contracts/interfaces/IGlueHook.sol";
import {IPoolManagerMin, GluedV4Core} from "../../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlockingERC20} from "../mocks/HostileTokens.sol";

/**
 * @title  ExtQS — QuillShield skills, transposed to the hook.
 * @notice NOT an official audit: QuillShield did not review, endorse or sign this suite. It is the
 *         hook's own integration of the firm's PUBLISHED skills (`quillai-network/quillshield_skills`):
 *         semantic-guard analysis (the guard every value-moving entry applies, exercised from the
 *         two callback channels a stranger can own), reentrancy-pattern analysis (cross-function,
 *         cross-contract through the PoolManager, read-only), oracle & flash-loan analysis (the
 *         in-hook reference under a same-block push), input & arithmetic safety (share caps,
 *         floors), external-call safety (bounded pushes, pull payments), state-invariant detection
 *         (the obligation identity) and DoS & griefing (force-feeding, under-gassed swaps).
 *         Check table: audit/external/quillshield.md.
 */
contract ExtQS is ExtBase {
    bytes4 constant MANAGER_LOCKED = bytes4(keccak256("ManagerLocked()"));

    ProbeEngine engine;

    /// @dev Register `engine` on the Stick and let it launch the fixture pool's program as a NATIVE
    ///      one (three steps, engine as pot admin), armed at 1 wei so every swap harvests.
    function _nativeProgram(IPoolManagerMin.PoolKey memory k, bytes32 poolId, address main, bool armed) internal {
        engine = new ProbeEngine(pump, POOL_MANAGER);
        stick.setRegisteredEngine(address(engine), true);
        vm.deal(address(engine), 1_000 ether);
        MockERC20(main).mint(address(engine), 10_000_000e18);
        engine.exec(main, abi.encodeCall(MockERC20(main).approve, (address(pump), MAX)));
        engine.setPool(k, poolId);
        engine.exec(POOL_MANAGER, abi.encodeCall(IPoolManagerMin.initialize, (k, LAUNCH_SQRT)));
        engine.exec(address(pump), abi.encodeCall(IGlueHook.initPot, (k, main, address(0))));
        uint256 mins = armed ? 1 : MAX;
        engine.exec{value: 60 ether}(
            address(pump),
            abi.encodeCall(
                IGlueHook.addLiquidityAdvanced,
                (k, TICK_LO, TICK_HI, SEED_LIQ, address(engine), _cfg(0, 0, 0, address(engine), address(engine), mins, mins))
            )
        );
        MockERC20(main).mint(address(helper), 20_000_000e18);
    }

    /// @dev A fresh key the engine can initialise (the fixture pool is already initialised by the test).
    function _freshKey() internal returns (IPoolManagerMin.PoolKey memory k, bytes32 poolId, MockERC20 main) {
        main = new MockERC20("Native", "NAT", 18);
        k = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(main), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        poolId = keccak256(abi.encode(k));
    }

    // ── semantic-guard analysis ─────────────────────────────────────────────────────

    /// QS1 — the consistency principle: every value-moving entry carries the same guard. From the
    ///       one channel a stranger can own with real gas (the full-gas native report) the engine re-enters
    ///       `donate`, `claim`, `flushDirect`, `harvest`, `addProgramLiquidity`, `removeProgramLiquidity`
    ///       and the PoolManager's own `swap`: inside a carrying swap all seven answer `Reentrancy`
    ///       (the manager wraps the hook's), from a manual harvest the six hook doors answer
    ///       `Reentrancy` and the manager itself is `ManagerLocked`. The report completes anyway.
    function test_QS1_everyDoorIsGuarded() public {
        (IPoolManagerMin.PoolKey memory k, bytes32 poolId, MockERC20 main) = _freshKey();
        _nativeProgram(k, poolId, address(main), true);
        engine.setMode(ProbeEngine.Mode.Matrix);

        // inside a swap
        helper.swap(k, true, -int256(1 ether));
        assertEq(engine.calls(), 1, "the report fired");
        for (uint256 i; i < 7; ++i) {
            assertEq(engine.answers(i), IGlueHook.Reentrancy.selector, "in-swap: every door is Reentrancy");
        }

        // from a manual harvest
        helper.swap(k, false, -int256(1_000e18)); // accrues (and reports once more)
        engine.setMode(ProbeEngine.Mode.Record); // the in-swap report of that sell should not run the matrix
        helper.swap(k, true, -int256(0.5 ether)); // pending fees for the manual harvest below
        engine.setMode(ProbeEngine.Mode.Matrix);
        // Everything pending was auto-harvested; disarm and accrue, so the manual harvest has legs
        engine.exec(
            address(pump),
            abi.encodeCall(IGlueHook.setProgramConfig, (poolId, _cfg(0, 0, 0, address(engine), address(engine), MAX, MAX)))
        );
        helper.swap(k, true, -int256(1 ether));
        uint256 callsBefore = engine.calls();
        engine.exec(address(pump), abi.encodeCall(IGlueHook.harvest, (k)));
        assertEq(engine.calls(), callsBefore + 1, "the manual harvest reported");
        for (uint256 i; i < 6; ++i) {
            assertEq(engine.answers(i), IGlueHook.Reentrancy.selector, "manual: every hook door is Reentrancy");
        }
        assertEq(engine.answers(6), MANAGER_LOCKED, "manual: the manager is simply locked");
    }

    // ── reentrancy-pattern analysis ─────────────────────────────────────────────────

    /// QS2 — read-only reentrancy: what a receiver sees mid-frame is never insolvent. A native
    ///       recipient paid at the swap's gas observes `hook.balance >= obligation` while its leg
    ///       is in flight; the native engine observes, at report time, the ledger already advanced
    ///       to its final value, the pot at its final balance, and the same solvency.
    function test_QS2_readOnlyReentrancySeesSolventBooks() public {
        // (a) the push channel
        ProbeRecipient probe = new ProbeRecipient(pump);
        probe.setMode(ProbeRecipient.Mode.Observe);
        _openProgram(_cfg(uint64(WAD / 2), 0, 0, address(probe), alice, 1, 1));
        _donateEth(key, 10 ether);
        _open();
        _buy(2 ether);
        (bool hit, uint256 bal, uint256 obl) = probe.observed();
        assertTrue(hit, "the probe ran inside the push");
        assertGe(bal, obl, "mid-frame: balance covers the obligation");
        assertGt(address(probe).balance, 0, "and the leg landed");
        assertEq(pump.owedOf(address(probe), ETH), 0, "nothing was booked: the push went through");

        // (b) the report channel
        (IPoolManagerMin.PoolKey memory k, bytes32 poolId, MockERC20 main) = _freshKey();
        _nativeProgram(k, poolId, address(main), true);
        engine.setMode(ProbeEngine.Mode.Observe);
        helper.swap(k, true, -int256(1 ether));
        assertEq(engine.calls(), 1);
        assertGe(engine.obsHookBalance(), engine.obsObligation(), "report-time: solvent");
        assertEq(engine.obsDeliveredSec(), pump.deliveredCumOf(poolId, ETH), "ledger already final at report time");
        assertEq(engine.obsDeliveredSec(), engine.lastSec(), "and equal to what was reported");
        assertEq(engine.obsPotBalance(), pump.potOf(poolId).balance, "pot already final at report time");
        assertEq(engine.obsOwedSec(), 0, "nothing owed: the push landed");
    }

    // ── oracle & flash-loan analysis ────────────────────────────────────────────────

    /// QS3 — the reference is the hook's own time-weighted tick: a same-block flash push cannot move
    ///       it, the gate after the push is `f/d` (under 1% for a 30% push), and the push-then-dump
    ///       round trip loses money.
    function test_QS3_flashPushCannotMoveTheReference() public {
        _donateEth(key, 20 ether);
        _open();
        int32 refBefore = pump.potOf(id).referenceTickX8;
        uint256 helperEth = address(helper).balance;
        uint256 helperTok = token.balanceOf(address(helper));

        (, int256 d1) = _buy(30 ether); // the push
        (uint256 share, , ) = pump.pumpShareOf(id);
        assertLt(share, 0.01e18, "the gate reads the premium: under 1%");
        _sell(uint256(d1)); // the dump of exactly what was bought
        assertEq(pump.potOf(id).referenceTickX8, refBefore, "the reference never moved in the block");
        assertLt(address(helper).balance, helperEth, "the round trip lost ETH");
        assertEq(token.balanceOf(address(helper)), helperTok, "and holds the same token");
    }

    /// QS4 — no external price feed: the reference is seeded from the pool's own slot0 tick at
    ///       declaration and re-seeded from it when a donation funds an EMPTY pot, exactly.
    function test_QS4_referenceIsThePoolsOwnTick() public {
        int24 tick = GluedV4Core.getSlot0(POOL_MANAGER, id).tick;
        assertEq(pump.potOf(id).referenceTickX8, int32(tick) << 8, "seeded at declaration");

        _buy(20 ether); // move the price on an unfunded pot: nothing observes
        assertEq(pump.potOf(id).referenceTickX8, int32(tick) << 8, "an empty pot does not observe");
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _donateEth(key, 1 ether);
        int24 moved = GluedV4Core.getSlot0(POOL_MANAGER, id).tick;
        assertTrue(moved != tick);
        assertEq(pump.potOf(id).referenceTickX8, int32(moved) << 8, "re-seeded from the live tick on funding");
    }

    // ── input & arithmetic safety ───────────────────────────────────────────────────

    /// QS5 — share caps: `compound + buyback` and `compound + burn` above 100% are `BadConfig`, exactly
    ///       100% is legal with a zero recipient behind it, and one wei below 100% needs a live one.
    function test_QS5_shareCapsExact() public {
        uint64 W = uint64(WAD);
        vm.expectRevert(IGlueHook.BadConfig.selector);
        _openProgram(_cfg(W, 0, 1, alice, bob, MAX, MAX)); // 100% + 1 wei on the secondary side
        vm.expectRevert(IGlueHook.BadConfig.selector);
        _openProgram(_cfg(0, W, 1, alice, bob, MAX, MAX)); // 100% + 1 wei on the main side
        vm.expectRevert(IGlueHook.BadConfig.selector);
        _openProgram(_cfg(W - 1, 0, 0, address(0), bob, MAX, MAX)); // a remainder with nobody behind it
        vm.expectRevert(IGlueHook.BadConfig.selector);
        _openProgram(_cfg(0, W - 1, 0, alice, address(0), MAX, MAX));

        _openProgram(_cfg(W, W, 0, address(0), address(0), MAX, MAX)); // exactly 100% both sides: no remainder
        IGlueHook.Program memory g = pump.programOf(id);
        assertEq(g.buybackShareWad, W);
        assertEq(g.burnShareWad, W);
    }

    /// QS6 — floors never create value: with one-third shares the pot gets `floor(fS/3)`, the burn
    ///       `floor(fM/3)`, the recipients the exact rests; no wei is lost or minted on either side.
    function test_QS6_splitFloorsConserve() public {
        uint64 third = 333333333333333333;
        _openProgram(_cfg(third, third, 0, alice, bob, MAX, MAX));
        _buy(3 ether);
        _sell(3_000e18);

        uint256 pot = pump.potOf(id).balance;
        uint256 aliceEth = alice.balance;
        uint256 bobTok = token.balanceOf(bob);
        uint256 hookTok = token.balanceOf(address(pump));
        vm.recordLogs();
        (uint256 fM, uint256 fS) = pump.harvest(key);
        (bool found, address to, uint256 burned, IGlueHook.Delivery mode) = _lastDelivered(vm.getRecordedLogs());

        assertEq(pump.potOf(id).balance - pot, fS * third / WAD, "pot: floor");
        assertEq(alice.balance - aliceEth, fS - fS * third / WAD, "alice: the exact rest");
        assertTrue(found && mode == IGlueHook.Delivery.BURNED, "the burn leg burned");
        assertEq(to, stick.wrapperOf(address(token)), "through the main's glue");
        assertEq(burned, fM * third / WAD, "burn: floor");
        assertEq(token.balanceOf(bob) - bobTok, fM - fM * third / WAD, "bob: the exact rest");
        assertEq(token.balanceOf(address(pump)), hookTok, "nothing stays on the hook");
    }

    // ── external-call safety ────────────────────────────────────────────────────────

    /// QS7 — a recipient burning gas is CHARGED to the swap that pays it, never bounded: the push
    ///       runs at the carrying call's gas (no stipend — a fixed number in an immutable hook
    ///       drifts with every chain gas repricing and would push legitimate smart-contract
    ///       recipients out of the push path for good). (a) With a generous budget the swap lands,
    ///       the leg is booked `owed` (the receive died out of gas), the burn is on the swapper's
    ///       bill; (b) with a budget an accepting recipient fits in twice over, the swap fails out
    ///       of gas — on THIS pool, whose program named the recipient, and nothing else moved;
    ///       (c) an accepting recipient is paid again and the backlog stays claimable.
    function test_QS7_gasBurningRecipientIsChargedNotBounded() public {
        ProbeRecipient probe = new ProbeRecipient(pump);
        _openProgram(_cfg(0, 0, 0, address(probe), alice, 1, 1));
        _buy(1 ether); // warm everything once
        _sell(1_000e18);

        probe.setMode(ProbeRecipient.Mode.Accept);
        uint256 g0 = gasleft();
        _buy(1 ether);
        uint256 accepting = g0 - gasleft();
        assertEq(pump.owedOf(address(probe), ETH), 0);

        bytes memory buyCall = abi.encodeCall(V4PoolHelper.swap, (key, true, -int256(1 ether)));

        // (a) generous budget: the swap lands, the burner ate the budget, the leg is booked
        probe.setMode(ProbeRecipient.Mode.BurnGas);
        uint256 budget = 30_000_000;
        g0 = gasleft();
        (bool ok, ) = address(helper).call{gas: budget}(buyCall);
        uint256 burning = g0 - gasleft();
        assertTrue(ok, "(a) the swap landed");
        uint256 owed = pump.owedOf(address(probe), ETH);
        assertGt(owed, 0, "(a) the refused leg was booked");
        assertGt(burning, budget / 2, "(a) the burner was charged the swap's gas, not a stipend");

        // (b) a budget an accepting recipient fits in twice: the burner leaves the frame the 1/64
        //     the EVM keeps, the swap fails out of gas — its own pool, no book moved
        uint256 obl = pump.obligationOf(ETH);
        (ok, ) = address(helper).call{gas: accepting * 2}(buyCall);
        assertFalse(ok, "(b) the swap failed out of gas");
        assertEq(pump.owedOf(address(probe), ETH), owed, "(b) nothing more was booked");
        assertEq(pump.obligationOf(ETH), obl, "(b) the obligation did not move");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "(b) the venue stays solvent");

        // (c) accepting again: paid in-swap (the backlog folds in) and whatever remains is claimable
        probe.setMode(ProbeRecipient.Mode.Accept);
        uint256 before = address(probe).balance;
        _buy(1 ether);
        assertGt(address(probe).balance - before, owed, "(c) the leg AND the backlog landed");
        assertEq(pump.owedOf(address(probe), ETH), 0, "(c) nothing left booked");
    }

    /// QS8 — pull payments are isolated: a recipient that keeps refusing cannot claim (its backlog
    ///       stays booked, nothing else is blocked) while another recipient claims its own in full.
    function test_QS8_pullPaymentsAreIsolated() public {
        ProbeRecipient a = new ProbeRecipient(pump);
        ProbeRecipient b = new ProbeRecipient(pump);
        a.setMode(ProbeRecipient.Mode.Refuse);
        b.setMode(ProbeRecipient.Mode.Refuse);
        _openProgram(_cfg(0, 0, 0, address(a), alice, MAX, MAX));
        _buy(2 ether);
        pump.harvest(key);
        pump.setProgramConfig(id, _cfg(0, 0, 0, address(b), alice, MAX, MAX));
        _buy(2 ether);
        pump.harvest(key);
        uint256 owedA = pump.owedOf(address(a), ETH);
        uint256 owedB = pump.owedOf(address(b), ETH);
        assertGt(owedA, 0);
        assertGt(owedB, 0);

        vm.expectRevert(); // a still refuses its own money: the claim reverts, the booking stays
        a.pull(ETH);
        assertEq(pump.owedOf(address(a), ETH), owedA, "a's backlog intact");

        b.setMode(ProbeRecipient.Mode.Accept);
        assertEq(b.pull(ETH), owedB, "b claims in full");
        assertEq(address(b).balance, owedB);
        assertEq(pump.owedOf(address(b), ETH), 0);
        assertEq(pump.owedOf(address(a), ETH), owedA, "a's backlog still intact");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "covered throughout");
    }

    // ── state-invariant detection ───────────────────────────────────────────────────

    /// QS9 — the obligation identity after a hostile session: for both assets `obligationOf` equals
    ///       the sum of its published parts (pot, parked, held, carry, every recipient's owed) and the
    ///       hook's balance covers it.
    function test_QS9_obligationIdentityUnderHostility() public {
        ProbeRecipient a = new ProbeRecipient(pump);
        a.setMode(ProbeRecipient.Mode.Refuse);
        _openProgram(_cfg(uint64(WAD / 4), uint64(WAD / 4), uint64(WAD / 4), address(a), bob, 1, 1));
        _donateEth(key, 10 ether);
        _open();
        for (uint256 i; i < 3; ++i) {
            _buy(2 ether);
            _sell(2_000e18);
            _refill();
        }
        address[] memory owedTo = new address[](2);
        owedTo[0] = address(a);
        owedTo[1] = bob;

        assertGt(pump.owedOf(address(a), ETH), 0, "the hostile recipient was booked");
        assertEq(pump.obligationOf(ETH), _obligationFromParts(ETH, owedTo), "ETH identity");
        assertEq(pump.obligationOf(address(token)), _obligationFromParts(address(token), owedTo), "token identity");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "ETH covered");
        assertGe(token.balanceOf(address(pump)), pump.obligationOf(address(token)), "token covered");
    }

    // ── DoS & griefing ──────────────────────────────────────────────────────────────

    /// QS10 — force-feeding: ETH and MAIN sent straight to the hook move no ledger, fund no pot, change
    ///        no quote, and never pump — the hook reads its books, never its balance.
    function test_QS10_forceFeedingIsInert() public {
        _donateEth(key, 5 ether);
        _open();
        (uint256 spendBefore, ) = pump.quotePump(key, 1 ether);
        uint256 oblEth = pump.obligationOf(ETH);
        uint256 oblTok = pump.obligationOf(address(token));

        (bool ok, ) = payable(address(pump)).call{value: 50 ether}("");
        assertTrue(ok, "the hook accepts value (the PoolManager pays it that way)");
        token.transfer(address(pump), 1_000e18);

        assertEq(pump.potOf(id).balance, 5 ether, "pot unchanged");
        assertEq(pump.obligationOf(ETH), oblEth, "ETH obligation unchanged");
        assertEq(pump.obligationOf(address(token)), oblTok, "token obligation unchanged");
        (uint256 spendAfter, ) = pump.quotePump(key, 1 ether);
        assertEq(spendAfter, spendBefore, "quote unchanged");

        // a fresh, EMPTY pot next door never pumps off the stray ETH
        MockERC20 token2 = new MockERC20("Main2", "MN2", 18);
        (IPoolManagerMin.PoolKey memory k2, ) = _openEthPool(address(token2), address(0));
        vm.recordLogs();
        helper.swap(k2, true, -int256(1 ether));
        assertEq(_countPumped(vm.getRecordedLogs()), 0, "no pump from an empty pot, whatever the balance");
    }

    /// QS11 — a refusing Glue burn never blocks the carrying swap: the burn leg is HELD (booked,
    ///        custodied, out of circulation), the asset is flagged and later burns short-circuit.
    function test_QS11_refusingBurnIsHeldNotReverted() public {
        BlockingERC20 blocky = new BlockingERC20();
        (IPoolManagerMin.PoolKey memory k2, ) = _openEthPool(address(blocky), address(0));
        blocky.setBlocked(stick.wrapperOf(address(blocky)), true); // the glue refuses the pull
        pump.donate{value: 10 ether}(k2, 10 ether);

        vm.recordLogs();
        helper.swap(k2, true, -int256(1 ether));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool pumped, , uint256 bought) = _lastPumped(logs);
        (bool found, address to, uint256 amount, IGlueHook.Delivery mode) = _lastDelivered(logs);
        assertTrue(pumped && found);
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.HELD));
        assertEq(to, address(pump));
        assertEq(amount, bought);
        assertEq(pump.heldOf(address(blocky)), bought, "booked");
        assertEq(blocky.balanceOf(address(pump)), bought, "custodied");
    }

    /// QS12 — under-gassed swaps: whatever gas a swapper attaches, the frame either reverts as a
    ///        whole or lands with the books closed — the pot never overdraws, the hook always covers
    ///        its obligation, and nothing is half-booked.
    function test_QS12_underGassedSwapsNeverHalfBook() public {
        _openProgram(_cfg(uint64(WAD / 2), uint64(WAD / 2), 0, alice, bob, 1, 1));
        _donateEth(key, 20 ether);
        _open();
        uint256 landed;
        for (uint256 g = 120_000; g <= 700_000; g += 20_000) {
            try helper.swap{gas: g}(key, true, -int256(0.5 ether)) {
                ++landed;
            } catch {}
            assertLe(pump.potOf(id).balance, 20 ether, "pot never overdrawn");
            assertGe(address(pump).balance, pump.obligationOf(ETH), "ETH covered");
            assertGe(token.balanceOf(address(pump)), pump.obligationOf(address(token)), "token covered");
            _refill();
        }
        assertGt(landed, 0, "some swaps landed");
        assertLt(landed, 30, "some swaps were refused whole");
    }
}
