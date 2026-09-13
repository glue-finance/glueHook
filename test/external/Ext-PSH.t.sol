// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {ExtBase, RiderMain} from "./ExtBase.sol";
import {IGlueHook} from "../../contracts/interfaces/IGlueHook.sol";
import {IPoolManagerMin} from "../../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlockingERC20} from "../mocks/HostileTokens.sol";

/**
 * @title  ExtPSH — Pashov Audit Group skills, transposed to the hook.
 * @notice NOT an official audit: Pashov Audit Group did not review, endorse or sign this suite. It is
 *         the hook's own integration of the firm's PUBLISHED `solidity-auditor` skill and its
 *         hacking agents (`pashov/skills`): the access-control agent (weakest guard per storage
 *         variable, escalation chains), the asymmetry agent (paired operations and branches must
 *         mirror), the boundary agent (codeless receivers, zero / empty / max inputs), the
 *         economic-security and flow-gap agents (the transient PAYER window under a hostile token),
 *         the invariant agent (timers no secondary path may reset, conservation across pools) and
 *         the execution-trace agent (atomic rollback). Check table: audit/external/pashov.md.
 */
contract ExtPSH is ExtBase {
    // ── access-control agent ────────────────────────────────────────────────────────

    /// PSH1 — weakest guard on `Pot.recipient`: it has exactly two writers, `initPot` (once, spent)
    ///        and `setRecipient` (admin). The program's owner and operator — different addresses
    ///        from the admin — cannot move it, and a second `initPot` is refused before it could.
    function test_PSH1_recipientHasOneLiveWriter() public {
        _openProgramFor(alice, _plainCfg(alice)); // alice: program owner AND operator, not the pot admin

        vm.prank(alice);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.setRecipient(id, alice);

        vm.expectRevert(IGlueHook.PotAlreadyReady.selector);
        pump.initPot(key, address(token), alice); // the admin's own second declaration is spent

        assertEq(pump.potOf(id).recipient, address(0), "still burn");
        pump.setRecipient(id, bob);
        assertEq(pump.potOf(id).recipient, bob, "only the admin's setRecipient writes it");
    }

    /// PSH2 — no escalation chain: the operator cannot become owner or lock the owner out of the
    ///        property; the owner cannot take the operator role back once handed off; a zeroed
    ///        operator is frozen for everyone; a surrendered owner locks the liquidity but forces the
    ///        harvest open.
    function test_PSH2_noEscalationChain() public {
        _openProgramFor(alice, _plainCfg(alice));
        vm.prank(alice);
        pump.setProgramOperator(id, bob);

        // bob (operator) cannot reach the property
        vm.startPrank(bob);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.transferProgramOwnership(id, bob);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.removeProgramLiquidity(key, 1e18, bob);
        vm.stopPrank();

        // alice (owner) cannot reclaim the rules
        vm.prank(alice);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.setProgramOperator(id, alice);

        // bob freezes the rules: nobody edits again, the owner's property is intact
        vm.prank(bob);
        pump.setProgramOperator(id, address(0));
        vm.prank(bob);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.setProgramConfig(id, _plainCfg(bob));
        vm.prank(alice);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.setProgramConfig(id, _plainCfg(alice));
        vm.prank(alice);
        pump.removeProgramLiquidity(key, 1e18, alice);
        assertEq(pump.programOf(id).liquidity, SEED_LIQ - 1e18, "the owner still holds the property");

        // surrender: liquidity locked for good, manual harvest forced open
        vm.prank(alice);
        pump.transferProgramOwnership(id, address(0));
        IGlueHook.Program memory g = pump.programOf(id);
        assertEq(g.owner, address(0));
        assertTrue(g.publicHarvest, "an ownerless program is publicly harvestable");
        vm.prank(alice);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.removeProgramLiquidity(key, 1e18, alice);
    }

    // ── asymmetry agent ─────────────────────────────────────────────────────────────

    /// PSH3 — the two `donate` branches mirror: native and ERC20 write the same two ledgers by the
    ///        same amount, emit the same event with the credited amount, and the ERC20 branch pulls
    ///        EXACTLY `amount` from an unlimited allowance.
    function test_PSH3_donateBranchesMirror() public {
        MockERC20 main2 = new MockERC20("Main2", "MN2", 18);
        MockERC20 sec2 = new MockERC20("Sec2", "SC2", 18);
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openErc20Pool(address(main2), address(sec2), address(0), false);
        sec2.mint(alice, 10e18);
        vm.prank(alice);
        sec2.approve(address(pump), MAX);

        // native branch
        uint256 oblEth = pump.obligationOf(ETH);
        vm.recordLogs();
        vm.prank(alice);
        pump.donate{value: 3e18}(key, 3e18);
        (bool f1, uint256 amt1) = _donatedAmount(vm.getRecordedLogs(), id, alice);
        assertTrue(f1);
        assertEq(amt1, 3e18, "event carries the credit");
        assertEq(pump.potOf(id).balance, 3e18, "pot.balance");
        assertEq(pump.obligationOf(ETH) - oblEth, 3e18, "potTotal");

        // ERC20 branch
        uint256 oblTok = pump.obligationOf(address(sec2));
        vm.recordLogs();
        vm.prank(alice);
        pump.donate(k2, 3e18);
        (bool f2, uint256 amt2) = _donatedAmount(vm.getRecordedLogs(), id2, alice);
        assertTrue(f2);
        assertEq(amt2, 3e18, "same event, same amount");
        assertEq(pump.potOf(id2).balance, 3e18, "same pot write");
        assertEq(pump.obligationOf(address(sec2)) - oblTok, 3e18, "same ledger write");
        assertEq(sec2.balanceOf(alice), 7e18, "exactly `amount` pulled, the allowance notwithstanding");
        assertEq(sec2.allowance(alice, address(pump)), MAX, "infinite allowance not consumed");
    }

    /// PSH4 — `addProgramLiquidity` ↔ `removeProgramLiquidity` mirror: `liquidity` moves by exactly
    ///        ±L, BOTH harvest first (the pending fees route through the split, so the ETH the hook
    ///        keeps grows by exactly the pot's buyback leg and its token stock by nothing), and the
    ///        principal never rests on the hook.
    function test_PSH4_addRemoveMirror() public {
        _openProgram(_cfg(uint64(WAD / 2), uint64(WAD / 2), 0, alice, bob, MAX, MAX));

        // pending fees, then the add: harvest-first
        _buy(3 ether);
        _sell(3_000e18);
        uint256 hookEth = address(pump).balance;
        uint256 hookTok = token.balanceOf(address(pump));
        uint256 pot = pump.potOf(id).balance;
        vm.recordLogs();
        pump.addProgramLiquidity{value: 50 ether}(key, 1e20);
        (uint256 fM1, uint256 fS1) = _harvested(vm.getRecordedLogs());
        assertGt(fM1, 0);
        assertGt(fS1, 0);
        assertEq(pump.programOf(id).liquidity, SEED_LIQ + 1e20, "+L");
        assertEq(address(pump).balance - hookEth, pump.potOf(id).balance - pot, "only the pot's leg stayed");
        assertEq(pump.potOf(id).balance - pot, fS1 / 2, "which is exactly the buyback share");
        assertEq(token.balanceOf(address(pump)), hookTok, "no token stays (the burn leg left, the rest was paid)");

        // pending fees, then the remove: harvest-first again, same shape
        _buy(3 ether);
        _sell(3_000e18);
        hookEth = address(pump).balance;
        hookTok = token.balanceOf(address(pump));
        pot = pump.potOf(id).balance;
        vm.recordLogs();
        pump.removeProgramLiquidity(key, 1e20, address(this));
        (uint256 fM2, uint256 fS2) = _harvested(vm.getRecordedLogs());
        assertGt(fM2, 0);
        assertGt(fS2, 0);
        assertEq(pump.programOf(id).liquidity, SEED_LIQ, "-L");
        assertEq(address(pump).balance - hookEth, pump.potOf(id).balance - pot, "only the pot's leg stayed");
        assertEq(pump.potOf(id).balance - pot, fS2 / 2, "the buyback share, again");
        assertEq(token.balanceOf(address(pump)), hookTok, "no token stays");
    }

    /// PSH5 — the admin-variant sandwich: a config edit landing right before a harvest applies to
    ///        the WHOLE pending amount (the split is a function of the pending fees and the rules
    ///        standing at the call — nothing pro-rata, nothing retroactive), so front-running or
    ///        back-running an operator's edit extracts nothing.
    function test_PSH5_configEditIsNotSandwichable() public {
        _openProgram(_cfg(0, 0, 0, alice, bob, MAX, MAX)); // 100% to the recipients while accruing
        _buy(3 ether);
        _sell(3_000e18);

        // The operator flips the rules AFTER the fees accrued, right before the harvest
        pump.setProgramConfig(id, _cfg(uint64(WAD / 2), uint64(WAD / 2), 0, alice, bob, MAX, MAX));

        uint256 aliceEth = alice.balance;
        uint256 bobTok = token.balanceOf(bob);
        uint256 pot = pump.potOf(id).balance;
        (uint256 fM, uint256 fS) = pump.harvest(key);

        assertEq(pump.potOf(id).balance - pot, fS / 2, "the new buyback share applies to ALL pending");
        assertEq(alice.balance - aliceEth, fS - fS / 2, "alice gets the new remainder");
        assertEq(token.balanceOf(bob) - bobTok, fM - fM / 2, "bob gets the new remainder");
    }

    // ── boundary agent ──────────────────────────────────────────────────────────────

    /// PSH6 — codeless and receive-less receivers: an EOA takes the ERC20 leg, a contract with no
    ///        `receive` bounces the native leg into `owed` (never reverting the harvest), the backlog
    ///        accumulates across harvests and stays exactly `Σ legs`.
    function test_PSH6_codelessAndReceivelessRecipients() public {
        address noReceive = address(new MockERC20("NoReceive", "NR", 18)); // code, no receive()
        _openProgram(_cfg(0, 0, 0, noReceive, alice, MAX, MAX));

        _buy(2 ether);
        _sell(2_000e18);
        (uint256 fM1, uint256 fS1) = pump.harvest(key);
        assertEq(token.balanceOf(alice), fM1, "the EOA took the ERC20 leg");
        assertEq(pump.owedOf(noReceive, ETH), fS1, "the receive-less contract is booked");
        assertEq(noReceive.balance, 0, "and got nothing");

        _buy(2 ether);
        (, uint256 fS2) = pump.harvest(key);
        assertEq(pump.owedOf(noReceive, ETH), fS1 + fS2, "backlog accumulates");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "and is covered");
    }

    /// PSH7 — empty states are typed reverts, never silent zeros: `harvest` with no program or with
    ///        no liquidity, `claim` with no backlog, `flushDirect` with nothing parked or with the
    ///        pot pointed at burn since the park (the park stays intact).
    function test_PSH7_emptyStatesRevertTyped() public {
        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.harvest(key); // no program
        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.claim(ETH);
        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.flushDirect(id);

        _openProgram(_plainCfg(address(this)));
        pump.removeProgramLiquidity(key, SEED_LIQ, address(this));
        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.harvest(key); // program exists, zero liquidity

        BlockingERC20 blocky = new BlockingERC20();
        address treasury = makeAddr("treasury");
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openEthPool(address(blocky), treasury);
        blocky.setBlocked(treasury, true);
        pump.donate{value: 10 ether}(k2, 10 ether);
        helper.swap(k2, true, -int256(1 ether));
        uint256 parked = pump.parkedDirectOf(id2);
        assertGt(parked, 0);
        pump.setRecipient(id2, address(0)); // moved to burn since the park
        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.flushDirect(id2);
        assertEq(pump.parkedDirectOf(id2), parked, "the park is intact");
    }

    /// PSH8 — max inputs: a 2^120 ERC20 donation is credited exactly; a quote for a boundless
    ///        demand is bounded by the pot; a `uint128.max` liquidity add reverts instead of
    ///        truncating and leaves the program untouched.
    function test_PSH8_maxInputs() public {
        MockERC20 main2 = new MockERC20("Main2", "MN2", 18);
        MockERC20 sec2 = new MockERC20("Sec2", "SC2", 18);
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openErc20Pool(address(main2), address(sec2), address(0), false);
        sec2.mint(address(this), 1 << 120);
        sec2.approve(address(pump), MAX);
        assertEq(pump.donate(k2, 1 << 120), 1 << 120);
        assertEq(pump.potOf(id2).balance, 1 << 120);
        assertEq(pump.obligationOf(address(sec2)), 1 << 120);

        _donateEth(key, 20 ether);
        _open();
        (uint256 spend, uint256 minOut) = pump.quotePump(key, MAX);
        assertLe(spend, 20 ether, "bounded by the pot");
        assertGt(minOut, 0, "with a floor");

        _openProgram(_plainCfg(address(this)));
        vm.expectRevert();
        pump.addProgramLiquidity{value: 50 ether}(key, type(uint128).max);
        assertEq(pump.programOf(id).liquidity, SEED_LIQ, "untouched");
    }

    // ── economic-security × flow-gap agents ─────────────────────────────────────────

    /// PSH9 — the transient PAYER window cannot be hijacked. While the hook pulls a program's seed
    ///        from its creator, a hostile MAIN's transfer hook calls `PoolManager.swap` on the same
    ///        pool (the manager IS unlocked) to summon a pump whose settle would be drawn from the
    ///        payer's allowance instead of the pot. The hook's guard throws the swap out
    ///        (`Reentrancy`, wrapped by the manager), the pot is untouched, no pump fired, and the
    ///        payer paid exactly the position's own amounts.
    function test_PSH9_payerWindowCannotBeHijacked() public {
        RiderMain rider = new RiderMain(POOL_MANAGER);
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openEthPool(address(rider), address(0));
        pump.donate{value: 20 ether}(k2, 20 ether);
        _settleReference(k2);
        _refill();
        rider.mint(address(this), 1_000_000e18);
        rider.approve(address(pump), MAX);

        uint256 myRider = rider.balanceOf(address(this));
        uint256 hookEth = address(pump).balance;
        rider.arm(address(this), k2, -int256(5_000e18)); // a sell of main from inside the pull

        vm.recordLogs();
        (uint256 a0, uint256 a1) = pump.addLiquidity{value: 50 ether}(k2, TICK_LO, TICK_HI, SEED_LIQ, address(this));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(rider.attempted(), "the ride was attempted inside the pull");
        assertFalse(rider.landed(), "and never landed");
        assertEq(_innerSelector(rider.revertData()), IGlueHook.Reentrancy.selector, "the guard answered");
        assertEq(_countPumped(logs), 0, "no pump fired");
        assertEq(pump.potOf(id2).balance, 20 ether, "the pot is untouched");
        assertEq(address(pump).balance, hookEth, "the hook kept exactly its pot ETH (the seed's excess came back)");
        assertEq(myRider - rider.balanceOf(address(this)), a1, "the payer paid the position's main leg and nothing else");
        assertGt(a0, 0);
        assertEq(rider.balanceOf(address(pump)), 0, "no main on the hook");
    }

    // ── invariant agent ─────────────────────────────────────────────────────────────

    /// PSH10 — timers no secondary path may reset: the reference (`referenceTickX8`, `lastTick`,
    ///         `lastTimestamp`) and the spend bucket move ONLY behind swaps. Funding a funded pot,
    ///         moving the recipient, editing the rules and a manual harvest leave all four untouched;
    ///         the next swap moves the clock (control).
    function test_PSH10_timersMoveOnlyBehindSwaps() public {
        _openProgram(_cfg(0, 0, 0, alice, bob, MAX, MAX));
        _donateEth(key, 20 ether);
        _open();
        _buy(1 ether); // a pump: stamps the bucket, observes the reference
        _sell(1_000e18);
        IGlueHook.Pot memory before = pump.potOf(id);
        assertGt(before.pumpBucketTimestamp, 0, "the bucket was stamped");

        vm.warp(block.timestamp + 1234);
        vm.roll(block.number + 1);
        _donateEth(key, 1 ether);
        pump.setRecipient(id, alice);
        pump.setProgramConfig(id, _cfg(0, 0, 0, bob, alice, MAX, MAX));
        pump.harvest(key);
        pump.setRecipient(id, address(0));

        IGlueHook.Pot memory after_ = pump.potOf(id);
        assertEq(after_.referenceTickX8, before.referenceTickX8, "reference untouched");
        assertEq(after_.lastTick, before.lastTick, "standing tick untouched");
        assertEq(after_.lastTimestamp, before.lastTimestamp, "clock untouched");
        assertEq(after_.pumpBucketTimestamp, before.pumpBucketTimestamp, "bucket untouched");

        _buy(0.1 ether);
        assertEq(pump.potOf(id).lastTimestamp, uint32(block.timestamp), "a swap moves the clock");
    }

    /// PSH11 — conservation of the pump's two legs over a session: the pot's drop equals Σ spent, and
    ///         Σ bought equals Σ delivered (the pot's output has exactly one destination per pump).
    function test_PSH11_pumpLegsConserve() public {
        _donateEth(key, 20 ether);
        _open();
        vm.recordLogs();
        for (uint256 i; i < 4; ++i) {
            _buy(1 ether);
            _sell(1_000e18);
            _refill();
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 spent, uint256 bought) = _sumPumped(logs);
        assertGt(spent, 0, "pumps fired");
        assertEq(20 ether - pump.potOf(id).balance, spent, "pot drop == sum spent");
        assertEq(_sumDelivered(logs), bought, "sum bought == sum delivered");
        assertEq(pump.obligationOf(ETH), pump.potOf(id).balance, "nothing else is owed in ETH");
        assertEq(address(pump).balance, pump.obligationOf(ETH), "and the hook holds exactly that");
    }

    /// PSH12 — conservation ACROSS pools: two pots in the same secondary, traded in turn — the
    ///         asset obligation is exactly the sum of the two pot balances and equals the hook's
    ///         balance to the wei; neither pot ever spends the other's money.
    function test_PSH12_crossPoolConservation() public {
        MockERC20 token2 = new MockERC20("Main2", "MN2", 18);
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openEthPool(address(token2), address(0));
        _donateEth(key, 5 ether);
        pump.donate{value: 30 ether}(k2, 30 ether);
        _settleReference(key);
        _settleReference(k2);
        _refill();

        for (uint256 i; i < 3; ++i) {
            _buy(2 ether);
            helper.swap(k2, false, -int256(2_000e18));
            _refill();
        }
        uint256 a = pump.potOf(id).balance;
        uint256 b = pump.potOf(id2).balance;
        assertLt(a, 5 ether, "pot A spent");
        assertLt(b, 30 ether, "pot B spent");
        assertEq(pump.obligationOf(ETH), a + b, "obligation == sum pots");
        assertEq(address(pump).balance, a + b, "balance == sum pots");
    }

    // ── execution-trace agent ───────────────────────────────────────────────────────

    /// PSH13 — atomic rollback, and pot money never funds a position: with ANOTHER pool's pot ETH
    ///         sitting on the hook, a `launchPool` whose native seed is under-funded settles
    ///         transiently, is caught by the value cap (`BadDonation`) and rolls back as ONE unit —
    ///         no pool on the manager, no pot, no program, the value back, the other pot intact.
    function test_PSH13_underfundedLaunchRollsBackWhole() public {
        _donateEth(key, 40 ether); // the hook now holds 40 ETH that is NOT the launcher's
        MockERC20 fresh = new MockERC20("Fresh", "FRS", 18);
        IPoolManagerMin.PoolKey memory k2 = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(fresh), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        bytes32 id2 = keccak256(abi.encode(k2));
        fresh.mint(address(this), 1e24);
        fresh.approve(address(pump), MAX);
        uint256 eth = address(this).balance;

        vm.expectRevert(IGlueHook.BadDonation.selector);
        pump.launchPool{value: 0.001 ether}(
            k2, LAUNCH_SQRT, address(fresh), address(0), 0, 0, SEED_LIQ, address(this), _plainCfg(address(this))
        );

        assertEq(address(this).balance, eth, "value back");
        assertEq(_sqrtPrice(id2), 0, "no pool");
        assertEq(pump.potOf(id2).admin, address(0), "no pot");
        assertFalse(pump.programOf(id2).exists, "no program");
        assertEq(pump.potOf(id).balance, 40 ether, "the other pot is intact");
        assertEq(address(pump).balance, 40 ether, "and the hook holds exactly it");
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────

    function _donatedAmount(Vm.Log[] memory logs, bytes32 poolId, address donor)
        private view returns (bool found, uint256 amount)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pump)) continue;
            if (logs[i].topics[0] != keccak256("Donated(bytes32,address,uint256)")) continue;
            if (logs[i].topics[1] != poolId || address(uint160(uint256(logs[i].topics[2]))) != donor) continue;
            found = true;
            amount = abi.decode(logs[i].data, (uint256));
        }
    }

    function _harvested(Vm.Log[] memory logs) private view returns (uint256 fM, uint256 fS) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pump)) continue;
            if (logs[i].topics[0] != keccak256("Harvested(bytes32,uint256,uint256,uint256,uint256)")) continue;
            (fM, fS, , ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
        }
    }

    function _sumDelivered(Vm.Log[] memory logs) private view returns (uint256 total) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pump)) continue;
            if (logs[i].topics[0] != DELIVERED_SIG) continue;
            (uint256 amount, ) = abi.decode(logs[i].data, (uint256, uint256));
            total += amount;
        }
    }
}
