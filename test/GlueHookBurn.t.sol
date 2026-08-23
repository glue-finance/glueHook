// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {GlueHookFixture} from "./helpers/GlueHookFixture.sol";
import {IGlueHook} from "../contracts/interfaces/IGlueHook.sol";
import {IPoolManagerMin} from "../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BurnableERC20, FakeBurnERC20, BlockingERC20} from "./mocks/HostileTokens.sol";

/**
 * @title  GlueHookBurn — the Glue burn path and the delivery cascade, every leg.
 * @notice B1–B9. A burn-intent pot (recipient == address(0)) burns through the Glue Protocol: a
 *         pure `unglue` through the canonical GlueStick (an empty collateral list — the supply is
 *         pulled from the hook and destroyed in-protocol, which runs its own burn / dead-route
 *         fallbacks), accepted only on the hook's verified balance drop. A main whose unglue
 *         refuses is flagged unburnable and every burn of it is HELD on the hook FOREVER (no
 *         withdrawal path exists, so custody is the burn). A live recipient is a literal target
 *         whose refusal parks per-pool and retries through {flushDirect}. A pot's MAIN must be
 *         glueable, so the network token and NATIVEWRAP are rejected at the declaration itself.
 */
contract GlueHookBurn is GlueHookFixture {
    /// @dev Run a buy that carries a pump and return what the pump's delivery did.
    function _pumpAndReadDelivery(IPoolManagerMin.PoolKey memory key)
        internal
        returns (uint256 bought, address to, IGlueHook.Delivery mode)
    {
        vm.recordLogs();
        helper.swap(key, true, -int256(1 ether)); // ETH -> main = a buy
        Vm.Log[] memory logs = vm.getRecordedLogs();
        ( , , bought) = _lastPumped(logs);
        ( , to, , mode) = _lastDelivered(logs);
    }

    /// B1 — HELD FOREVER: a burn-intent token that blocks the GlueStick's pull can never be
    ///      unglued — the burn is held on the hook itself, booked in {heldOf} and counted in
    ///      {obligationOf}. There is no function that can ever move it, so custody IS the burn.
    function test_B1_heldForever() public {
        BlockingERC20 main = new BlockingERC20();

        _deployCore();
        main.setBlocked(GLUE_STICK, true); // the glue pull reverts: the unglue can never run
        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(main), address(0));
        _donateEth(key, 20 ether);

        (uint256 bought, address to, IGlueHook.Delivery mode) = _pumpAndReadDelivery(key);

        assertGt(bought, 0, "the pump bought main");
        assertEq(to, address(pump), "delivery settled on the hook itself");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.HELD), "as a terminal hold");
        assertEq(main.balanceOf(address(pump)), bought, "the hook custodies the raw");
        assertEq(pump.heldOf(address(main)), bought, "booked in the held ledger");
        assertEq(pump.parkedOf(address(main)), 0, "never as a retryable park");
        assertEq(pump.obligationOf(address(main)), bought, "and attributed in the obligation");
    }

    /// B2 — THE GLUE BURN: the main is pulled by the GlueStick's pure `unglue` and destroyed
    ///      in-protocol (this token has a working `burn(uint256)`, so the supply truly falls).
    ///      The delivery names the GLUE_STICK and is accepted only because the hook's balance
    ///      actually dropped.
    function test_B2_glueBurn() public {
        BurnableERC20 main = new BurnableERC20();
        _deployCore();
        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(main), address(0));
        _donateEth(key, 20 ether);

        uint256 supplyBefore = main.totalSupply();
        (uint256 bought, address to, IGlueHook.Delivery mode) = _pumpAndReadDelivery(key);

        assertGt(bought, 0, "bought main");
        assertEq(to, GLUE_STICK, "delivery names the glue it burned through");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.BURNED), "as a Glue burn");
        assertEq(main.totalSupply(), supplyBefore - bought, "supply fell");
        assertEq(main.balanceOf(address(pump)), 0, "nothing stuck to the hook");
        assertGt(stick.unglueCalls(), 0, "the burn really ran through the stick");
    }

    /// B3 — A LYING BURN INSIDE THE GLUE: a token whose `burn` returns success but destroys
    ///      nothing is caught by the protocol's own balance-drop check and dead-routed inside the
    ///      glue. The hook still counts it BURNED — its own balance really fell — and the supply
    ///      really is out of circulation at `0xdead`.
    function test_B3_fakeBurnDeadRoutesInsideGlue() public {
        FakeBurnERC20 main = new FakeBurnERC20();
        _deployCore();
        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(main), address(0));
        _donateEth(key, 20 ether);

        (uint256 bought, address to, IGlueHook.Delivery mode) = _pumpAndReadDelivery(key);

        assertGt(bought, 0, "bought main");
        assertEq(to, GLUE_STICK, "the delivery went through the glue");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.BURNED), "as a Glue burn");
        assertEq(main.balanceOf(DEAD), bought, "which dead-routed the lying token internally");
        assertEq(main.balanceOf(address(pump)), 0, "nothing stuck to the hook");
    }

    /// B4 — THE FLAG IS FOREVER: the first refused unglue marks the asset unburnable, and from
    ///      then on every burn of it settles straight to the held ledger — even if the unglue
    ///      would now succeed. The probe never runs again.
    function test_B4_unburnableFlagShortCircuits() public {
        BlockingERC20 main = new BlockingERC20();

        _deployCore();
        main.setBlocked(GLUE_STICK, true);
        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(main), address(0));
        _donateEth(key, 40 ether);

        // First pump: the unglue refuses, the asset is flagged, the amount is held
        (uint256 first, , IGlueHook.Delivery mode1) = _pumpAndReadDelivery(key);
        assertEq(uint8(mode1), uint8(IGlueHook.Delivery.HELD), "first fall-through held");
        assertEq(pump.heldOf(address(main)), first, "and booked");

        // The token relents — the unglue WOULD now work. The flag doesn't care.
        main.setBlocked(GLUE_STICK, false);

        (uint256 second, address to, IGlueHook.Delivery mode2) = _pumpAndReadDelivery(key);
        assertGt(second, 0, "the second pump bought main");
        assertEq(to, address(pump), "and still settled on the hook");
        assertEq(uint8(mode2), uint8(IGlueHook.Delivery.HELD), "straight to held, probe skipped");
        assertEq(pump.heldOf(address(main)), first + second, "the held ledger accumulates");
        assertEq(main.balanceOf(GLUE_STICK), 0, "the stick never saw a wei of it");
    }

    /// B5 — THE FLAG IS PER-ASSET: one weird token being held forever changes nothing for any
    ///      other pool — a glueable main elsewhere still burns through the stick.
    function test_B5_flagIsPerAsset() public {
        BlockingERC20 weird = new BlockingERC20();
        BurnableERC20 sane = new BurnableERC20();

        _deployCore();
        weird.setBlocked(GLUE_STICK, true);
        (IPoolManagerMin.PoolKey memory kWeird, ) = _openEthPool(address(weird), address(0));
        (IPoolManagerMin.PoolKey memory kSane, ) = _openEthPool(address(sane), address(0));
        _donateEth(kWeird, 20 ether);
        _donateEth(kSane, 20 ether);

        ( , , IGlueHook.Delivery modeWeird) = _pumpAndReadDelivery(kWeird);
        assertEq(uint8(modeWeird), uint8(IGlueHook.Delivery.HELD), "the weird token held");

        uint256 supplyBefore = sane.totalSupply();
        (uint256 bought, , IGlueHook.Delivery modeSane) = _pumpAndReadDelivery(kSane);
        assertEq(uint8(modeSane), uint8(IGlueHook.Delivery.BURNED), "the sane one still glue-burns");
        assertEq(sane.totalSupply(), supplyBefore - bought, "for real");
    }

    /// B6 — flushDirect is a no-op guard, not a footgun: it reverts when nothing is parked for the
    ///      pool, and the held ledger has no retry entry at all (held is terminal by design).
    function test_B6_flushDirectGuard() public {
        MockERC20 main = new MockERC20("Main", "MN", 18);
        _deployCore();
        ( , bytes32 poolId) = _openEthPool(address(main), address(0));

        // Nothing direct-parked for the pool
        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.flushDirect(poolId);
    }

    /// B7 — MAIN MUST BE GLUEABLE: the pot declaration rejects the NETWORK TOKEN and NATIVEWRAP
    ///      outright — neither can run the Glue burn — on both {initPot} and {launchPool}. An
    ///      ERC20 main declares fine and may be pointed at burn freely, both ways.
    function test_B7_unglueableMainsRejected() public {
        MockERC20 secondary = new MockERC20("Sec", "SEC", 18);
        MockERC20 main = new MockERC20("Main", "MN", 18);
        _deployCore();

        IPoolManagerMin.PoolKey memory key = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(secondary), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        IPoolManagerMin(POOL_MANAGER).initialize(key, LAUNCH_SQRT);

        // The network token can never be main — burn intent or not
        vm.expectRevert(IGlueHook.BadRoles.selector);
        pump.initPot(key, ETH, address(0));
        vm.expectRevert(IGlueHook.BadRoles.selector);
        pump.initPot(key, ETH, makeAddr("treasury"));

        // NATIVEWRAP can never be main either (Glue rejects the network wrapper by design)
        MockERC20 wrapPair = new MockERC20("Pair", "PAIR", 18);
        (address c0, address c1) = NATIVEWRAP < address(wrapPair)
            ? (NATIVEWRAP, address(wrapPair))
            : (address(wrapPair), NATIVEWRAP);
        IPoolManagerMin.PoolKey memory wkey = IPoolManagerMin.PoolKey({
            currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        IPoolManagerMin(POOL_MANAGER).initialize(wkey, PAR_SQRT);
        vm.expectRevert(IGlueHook.BadRoles.selector);
        pump.initPot(wkey, NATIVEWRAP, makeAddr("treasury"));

        // launchPool runs the SAME declaration, so the same mains bounce there too
        IPoolManagerMin.PoolKey memory lkey = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(main), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        vm.expectRevert(IGlueHook.BadRoles.selector);
        pump.launchPool(
            lkey, LAUNCH_SQRT, ETH, makeAddr("treasury"), 0, 0, 0, address(this), _plainCfg()
        );

        // A glueable ERC20 main declares fine, and burn intent is always a legal target
        pump.initPot(key, address(secondary), makeAddr("treasury"));
        bytes32 poolId = keccak256(abi.encode(key));
        pump.setRecipient(poolId, address(0)); // to burn…
        pump.setRecipient(poolId, makeAddr("otherTreasury")); // …and back
    }

    /// B8 — a refused ERC20 delivery parks PER-POOL and retries: the recipient's blocklist bounces
    ///      the direct transfer (park, booked in {parkedDirectOf}), `flushDirect` reverts while the
    ///      refusal stands, and delivers the whole park once it lifts.
    function test_B8_refusedDeliveryParksAndRetries() public {
        BlockingERC20 main = new BlockingERC20();
        address treasury = makeAddr("treasury");
        main.setBlocked(treasury, true);

        _deployCore();
        (IPoolManagerMin.PoolKey memory key, bytes32 poolId) = _openEthPool(address(main), treasury);
        _donateEth(key, 20 ether);

        (uint256 bought, address to, IGlueHook.Delivery mode) = _pumpAndReadDelivery(key);
        assertEq(to, address(pump), "the refused delivery parked on the hook");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.PARKED), "as a park");
        assertEq(pump.parkedDirectOf(poolId), bought, "booked per-pool for the retry");
        assertEq(pump.parkedOf(address(main)), bought, "and in the asset ledger");
        assertEq(pump.heldOf(address(main)), 0, "but never as a hold (the intent was delivery)");

        // Still refused: the retry reverts and the park stays intact
        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.flushDirect(poolId);
        assertEq(pump.parkedDirectOf(poolId), bought, "untouched");

        // The refusal lifts: the retry delivers the whole park and clears both ledgers
        main.setBlocked(treasury, false);
        vm.expectEmit(true, true, false, true, address(pump));
        emit IGlueHook.FlushedDirect(poolId, treasury, bought);
        uint256 delivered = pump.flushDirect(poolId);

        assertEq(delivered, bought, "the whole park delivered");
        assertEq(main.balanceOf(treasury), bought, "and the treasury really holds it");
        assertEq(pump.parkedDirectOf(poolId), 0, "per-pool ledger cleared");
        assertEq(pump.parkedOf(address(main)), 0, "asset ledger cleared");
        assertEq(main.balanceOf(address(pump)), 0, "nothing stuck to the hook");
    }

    /// B9 — THE CREATION-TIME ENSURE: declaring a pot lazily creates the main's glue through the
    ///      GlueStick's own validated chokepoint, so burns route through Glue from the first swap;
    ///      an already-glued main is left alone (the ensure is idempotent and skipped), and a
    ///      refused ensure never blocks the pool (its burns settle to the held ledger instead —
    ///      the never-stop posture, pinned in the pot-split suite's NS3).
    function test_B9_creationEnsuresTheGlue() public {
        MockERC20 fresh = new MockERC20("Fresh", "FRS", 18);
        MockERC20 preGlued = new MockERC20("Glued", "GLD", 18);
        _deployCore();

        // A fresh main: the declaration creates its glue
        (bool sticky, ) = stick.isStickyAsset(address(fresh));
        assertFalse(sticky, "no glue before the declaration");
        _openEthPool(address(fresh), address(0));
        (sticky, ) = stick.isStickyAsset(address(fresh));
        assertTrue(sticky, "the declaration ensured the glue");

        // An already-glued main: the ensure is skipped (isStickyAsset short-circuits)
        stick.ensureWrapper(address(preGlued));
        uint256 ensuresBefore = stick.ensureCalls();
        _openEthPool(address(preGlued), address(0));
        assertEq(stick.ensureCalls(), ensuresBefore, "no redundant ensure on a glued main");
    }

    /// @dev A minimal all-zero-shares config for launch attempts that must revert earlier.
    function _plainCfg() internal returns (IGlueHook.ProgramConfig memory) {
        return IGlueHook.ProgramConfig({
            buybackShareWad: 0,
            burnShareWad: 0,
            compoundShareWad: 0,
            potCompoundShareWad: 0,
            potBurnShareWad: 0,
            publicHarvest: false,
            secondaryRecipient: makeAddr("cfg_sec"),
            mainRecipient: makeAddr("cfg_main"),
            minMain: type(uint256).max,
            minSecondary: type(uint256).max
        });
    }
}
