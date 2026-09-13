// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {GlueHookFixture} from "./helpers/GlueHookFixture.sol";
import {GlueHook} from "../contracts/GlueHook.sol";
import {IGlueHook} from "../contracts/interfaces/IGlueHook.sol";
import {IPoolManagerMin} from "../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";

/**
 * @title  GlueHookUnit — deterministic single-behaviour proofs, one per test.
 * @notice U1–U14. Everything the hook promises in its interface, checked in isolation against the
 *         REAL PoolManager: deployment gating, callback auth, admin capture, role declaration,
 *         funding in both currencies (including fee-on-transfer), the pump behind buys and sells,
 *         recipient delivery, the passthrough guarantees, and the view surface.
 */
contract GlueHookUnit is GlueHookFixture {
    MockERC20 token;
    IPoolManagerMin.PoolKey key;
    bytes32 id;

    function setUp() public {
        _deployCore();
        token = new MockERC20("Main", "MAIN", 18);
        (key, id) = _openEthPool(address(token), address(0));
    }

    /// U1 — the address IS the permission set: a deployment at an address without the hook bits
    ///      reverts in the constructor, so a mis-mined salt fails at deploy time.
    function test_U1_wrongAddressRevertsAtDeploy() public {
        vm.expectRevert(IGlueHook.BadRoles.selector);
        new GlueHook(POOL_MANAGER, NATIVEWRAP);
    }

    /// U2 — every callback and the pump's self-call entry are PoolManager-only / self-only.
    function test_U2_callbackAuth() public {
        IPoolManagerMin.SwapParams memory params =
            IPoolManagerMin.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});

        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.beforeInitialize(address(this), key, 0);

        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.afterSwap(address(this), key, params, 0, "");

        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.executePump(id, key, true, 1, 1);
    }

    /// U3 — whoever calls `PoolManager.initialize` on a hooked pool is captured as its pot admin.
    function test_U3_adminCapture() public view {
        assertEq(pump.potOf(id).admin, address(this), "the initialiser is the admin");
        assertTrue(pump.potOf(id).configured, "and the fixture declared the roles");
    }

    /// U4 — initPot: admin-only, once, currencies validated, and never before the pool exists.
    function test_U4_initPotValidation() public {
        // A pool that never ran beforeInitialize has no admin and no pot
        IPoolManagerMin.PoolKey memory ghost = key;
        ghost.fee = 500;
        ghost.tickSpacing = 10;
        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.initPot(ghost, address(token), address(0));

        // Roles are declared once
        vm.expectRevert(IGlueHook.PotAlreadyReady.selector);
        pump.initPot(key, address(token), address(0));

        // A fresh pool, but a stranger cannot declare its roles
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        IPoolManagerMin.PoolKey memory k2 = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(other), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        IPoolManagerMin(POOL_MANAGER).initialize(k2, LAUNCH_SQRT);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.initPot(k2, address(other), address(0));

        // And main must be one of the pool's own currencies
        vm.expectRevert(IGlueHook.BadRoles.selector);
        pump.initPot(k2, address(token), address(0));
    }

    /// U5 — setRecipient: admin-only, configured pots only, and `address(0)` restores burn intent.
    function test_U5_setRecipient() public {
        address alice = makeAddr("alice");

        vm.prank(alice);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.setRecipient(id, alice);

        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.setRecipient(keccak256("ghost pool"), alice);

        vm.expectEmit(true, false, false, true, address(pump));
        emit IGlueHook.RecipientSet(id, alice);
        pump.setRecipient(id, alice);
        assertEq(pump.potOf(id).recipient, alice, "recipient moved");

        pump.setRecipient(id, address(0));
        assertEq(pump.potOf(id).recipient, address(0), "and burn intent restored");
    }

    /// U6 — a native donation: exact value required, credited verbatim, booked everywhere it must be.
    function test_U6_donateNative() public {
        // Value and amount must agree — never more, never less
        vm.expectRevert(IGlueHook.BadDonation.selector);
        pump.donate{value: 1 ether}(key, 2 ether);

        vm.expectEmit(true, true, false, true, address(pump));
        emit IGlueHook.Donated(id, address(this), 5 ether);
        uint256 credited = pump.donate{value: 5 ether}(key, 5 ether);

        assertEq(credited, 5 ether, "credited verbatim");
        assertEq(pump.potOf(id).balance, 5 ether, "pot booked it");
        assertEq(pump.obligationOf(ETH), 5 ether, "the obligation ledger booked it");
        assertEq(address(pump).balance, 5 ether, "and the hook actually holds it");
    }

    /// U7 — a pot that has no declared roles cannot be funded: there is no "secondary" to credit.
    function test_U7_donateUnconfiguredReverts() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        IPoolManagerMin.PoolKey memory k2 = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(other), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        IPoolManagerMin(POOL_MANAGER).initialize(k2, LAUNCH_SQRT);
        // The pool exists and has an admin, but initPot has not run
        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.donate{value: 1 ether}(k2, 1 ether);
    }

    /// U8 — an ERC20 pot: no value accepted, allowance-pulled, and a fee-on-transfer secondary is
    ///      credited at the MEASURED amount that actually arrived, not the nominal one.
    function test_U8_donateErc20AndFoT() public {
        MockERC20 main2 = new MockERC20("Main2", "MN2", 18);
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20("Taxed", "TAX", 18, 300); // 3%
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) =
            _openErc20Pool(address(main2), address(fot), address(0), false);

        fot.mint(address(this), 100e18);
        fot.approve(address(pump), type(uint256).max);

        // An ERC20 pot must not be paid value
        vm.expectRevert(IGlueHook.BadDonation.selector);
        pump.donate{value: 1}(k2, 10e18);

        uint256 credited = pump.donate(k2, 10e18);
        uint256 expected = 10e18 - (10e18 * 300) / 10_000;
        assertEq(credited, expected, "credited what arrived, not what was sent");
        assertEq(pump.potOf(id2).balance, expected, "pot books the measured delta");
        assertEq(fot.balanceOf(address(pump)), expected, "which is what the hook holds");
    }

    /// U9 — the pump's happy path: a buy triggers it, it spends pot ETH, buys main, and with no glue
    ///      and no burn() on the token the cascade lands on the DEAD address. Books stay closed.
    function test_U9_pumpHappyPath() public {
        _donateEth(key, 20 ether);

        vm.recordLogs();
        helper.swap(key, true, -int256(1 ether)); // ETH -> token = a buy of main
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool pumped, uint256 spent, uint256 bought) = _lastPumped(logs);
        assertTrue(pumped, "the buy carried a pump");
        assertGt(spent, 0, "which spent pot secondary");
        assertGt(bought, 0, "and bought main");
        assertEq(pump.potOf(id).balance, 20 ether - spent, "the pot was debited exactly the spend");

        (bool delivered, address to, uint256 amount, IGlueHook.Delivery mode) = _lastDelivered(logs);
        assertTrue(delivered, "the bought main was delivered");
        assertEq(to, stick.wrapperOf(address(token)), "through the main's own GlueWrapper unglue");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.BURNED), "as a BURNED delivery");
        assertEq(amount, bought, "in full");
        assertEq(token.balanceOf(DEAD), bought, "and the glue really destroyed it (dead-routed: no burn())");
        assertEq(token.balanceOf(address(pump)), 0, "nothing stuck to the hook");
    }

    /// U10 — the sell-side pump's happy path: a sell into a rich pot pays the seller the pool's own
    ///       price (their trade is untouched), then the pump buys the dip behind them — spending
    ///       exactly what its quote for the seller's proceeds sized, clearing its floor, and lifting
    ///       the price back up but never above where the sell started.
    function test_U10_pumpBehindSell() public {
        _donateEth(key, 50 ether);
        uint160 before = _sqrtPrice(id);

        uint256 helperEthBefore = address(helper).balance;
        vm.recordLogs();
        helper.swap(key, false, -int256(2_000e18)); // token -> ETH = a sell of main
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool pumped, uint256 spent, uint256 bought) = _lastPumped(logs);
        uint256 received = address(helper).balance - helperEthBefore;

        assertTrue(pumped, "the pump fired behind the sell");
        // The pot is rich, the dip sits below the reference: the fee ceiling binds (0.8 · 0.3% · ~100 ETH)
        assertApproxEqRel(spent, 0.24 ether, 0.02e18, "the fee ceiling sized it");
        assertLt(spent, (received * 48) / 100, "well inside 48% of what the seller received");
        assertGt(bought, 0, "and it bought main");
        assertEq(pump.potOf(id).balance, 50 ether - spent, "the pot was debited exactly the spend");
        // Main is currency1: the sell lifted the sqrt ratio (a cheaper main), the pump pulled it back
        // part of the way, and it still sits above the sell's start
        assertGt(_sqrtPrice(id), before, "main's price ends below the sell's start");
    }

    /// U11 — a pot thinner than the pump it could carry spends 80% of itself (the haircut), never
    ///       all of it, and the seller's own trade is still the pool's plain execution.
    function test_U11_thinPotBehindSell() public {
        _donateEth(key, 0.05 ether);
        uint160 before = _sqrtPrice(id);

        vm.recordLogs();
        helper.swap(key, false, -int256(60_000e18));
        (bool pumped, uint256 spent, ) = _lastPumped(vm.getRecordedLogs());

        assertTrue(pumped, "the thin pot still fired");
        assertEq(spent, 0.04 ether, "spending 80% of what it held");
        assertEq(pump.potOf(id).balance, 0.01 ether, "keeping the haircut's remainder");
        assertTrue(_sqrtPrice(id) != before, "and the pool traded the sell itself");
    }

    /// U12 — a live recipient is a literal delivery target: the pump's proceeds transfer straight to
    ///       it, marked DIRECT, and nothing touches the burn cascade.
    function test_U12_recipientDirectDelivery() public {
        address treasury = makeAddr("treasury");
        pump.setRecipient(id, treasury);
        _donateEth(key, 10 ether);

        vm.recordLogs();
        helper.swap(key, true, -int256(1 ether));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        ( , , uint256 bought) = _lastPumped(logs);
        (bool delivered, address to, uint256 amount, IGlueHook.Delivery mode) = _lastDelivered(logs);
        assertTrue(delivered, "delivered");
        assertEq(to, treasury, "to the named recipient");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.DIRECT), "directly");
        assertEq(token.balanceOf(treasury), amount, "who really holds it");
        assertEq(amount, bought, "all of it");
        assertEq(token.balanceOf(DEAD), 0, "and nothing was burned");
    }

    /// U13 — the quotes mirror the live gates: zeros before funding, real numbers after, the gate
    ///       reads whole at the reference, and the obligation ledger is pot totals plus parked.
    function test_U13_viewsAndQuotes() public {
        // Empty pot: the pump stands aside, and the quote says so
        (uint256 s2, uint256 p2) = pump.quotePump(key, 1 ether);
        assertEq(s2 + p2, 0, "an empty pot quotes nothing");

        _donateEth(key, 10 ether);
        (uint256 spend, uint256 minOut) = pump.quotePump(key, 1 ether);
        assertGt(spend, 0, "a funded pot quotes the pump");
        assertGt(minOut, 0, "with a real floor");
        (uint256 share, int24 spot, int24 ref) = pump.pumpShareOf(id);
        assertEq(spot, ref, "a fresh pool sits on its reference");
        assertEq(share, 0.6e18, "so the gate reads the whole share");

        assertEq(pump.obligationOf(ETH), 10 ether, "obligation = pot totals + parked");
        assertEq(pump.parkedOf(address(token)), 0, "nothing parked");
        assertEq(pump.heldOf(address(token)), 0, "and nothing burn-parked");
    }

    /// U14 — a dust sell that pays the seller nothing carries no demand, so it carries no pump: the
    ///       pot is untouched while the pool executes the dust itself.
    function test_U14_dustSellCarriesNoPump() public {
        _donateEth(key, 10 ether);
        uint160 before = _sqrtPrice(id);

        // 500 wei of main: the proceeds side (ETH, ~1000x scarcer) rounds to zero, but after the fee
        // there is still input left for the pool to execute, so the price must move.
        vm.recordLogs();
        helper.swap(key, false, -int256(500));
        (bool pumped, , ) = _lastPumped(vm.getRecordedLogs());

        assertFalse(pumped, "zero proceeds size a zero pump");
        assertTrue(_sqrtPrice(id) != before, "and the pool executed the dust sell instead");
        assertEq(pump.potOf(id).balance, 10 ether, "with the pot untouched");
    }
}
