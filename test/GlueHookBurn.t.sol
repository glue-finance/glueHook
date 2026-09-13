// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {GlueHookFixture} from "./helpers/GlueHookFixture.sol";
import {IGlueHook} from "../contracts/interfaces/IGlueHook.sol";
import {IPoolManagerMin} from "../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockGlueWrapper} from "./mocks/MockGlueWrapper.sol";
import {BurnableERC20, FakeBurnERC20, BlockingERC20} from "./mocks/HostileTokens.sol";

/**
 * @title  GlueHookBurn — the Glue burn path and the delivery cascade, every leg.
 * @notice B1–B15. A burn-intent pot (recipient == address(0)) burns through the Glue Protocol in
 *         the shape the main's classification dictates. A glued main: a pure `unglue` called on
 *         the main's own GlueWrapper (an empty collateral list — the supply is pulled from the
 *         hook's exact allowance and destroyed in-protocol, which runs its own burn / dead-route
 *         fallbacks), accepted only on the hook's verified balance drop. A main that IS a
 *         GlueWrapper (ERC20 or NFT mode): a PARK — the shares are transferred to the wrapper's
 *         own address, the one custody Glue's supply oracle subtracts. A main whose unglue
 *         refuses is flagged unburnable and every burn of it is HELD on the hook FOREVER (no
 *         withdrawal path exists, so custody is the burn). A live recipient is a literal target
 *         whose refusal parks per-pool and retries through {flushDirect}. A pot's MAIN must be
 *         glueable, so the network token and NATIVEWRAP are rejected at the declaration itself.
 */
contract GlueHookBurn is GlueHookFixture {
    /// @dev Deploy a GlueWrapper clone in the given mode and register it as the canonical glue of
    ///      a fresh collection/sticky — the shape a wrapper main has on the real Stick.
    function _wrapperMain(bool fungible) internal returns (MockGlueWrapper w) {
        MockERC20 collection = new MockERC20("Collection", "NFT", 18);
        w = new MockGlueWrapper();
        w.initialize(address(collection), fungible);
        stick.registerWrapper(address(w), address(collection));
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

    /// @dev Run a buy that carries a pump and return what the pump's delivery did.
    function _pumpAndReadDelivery(IPoolManagerMin.PoolKey memory key)
        internal
        returns (uint256 bought, address to, IGlueHook.Delivery mode)
    {
        _refill(); // each pump here is meant to be a full one: give the bucket its minute
        vm.recordLogs();
        helper.swap(key, true, -int256(1 ether)); // ETH -> main = a buy
        Vm.Log[] memory logs = vm.getRecordedLogs();
        ( , , bought) = _lastPumped(logs);
        ( , to, , mode) = _lastDelivered(logs);
    }

    /// B1 — HELD FOREVER: a burn-intent token that blocks its own glue's pull can never be
    ///      unglued — the burn is held on the hook itself, booked in {heldOf} and counted in
    ///      {obligationOf}. There is no function that can ever move it, so custody IS the burn.
    function test_B1_heldForever() public {
        BlockingERC20 main = new BlockingERC20();

        _deployCore();
        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(main), address(0));
        main.setBlocked(stick.wrapperOf(address(main)), true); // the glue pull reverts: the unglue can never run
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

    /// B2 — THE GLUE BURN: the main is pulled by its own GlueWrapper's pure `unglue` (no Stick
    ///      hop) and destroyed in-protocol (this token has a working `burn(uint256)`, so the
    ///      supply truly falls). The delivery names the WRAPPER and is accepted only because the
    ///      hook's balance actually dropped.
    function test_B2_glueBurn() public {
        BurnableERC20 main = new BurnableERC20();
        _deployCore();
        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(main), address(0));
        MockGlueWrapper glue = MockGlueWrapper(stick.wrapperOf(address(main)));
        _donateEth(key, 20 ether);

        uint256 supplyBefore = main.totalSupply();
        (uint256 bought, address to, IGlueHook.Delivery mode) = _pumpAndReadDelivery(key);

        assertGt(bought, 0, "bought main");
        assertEq(to, address(glue), "delivery names the wrapper it burned through");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.BURNED), "as a Glue burn");
        assertEq(main.totalSupply(), supplyBefore - bought, "supply fell");
        assertEq(main.balanceOf(address(pump)), 0, "nothing stuck to the hook");
        assertEq(glue.unglueCalls(), 1, "the burn really ran through the wrapper");
        assertEq(stick.unglueCalls(), 0, "and never through the stick");
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
        assertEq(to, stick.wrapperOf(address(main)), "the delivery went through the glue");
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
        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(main), address(0));
        address glue = stick.wrapperOf(address(main));
        main.setBlocked(glue, true);
        _donateEth(key, 40 ether);

        // First pump: the unglue refuses, the asset is flagged, the amount is held
        (uint256 first, , IGlueHook.Delivery mode1) = _pumpAndReadDelivery(key);
        assertEq(uint8(mode1), uint8(IGlueHook.Delivery.HELD), "first fall-through held");
        assertEq(pump.heldOf(address(main)), first, "and booked");
        assertEq(main.allowance(address(pump), glue), 0, "the refused burn left no dangling allowance");

        // The token relents — the unglue WOULD now work. The flag doesn't care.
        main.setBlocked(glue, false);

        (uint256 second, address to, IGlueHook.Delivery mode2) = _pumpAndReadDelivery(key);
        assertGt(second, 0, "the second pump bought main");
        assertEq(to, address(pump), "and still settled on the hook");
        assertEq(uint8(mode2), uint8(IGlueHook.Delivery.HELD), "straight to held, probe skipped");
        assertEq(pump.heldOf(address(main)), first + second, "the held ledger accumulates");
        assertEq(main.balanceOf(glue), 0, "the wrapper never saw a wei of it");
    }

    /// B5 — THE FLAG IS PER-ASSET: one weird token being held forever changes nothing for any
    ///      other pool — a glueable main elsewhere still burns through the stick.
    function test_B5_flagIsPerAsset() public {
        BlockingERC20 weird = new BlockingERC20();
        BurnableERC20 sane = new BurnableERC20();

        _deployCore();
        (IPoolManagerMin.PoolKey memory kWeird, ) = _openEthPool(address(weird), address(0));
        weird.setBlocked(stick.wrapperOf(address(weird)), true);
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
        assertEq(stick.wrapperOf(address(fresh)), address(0), "no glue before the declaration");
        _openEthPool(address(fresh), address(0));
        assertTrue(stick.wrapperOf(address(fresh)) != address(0), "the declaration ensured the glue");

        // An already-glued main: the ensure is skipped (the registry read short-circuits)
        stick.ensureWrapper(address(preGlued));
        uint256 ensuresBefore = stick.ensureCalls();
        _openEthPool(address(preGlued), address(0));
        assertEq(stick.ensureCalls(), ensuresBefore, "no redundant ensure on a glued main");
    }

    /// B10 — A WRAPPER MAIN (NFT mode) PARKS: the main is the ERC20 face of a wrapped collection,
    ///       so its `unglue` can never burn it (whole units only, and the empty-collateral shape
    ///       is rejected). The declaration recognises it through the Stick's registry — no ensure
    ///       is even attempted — and the burn is a PARK: the shares move to the wrapper's own
    ///       address, which Glue counts as out of circulation. Nothing is held, no unglue runs.
    function test_B10_nftWrapperMainParks() public {
        _deployCore();
        MockGlueWrapper w = _wrapperMain(false);
        uint256 ensuresBefore = stick.ensureCalls();

        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(w), address(0));
        assertEq(stick.ensureCalls(), ensuresBefore, "a wrapper main is never ensured (wrap-of-wrap)");
        _donateEth(key, 20 ether);

        uint256 supplyBefore = w.totalSupply();
        (uint256 bought, address to, IGlueHook.Delivery mode) = _pumpAndReadDelivery(key);

        assertGt(bought, 0, "the pump bought wrapper shares");
        assertEq(to, address(w), "the delivery names the wrapper itself");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.BURNED), "as a burn");
        assertEq(w.parkedShares(), bought, "every share is PARKED on the wrapper");
        assertEq(w.totalSupply(), supplyBefore, "parking destroys nothing (Glue's oracle subtracts it)");
        assertEq(w.balanceOf(address(pump)), 0, "nothing stuck to the hook");
        assertEq(pump.heldOf(address(w)), 0, "nothing held");
        assertEq(pump.obligationOf(address(w)), 0, "nothing owed");
        assertEq(w.unglueCalls(), 0, "the wrapper's unglue never ran");
        assertEq(stick.unglueCalls(), 0, "nor the stick's");
    }

    /// B11 — A WRAPPER MAIN (ERC20 mode) PARKS IDENTICALLY: the mode is irrelevant to the hook —
    ///       what matters is that the main IS its own glue — and the park accumulates across
    ///       pumps, never flagging the asset.
    function test_B11_erc20WrapperMainParks() public {
        _deployCore();
        MockGlueWrapper w = _wrapperMain(true);
        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(w), address(0));
        _donateEth(key, 40 ether);

        (uint256 first, address to1, IGlueHook.Delivery mode1) = _pumpAndReadDelivery(key);
        (uint256 second, address to2, IGlueHook.Delivery mode2) = _pumpAndReadDelivery(key);

        assertGt(first, 0, "first pump bought");
        assertGt(second, 0, "second pump bought");
        assertEq(to1, address(w), "first parked on the wrapper");
        assertEq(to2, address(w), "second parked on the wrapper");
        assertEq(uint8(mode1), uint8(IGlueHook.Delivery.BURNED), "as a burn");
        assertEq(uint8(mode2), uint8(IGlueHook.Delivery.BURNED), "as a burn");
        assertEq(w.parkedShares(), first + second, "the park accumulates");
        assertEq(pump.heldOf(address(w)), 0, "never held");
        assertEq(w.unglueCalls(), 0, "no unglue on a wrapper main");
    }

    /// B12 — A GLUED ERC20 MAIN BURNS THROUGH ITS WRAPPER DIRECTLY: the hook approves the EXACT
    ///       amount to the main's wrapper and calls the wrapper's own `unglue` (no Stick hop). The
    ///       allowance is consumed to zero, the wrapper's counter moves, the Stick's does not, and
    ///       a token without `burn()` is dead-routed inside the glue.
    function test_B12_gluedMainDirectWrapperUnglue() public {
        MockERC20 main = new MockERC20("Main", "MN", 18);
        _deployCore();
        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(main), address(0));
        MockGlueWrapper glue = MockGlueWrapper(stick.wrapperOf(address(main)));
        assertTrue(address(glue) != address(0), "the declaration ensured the glue");
        assertTrue(address(glue) != address(main), "and it is not the main itself");
        _donateEth(key, 20 ether);

        (uint256 bought, address to, IGlueHook.Delivery mode) = _pumpAndReadDelivery(key);

        assertGt(bought, 0, "bought main");
        assertEq(to, address(glue), "the delivery names the wrapper");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.BURNED), "as a Glue burn");
        assertEq(glue.unglueCalls(), 1, "exactly one wrapper unglue");
        assertEq(stick.unglueCalls(), 0, "the stick's unglue is out of the path");
        assertEq(main.allowance(address(pump), address(glue)), 0, "the exact allowance was consumed whole");
        assertEq(main.balanceOf(DEAD), bought, "dead-routed inside the glue (no burn())");
        assertEq(main.balanceOf(address(pump)), 0, "nothing stuck to the hook");
        assertEq(pump.heldOf(address(main)), 0, "nothing held");
    }

    /// B13 — LAZY GLUE: the Stick refuses the main at declaration (best effort, the pool opens with
    ///       no glue recorded). Once the Stick admits it, the FIRST burn ensures the glue, records
    ///       it and burns through it. A main the Stick keeps refusing is flagged unburnable at its
    ///       first burn and settles to held — without probing the Stick ever again.
    function test_B13_lazyGlue() public {
        MockERC20 late = new MockERC20("Late", "LATE", 18);
        MockERC20 never = new MockERC20("Never", "NVR", 18);
        _deployCore();
        stick.setRefuse(address(late), true);
        stick.setRefuse(address(never), true);

        (IPoolManagerMin.PoolKey memory kLate, ) = _openEthPool(address(late), address(0));
        (IPoolManagerMin.PoolKey memory kNever, ) = _openEthPool(address(never), address(0));
        assertEq(stick.wrapperOf(address(late)), address(0), "no glue at declaration");
        assertEq(stick.wrapperOf(address(never)), address(0), "no glue at declaration");
        _donateEth(kLate, 20 ether);
        _donateEth(kNever, 40 ether);

        // The Stick relents on `late`: the first burn glues it and burns through the new wrapper
        stick.setRefuse(address(late), false);
        uint256 ensuresBefore = stick.ensureCalls();
        (uint256 bought, address to, IGlueHook.Delivery mode) = _pumpAndReadDelivery(kLate);
        MockGlueWrapper glue = MockGlueWrapper(stick.wrapperOf(address(late)));
        assertEq(stick.ensureCalls(), ensuresBefore + 1, "the burn ensured the glue once");
        assertTrue(address(glue) != address(0), "and the glue now exists");
        assertEq(to, address(glue), "the delivery went through it");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.BURNED), "as a Glue burn");
        assertEq(glue.unglueCalls(), 1, "one wrapper unglue");
        assertEq(late.balanceOf(DEAD), bought, "dead-routed inside the glue");
        assertEq(pump.heldOf(address(late)), 0, "nothing held");

        // `never` stays refused: the first burn's lazy ensure fails, the asset is flagged and
        // held. Even once the Stick relents, the flag holds: the Stick is never probed again (an
        // ensure now WOULD create the glue — none appears)
        (uint256 first, , IGlueHook.Delivery m1) = _pumpAndReadDelivery(kNever);
        assertEq(uint8(m1), uint8(IGlueHook.Delivery.HELD), "refused: held");
        assertEq(stick.wrapperOf(address(never)), address(0), "no glue could be created");
        stick.setRefuse(address(never), false);
        (uint256 second, , IGlueHook.Delivery m2) = _pumpAndReadDelivery(kNever);
        assertEq(uint8(m2), uint8(IGlueHook.Delivery.HELD), "straight to held");
        assertEq(stick.wrapperOf(address(never)), address(0), "flagged: the Stick was never asked again");
        assertEq(pump.heldOf(address(never)), first + second, "both burns held");
        assertEq(never.balanceOf(address(pump)), first + second, "custody covers the whole hold");
    }

    /// B14 — EVERY BURN-INTENT LEG OF A WRAPPER MAIN PARKS, launched in one transaction: the
    ///       harvest's burn share and the pot output's burn share merge into ONE park on the
    ///       wrapper, the pot's live-recipient rest is delivered, nothing is held.
    function test_B14_wrapperMainBurnLegsPark() public {
        _deployCore();
        MockGlueWrapper w = _wrapperMain(false);
        address treasury = makeAddr("treasury");
        IPoolManagerMin.PoolKey memory key = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(w), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });

        // The launcher seeds the program: wrapper shares from its allowance, ETH from value
        w.mint(address(this), 1_000_000e18);
        w.approve(address(pump), type(uint256).max);
        IGlueHook.ProgramConfig memory cfg = IGlueHook.ProgramConfig({
            buybackShareWad: 0,
            burnShareWad: uint64(5e17),
            compoundShareWad: 0,
            potCompoundShareWad: 0,
            potBurnShareWad: uint64(5e17),
            publicHarvest: true,
            secondaryRecipient: makeAddr("secR"),
            mainRecipient: makeAddr("mainR"),
            minMain: type(uint256).max, // disarmed while the fees accrue
            minSecondary: type(uint256).max
        });
        pump.launchPool{value: 150 ether}(
            key, LAUNCH_SQRT, address(w), treasury, TICK_LO, TICK_HI, _launchLiquidity(), address(this), cfg
        );
        _mintTo(address(w), address(helper), 20_000_000e18);

        // Trade both ways (pot still empty, so no pump rides behind either; the sell pays a MAIN-side fee),
        // then fund the pot and ARM: the measured buy harvests both sides' fees AND pumps
        helper.swap(key, true, -int256(2 ether));
        helper.swap(key, false, -int256(2_000e18));
        _donateEth(key, 20 ether);
        cfg.minMain = 1;
        cfg.minSecondary = 1;
        pump.setProgramConfig(keccak256(abi.encode(key)), cfg);

        uint256 parkedBefore = w.parkedShares();
        vm.recordLogs();
        helper.swap(key, true, -int256(1 ether)); // a buy: auto-harvest + pump in one frame
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool harvested, , , uint256 burned, ) = _lastHarvested(logs);
        (bool pumped, , uint256 bought) = _lastPumped(logs);
        ( , address to, uint256 amount, IGlueHook.Delivery mode) = _lastDelivered(logs);

        assertTrue(harvested && pumped, "the swap carried both a harvest and a pump");
        assertGt(burned, 0, "the harvest had a burn share");
        uint256 potBurn = (bought * 5e17) / 1e18;
        assertEq(w.parkedShares() - parkedBefore, burned + potBurn, "both burn legs parked in one walk");
        assertEq(to, address(w), "the last delivery is the park");
        assertEq(amount, burned + potBurn, "for exactly the merged burn legs");
        assertEq(uint8(mode), uint8(IGlueHook.Delivery.BURNED), "as a burn");
        assertEq(w.balanceOf(treasury), bought - potBurn, "the pot's rest reached the live recipient");
        assertEq(pump.heldOf(address(w)), 0, "nothing held");
        assertEq(w.unglueCalls(), 0, "no unglue on a wrapper main");
    }

    /// B15 — ISOLATION: the classification is per main. A wrapper main parks on itself while a
    ///       plain glued main in another pool burns through its own wrapper — neither path leaks
    ///       into the other's ledgers.
    function test_B15_wrapperAndPlainMainsIsolated() public {
        BurnableERC20 plain = new BurnableERC20();
        _deployCore();
        MockGlueWrapper w = _wrapperMain(false);
        (IPoolManagerMin.PoolKey memory kW, ) = _openEthPool(address(w), address(0));
        (IPoolManagerMin.PoolKey memory kP, ) = _openEthPool(address(plain), address(0));
        MockGlueWrapper glue = MockGlueWrapper(stick.wrapperOf(address(plain)));
        _donateEth(kW, 20 ether);
        _donateEth(kP, 20 ether);

        uint256 plainSupply = plain.totalSupply();
        (uint256 bW, address toW, IGlueHook.Delivery mW) = _pumpAndReadDelivery(kW);
        (uint256 bP, address toP, IGlueHook.Delivery mP) = _pumpAndReadDelivery(kP);

        assertEq(toW, address(w), "wrapper main: parked on itself");
        assertEq(uint8(mW), uint8(IGlueHook.Delivery.BURNED), "as a burn");
        assertEq(w.parkedShares(), bW, "the park holds every share");
        assertEq(toP, address(glue), "plain main: burned through its wrapper");
        assertEq(uint8(mP), uint8(IGlueHook.Delivery.BURNED), "as a burn");
        assertEq(plain.totalSupply(), plainSupply - bP, "for real");
        assertEq(glue.unglueCalls(), 1, "one unglue on the plain main's glue");
        assertEq(w.unglueCalls(), 0, "none on the wrapper main");
        assertEq(pump.heldOf(address(w)) | pump.heldOf(address(plain)), 0, "nothing held anywhere");
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
