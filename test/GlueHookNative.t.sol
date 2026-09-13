// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {GlueHookFixture} from "./helpers/GlueHookFixture.sol";
import {IGlueHook} from "../contracts/interfaces/IGlueHook.sol";
import {IPoolManagerMin} from "../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockGlueStick} from "./mocks/MockGlueStick.sol";
import {MockHookedEngine} from "./mocks/MockHookedEngine.sol";

/**
 * @title  GlueHookNative — NATIVE PROGRAMS: the Glue LP-engine integration.
 * @notice N1–N16 against the real PoolManager. A program created by an address the GlueStick's
 *         registry reports as a REGISTERED LP engine is stamped `native`: its owner and both
 *         remainder recipients are pinned to that engine, and every harvest — in-swap, manual, and
 *         the harvest-first inside the program's own add / remove — advances the per-`(pool,
 *         asset)` DELIVERED ledger by exactly what landed on the engine and reports it through
 *         `recordHarvest` at the carrying call's gas. The suite drives the hook AS the engine (a mock
 *         that records the callback and can misbehave on demand) and bends the Stick's registry
 *         answer to prove creation is never blocked by it.
 *
 *   N1  stamping through `launchPool`: the passed owner and recipients are IGNORED, the engine is
 *       owner, operator and both recipients, and creation itself reports nothing
 *   N2  stamping through `addLiquidityAdvanced` and the plain `addLiquidity` (engine as pot admin)
 *   N3  a non-registered creator — a stranger, or the very same engine once expelled from the
 *       registry — takes the plain path: not native, no report, a ledger that stays zero
 *   N4  a codeless / reverting / short-answering / garbage-answering Stick never blocks creation:
 *       the program is simply not native; the truthful Stick stamps it (control)
 *   N5  the property is pinned: `transferProgramOwnership` refuses a new owner AND a surrender,
 *       while a non-native program still transfers
 *   N6  the rules stay editable — shares, `publicHarvest`, the mins, the operator hand-off — but
 *       moving either recipient off the engine is `BadConfig`
 *   N7  the manual harvest delivers the EXACT remainder legs to the engine; the callback sees
 *       `msg.sender == hook` and the exact `(poolId, dMain, dSec)`; the ledger equals what landed;
 *       `HarvestRecorded(..., true)`; a frame with nothing pending reports nothing
 *   N8  the `owed` path: an engine refusing the native push is booked, the callback reports ZERO
 *       for that leg and the ledger stands; the later frame that folds the backlog in reports
 *       `push + backlog` and advances the ledger by exactly that
 *   N9  a REVERTING engine: `recorded == false`, the ledger still advances, the money still landed,
 *       the harvest still settled — and the same inside a carrying swap, which is unaffected
 *   N10 a GAS-BURNING engine is CHARGED, not bounded (no stipend): a generous budget finishes
 *       the frame with the burn on the caller's bill, a tight one fails the harvest out of gas
 *       on the engine's own program only, and the next honest harvest lands
 *   N11 a RE-ENTERING engine is thrown out by the hook's guard (`Reentrancy`) both from a manual
 *       harvest and from inside a swap; the report completes and the swap succeeds
 *   N12 the armed in-swap auto-harvest fires the callback inside the swap — behind a buy and
 *       behind a sell — and a disarmed program never does
 *   N13 the harvest-first inside `addProgramLiquidity` / `removeProgramLiquidity` reports too, to
 *       the wei, and the principal never pollutes the report
 *   N14 storage: `native` is packed in slot 0 of the program next to `exists / publicHarvest /
 *       armed`, `owner` opens slot 1 (`vm.load`)
 *   N15 EXACTLY ONCE across a mixed history of succeeding and failing callbacks: the ledger equals
 *       the engine's cumulative balance delta at every step, and ledger − recorded == the legs of
 *       exactly the frames whose callback failed (what a reconcile credits)
 *   N16 the report stays out of the pot's and the pump's way: a pump behind the carrying swap, a
 *       buyback share fuelling the pot and a burn share all settle as on a casual pool, and the
 *       report carries only the remainder legs
 */
contract GlueHookNative is GlueHookFixture {
    MockERC20 token;
    MockHookedEngine engine;
    IPoolManagerMin.PoolKey key;
    bytes32 id;
    address alice;
    address carol;
    address dave;

    uint128 constant SEED_LIQ = 1e21;
    uint256 constant MAX = type(uint256).max;
    bytes32 constant RECORDED_SIG = keccak256("HarvestRecorded(bytes32,address,uint256,uint256,bool)");

    function setUp() public {
        _deployCore();
        token = new MockERC20("Main", "MAIN", 18);
        engine = new MockHookedEngine(pump);
        stick.setRegisteredEngine(address(engine), true);
        token.mint(address(engine), 10_000_000e18);
        engine.exec(address(token), abi.encodeCall(token.approve, (address(pump), MAX)));
        vm.deal(address(engine), 1_000 ether);
        token.mint(address(this), 10_000_000e18);
        token.approve(address(pump), MAX);
        alice = makeAddr("alice");
        carol = makeAddr("carol");
        dave = makeAddr("dave");
        key = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(token), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        id = keccak256(abi.encode(key));
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────

    function _cfg(uint64 bb, uint64 burn, address secR, address mainR, uint256 mm, uint256 ms)
        internal pure returns (IGlueHook.ProgramConfig memory)
    {
        return IGlueHook.ProgramConfig({
            buybackShareWad: bb,
            burnShareWad: burn,
            compoundShareWad: 0,
            potCompoundShareWad: 0,
            potBurnShareWad: 0,
            publicHarvest: false,
            secondaryRecipient: secR,
            mainRecipient: mainR,
            minMain: mm,
            minSecondary: ms
        });
    }

    /// @dev Zero shares, disarmed, recipients = the engine: the report equals the gross fees.
    function _plain() internal view returns (IGlueHook.ProgramConfig memory) {
        return _cfg(0, 0, address(engine), address(engine), MAX, MAX);
    }

    /// @dev The engine launches the pool in ONE transaction — becoming pot admin, program owner and
    ///      (by the stamp) both recipients — with `owner`/recipients as PASSED to prove they are
    ///      ignored. Then the helper is funded so it can trade.
    function _launchAsEngine(address ownerArg, IGlueHook.ProgramConfig memory cfg) internal {
        engine.exec{value: 60 ether}(
            address(pump),
            abi.encodeCall(
                IGlueHook.launchPool,
                (key, LAUNCH_SQRT, address(token), address(0), TICK_LO, TICK_HI, SEED_LIQ, ownerArg, cfg)
            )
        );
        token.mint(address(helper), 20_000_000e18);
    }

    /// @dev The three-step shape with the engine as pot admin: initialise, declare, then `advanced`
    ///      (or the plain `addLiquidity` when `cfg.minMain == 0` is used as the sentinel).
    function _threeStepAsEngine(bool advanced, IGlueHook.ProgramConfig memory cfg) internal {
        engine.exec(POOL_MANAGER, abi.encodeCall(IPoolManagerMin.initialize, (key, LAUNCH_SQRT)));
        engine.exec(address(pump), abi.encodeCall(IGlueHook.initPot, (key, address(token), address(0))));
        if (advanced) {
            engine.exec{value: 60 ether}(
                address(pump),
                abi.encodeCall(IGlueHook.addLiquidityAdvanced, (key, TICK_LO, TICK_HI, SEED_LIQ, alice, cfg))
            );
        } else {
            engine.exec{value: 60 ether}(
                address(pump), abi.encodeCall(IGlueHook.addLiquidity, (key, TICK_LO, TICK_HI, SEED_LIQ, alice))
            );
        }
        token.mint(address(helper), 20_000_000e18);
    }

    function _harvestAsEngine() internal {
        engine.exec(address(pump), abi.encodeCall(IGlueHook.harvest, (key)));
    }

    function _setConfigAsEngine(IGlueHook.ProgramConfig memory cfg) internal {
        engine.exec(address(pump), abi.encodeCall(IGlueHook.setProgramConfig, (id, cfg)));
    }

    /// @dev Trade both directions so BOTH fee sides accrue on the program's position.
    function _genFees() internal {
        helper.swap(key, true, -int256(5 ether));
        helper.swap(key, false, -int256(4_000e18));
    }

    /// @dev The LAST `HarvestRecorded` in a recorded window, or `found = false`.
    function _lastRecorded(Vm.Log[] memory logs)
        internal view
        returns (bool found, address eng, uint256 dMain, uint256 dSec, bool recorded)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pump) || logs[i].topics[0] != RECORDED_SIG) continue;
            found = true;
            assertEq(logs[i].topics[1], id, "the report names the pool");
            eng = address(uint160(uint256(logs[i].topics[2])));
            (dMain, dSec, recorded) = abi.decode(logs[i].data, (uint256, uint256, bool));
        }
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

    function _assertNativeStamp() internal view {
        IGlueHook.Program memory g = pump.programOf(id);
        assertTrue(g.native, "stamped native");
        assertEq(g.owner, address(engine), "the engine owns the program");
        assertEq(g.operator, address(engine), "and starts as its operator");
        assertEq(g.mainRecipient, address(engine), "main remainder pinned to the engine");
        assertEq(g.secondaryRecipient, address(engine), "secondary remainder pinned to the engine");
    }

    // ── N1–N4: the stamp ────────────────────────────────────────────────────────────

    /// N1 — `launchPool` by a registered engine: whatever owner and recipients were passed, the
    ///      program is the engine's on all three seats. Creation itself reports nothing.
    function test_N1_stampThroughLaunch() public {
        vm.recordLogs();
        _launchAsEngine(alice, _cfg(uint64(3e17), uint64(2e17), carol, dave, MAX, MAX));
        (bool found, , , , ) = _lastRecorded(vm.getRecordedLogs());

        _assertNativeStamp();
        assertFalse(found, "creation reports nothing");
        assertEq(pump.programOf(id).buybackShareWad, 3e17, "the passed shares stand");
        assertEq(pump.programOf(id).burnShareWad, 2e17, "both of them");
        assertEq(pump.deliveredCumOf(id, ETH), 0, "ledger starts at zero");
        assertEq(pump.deliveredCumOf(id, address(token)), 0, "on both assets");
        assertEq(pump.potOf(id).admin, address(engine), "the engine is the pot admin too");
    }

    /// N2 — the three-step shapes: `addLiquidityAdvanced` with foreign recipients, and the plain
    ///      `addLiquidity` (whose default recipients are the passed owner) — both stamp the engine.
    function test_N2_stampThroughAdds() public {
        _threeStepAsEngine(true, _cfg(0, 0, carol, dave, MAX, MAX));
        _assertNativeStamp();

        // A second pool for the plain entry
        token = new MockERC20("Main2", "MAIN2", 18);
        token.mint(address(engine), 10_000_000e18);
        engine.exec(address(token), abi.encodeCall(token.approve, (address(pump), MAX)));
        key = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(token), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        id = keccak256(abi.encode(key));
        _threeStepAsEngine(false, _plain());
        _assertNativeStamp();
    }

    /// N3 — a stranger's program, and the engine's own once EXPELLED from the registry, are plain:
    ///      not native, freely transferable, no report on harvest, ledger zero.
    function test_N3_nonNativeTakesThePlainPath() public {
        // A stranger (the test contract) launches
        pump.launchPool{value: 60 ether}(
            key, LAUNCH_SQRT, address(token), address(0), TICK_LO, TICK_HI, SEED_LIQ, address(this),
            _cfg(0, 0, carol, dave, MAX, MAX)
        );
        token.mint(address(helper), 20_000_000e18);
        IGlueHook.Program memory g = pump.programOf(id);
        assertFalse(g.native, "a stranger is not native");
        assertEq(g.mainRecipient, dave, "recipients as passed");
        assertEq(g.secondaryRecipient, carol, "both of them");

        _genFees();
        vm.recordLogs();
        pump.harvest(key);
        (bool found, , , , ) = _lastRecorded(vm.getRecordedLogs());
        assertFalse(found, "a non-native harvest reports nothing");
        assertEq(pump.deliveredCumOf(id, ETH), 0, "and its ledger stays zero");
        assertEq(pump.deliveredCumOf(id, address(token)), 0, "on both assets");
        pump.transferProgramOwnership(id, alice);
        assertEq(pump.programOf(id).owner, alice, "and it still transfers");

        // The engine itself, expelled from the registry, is a stranger too
        stick.setRegisteredEngine(address(engine), false);
        token = new MockERC20("Main2", "MAIN2", 18);
        token.mint(address(engine), 10_000_000e18);
        engine.exec(address(token), abi.encodeCall(token.approve, (address(pump), MAX)));
        key = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(token), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        id = keccak256(abi.encode(key));
        _launchAsEngine(alice, _cfg(0, 0, carol, dave, MAX, MAX));
        g = pump.programOf(id);
        assertFalse(g.native, "an unregistered engine is not native");
        assertEq(g.owner, alice, "the passed owner stands");
        assertEq(g.mainRecipient, dave, "and the passed recipients");
    }

    /// N4 — the registry probe is TOLERANT: a codeless Stick, a reverting one, a one-byte answer
    ///      and a non-boolean word all read as "not native" and never block creation. Only the
    ///      truthful `true` stamps (control).
    function test_N4_stickShapesNeverBlockCreation() public {
        // Four pools, four Stick moods; a fresh main each time
        MockGlueStick.RegistryMode[3] memory modes = [
            MockGlueStick.RegistryMode.Revert, MockGlueStick.RegistryMode.Short, MockGlueStick.RegistryMode.Garbage
        ];
        for (uint256 i; i < 4; ++i) {
            token = new MockERC20("M", "M", 18);
            token.mint(address(engine), 10_000_000e18);
            engine.exec(address(token), abi.encodeCall(token.approve, (address(pump), MAX)));
            key = IPoolManagerMin.PoolKey({
                currency0: ETH, currency1: address(token), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
            });
            id = keccak256(abi.encode(key));
            if (i < 3) {
                stick.setRegistryMode(modes[i]);
            } else {
                // Codeless: wipe the Stick's code entirely (the burn path is best-effort too)
                vm.etch(GLUE_STICK, "");
            }
            _launchAsEngine(alice, _plain());
            IGlueHook.Program memory g = pump.programOf(id);
            assertFalse(g.native, "a misbehaving Stick never stamps");
            assertEq(g.owner, alice, "creation went through on the plain path");
        }

        // Control: the truthful Stick stamps (re-etched code; the storage — including the last
        // mood — survived the wipe, so the mood is reset explicitly)
        deployCodeTo("MockGlueStick.sol:MockGlueStick", "", GLUE_STICK);
        stick = MockGlueStick(GLUE_STICK);
        stick.setRegistryMode(MockGlueStick.RegistryMode.Normal);
        stick.setRegisteredEngine(address(engine), true);
        token = new MockERC20("M", "M", 18);
        token.mint(address(engine), 10_000_000e18);
        engine.exec(address(token), abi.encodeCall(token.approve, (address(pump), MAX)));
        key = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(token), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        id = keccak256(abi.encode(key));
        _launchAsEngine(alice, _plain());
        _assertNativeStamp();
    }

    // ── N5–N6: pinning ──────────────────────────────────────────────────────────────

    /// N5 — the property is pinned: no new owner, no surrender. A non-native program (the same
    ///      engine, un-registered at creation) still transfers.
    function test_N5_ownershipPinned() public {
        _launchAsEngine(alice, _plain());

        vm.expectRevert(IGlueHook.NotAllowed.selector);
        engine.exec(address(pump), abi.encodeCall(IGlueHook.transferProgramOwnership, (id, alice)));
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        engine.exec(address(pump), abi.encodeCall(IGlueHook.transferProgramOwnership, (id, address(0))));
        // A stranger is refused as everywhere else
        vm.prank(alice);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.transferProgramOwnership(id, alice);
        assertEq(pump.programOf(id).owner, address(engine), "still the engine's");

        // Non-native control: expel, create, transfer
        stick.setRegisteredEngine(address(engine), false);
        token = new MockERC20("Main2", "MAIN2", 18);
        token.mint(address(engine), 10_000_000e18);
        engine.exec(address(token), abi.encodeCall(token.approve, (address(pump), MAX)));
        key = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(token), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        id = keccak256(abi.encode(key));
        _launchAsEngine(address(engine), _plain());
        assertFalse(pump.programOf(id).native, "plain");
        engine.exec(address(pump), abi.encodeCall(IGlueHook.transferProgramOwnership, (id, alice)));
        assertEq(pump.programOf(id).owner, alice, "a plain program transfers");
    }

    /// N6 — the RULES stay the engine's to edit (shares, `publicHarvest`, the mins) and the operator
    ///      seat can be handed off; moving either recipient off the engine is `BadConfig`.
    function test_N6_rulesEditableRecipientsPinned() public {
        _launchAsEngine(alice, _plain());

        // Shares, gate and mins move
        IGlueHook.ProgramConfig memory cfg = _cfg(uint64(4e17), uint64(1e17), address(engine), address(engine), 1, 1);
        cfg.publicHarvest = true;
        _setConfigAsEngine(cfg);
        IGlueHook.Program memory g = pump.programOf(id);
        assertEq(g.buybackShareWad, 4e17, "buyback share edited");
        assertEq(g.burnShareWad, 1e17, "burn share edited");
        assertTrue(g.publicHarvest, "gate opened");
        assertEq(g.minMain, 1, "mins armed");
        assertTrue(g.armed, "and the armed flag follows");

        // Either recipient off the engine: refused
        vm.expectRevert(IGlueHook.BadConfig.selector);
        _setConfigAsEngine(_cfg(0, 0, carol, address(engine), MAX, MAX));
        vm.expectRevert(IGlueHook.BadConfig.selector);
        _setConfigAsEngine(_cfg(0, 0, address(engine), dave, MAX, MAX));
        vm.expectRevert(IGlueHook.BadConfig.selector);
        _setConfigAsEngine(_cfg(0, 0, address(0), address(0), MAX, MAX));

        // The operator seat hands off; the operator edits under the same pin
        engine.exec(address(pump), abi.encodeCall(IGlueHook.setProgramOperator, (id, alice)));
        assertEq(pump.programOf(id).operator, alice, "operator handed off");
        vm.prank(alice);
        pump.setProgramConfig(id, _cfg(uint64(2e17), 0, address(engine), address(engine), MAX, MAX));
        assertEq(pump.programOf(id).buybackShareWad, 2e17, "the operator edited");
        vm.prank(alice);
        vm.expectRevert(IGlueHook.BadConfig.selector);
        pump.setProgramConfig(id, _cfg(0, 0, alice, address(engine), MAX, MAX));
        // And the engine, no longer operator, cannot edit the rules (property != rules)
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        _setConfigAsEngine(_plain());
    }

    // ── N7–N11: the report ──────────────────────────────────────────────────────────

    /// N7 — MANUAL HARVEST, exact: the engine receives the exact remainder legs, the callback sees
    ///      `msg.sender == hook` and the exact `(poolId, dMain, dSec)`, the ledger equals what
    ///      landed, and `HarvestRecorded(..., true)` carries the same numbers. A second harvest
    ///      with nothing pending reports nothing.
    function test_N7_manualHarvestExactReport() public {
        _launchAsEngine(alice, _plain());
        _genFees();
        uint256 ethBefore = address(engine).balance;
        uint256 tokBefore = token.balanceOf(address(engine));

        vm.recordLogs();
        _harvestAsEngine();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool h, uint256 fMain, uint256 fSec, , ) = _lastHarvested(logs);
        (bool found, address eng, uint256 dMain, uint256 dSec, bool recorded) = _lastRecorded(logs);

        assertTrue(h && found, "harvested and reported");
        assertGt(fMain, 0, "token fees accrued");
        assertGt(fSec, 0, "ETH fees accrued");
        assertEq(address(engine).balance - ethBefore, fSec, "the whole ETH side landed on the engine");
        assertEq(token.balanceOf(address(engine)) - tokBefore, fMain, "and the whole token side");
        assertEq(eng, address(engine), "reported to the engine");
        assertEq(dMain, fMain, "event: main leg");
        assertEq(dSec, fSec, "event: secondary leg");
        assertTrue(recorded, "event: the callback succeeded");
        assertEq(engine.calls(), 1, "one callback");
        assertEq(engine.lastSender(), address(pump), "from the hook");
        assertEq(engine.lastPoolId(), id, "for this pool");
        assertEq(engine.lastMain(), fMain, "callback: main leg");
        assertEq(engine.lastSec(), fSec, "callback: secondary leg");
        assertEq(pump.deliveredCumOf(id, address(token)), fMain, "ledger: main");
        assertEq(pump.deliveredCumOf(id, ETH), fSec, "ledger: secondary");

        // Nothing pending: nothing lands, nothing is reported
        vm.recordLogs();
        _harvestAsEngine();
        (found, , , , ) = _lastRecorded(vm.getRecordedLogs());
        assertFalse(found, "an empty frame is not reported");
        assertEq(engine.calls(), 1, "no second callback");
    }

    /// N8 — the OWED path: a refused native push is booked and reported as ZERO (the ledger stands
    ///      for that asset); the frame that later folds the backlog in reports `push + backlog`
    ///      and moves the ledger by exactly that — the ledger tracks what LANDED, never gross.
    function test_N8_owedLegReportsWhenItLands() public {
        _launchAsEngine(alice, _plain());
        engine.setRefuseEth(true);
        _genFees();
        uint256 ethBefore = address(engine).balance;

        vm.recordLogs();
        _harvestAsEngine();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, uint256 fMain1, uint256 fSec1, , ) = _lastHarvested(logs);
        (bool found, , uint256 dMain, uint256 dSec, bool recorded) = _lastRecorded(logs);
        assertTrue(found && recorded, "reported");
        assertEq(dMain, fMain1, "the token leg landed and was reported");
        assertEq(dSec, 0, "the refused ETH leg reports ZERO");
        assertEq(pump.owedOf(address(engine), ETH), fSec1, "booked owed in full");
        assertEq(pump.deliveredCumOf(id, ETH), 0, "the ETH ledger did not move");
        assertEq(pump.deliveredCumOf(id, address(token)), fMain1, "the token ledger did");
        assertEq(address(engine).balance, ethBefore, "no ETH landed");

        // The engine relents; the next frame folds the backlog in
        engine.setRefuseEth(false);
        _genFees();
        vm.recordLogs();
        _harvestAsEngine();
        logs = vm.getRecordedLogs();
        (, , uint256 fSec2, , ) = _lastHarvested(logs);
        (, , , dSec, recorded) = _lastRecorded(logs);
        assertTrue(recorded, "reported again");
        assertEq(dSec, fSec2 + fSec1, "push + backlog reported");
        assertEq(address(engine).balance - ethBefore, fSec2 + fSec1, "and that is what landed");
        assertEq(pump.deliveredCumOf(id, ETH), fSec2 + fSec1, "the ledger moved by exactly that");
        assertEq(pump.owedOf(address(engine), ETH), 0, "backlog cleared");
        assertEq(engine.cumSec(), fSec2 + fSec1, "the engine's own sum agrees");
    }

    /// N9 — a REVERTING engine: `recorded == false`, the ledger advances anyway, the legs landed,
    ///      the harvest settled; inside a swap the carrying trade is untouched.
    function test_N9_revertingEngineNeverBubbles() public {
        _launchAsEngine(alice, _plain());
        engine.setMode(MockHookedEngine.Mode.Revert);
        _genFees();
        uint256 ethBefore = address(engine).balance;

        vm.recordLogs();
        _harvestAsEngine();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, uint256 fMain, uint256 fSec, , ) = _lastHarvested(logs);
        (bool found, , uint256 dMain, uint256 dSec, bool recorded) = _lastRecorded(logs);
        assertTrue(found, "the report event fired");
        assertFalse(recorded, "flagged as not recorded");
        assertEq(dMain, fMain, "with the legs it tried to report");
        assertEq(dSec, fSec, "both of them");
        assertEq(engine.calls(), 0, "the engine recorded nothing");
        assertEq(address(engine).balance - ethBefore, fSec, "the money landed regardless");
        assertEq(pump.deliveredCumOf(id, ETH), fSec, "and the ledger advanced regardless");
        assertEq(pump.deliveredCumOf(id, address(token)), fMain, "on both assets");

        // Armed, inside a swap: the swap goes through, the harvest lands, the flag reads false
        _setConfigAsEngine(_cfg(0, 0, address(engine), address(engine), 1, 1));
        _genFees(); // accrue on the first, harvest inside the second
        uint256 ledgerBefore = pump.deliveredCumOf(id, ETH);
        vm.recordLogs();
        (, int256 got) = helper.swap(key, true, -int256(1 ether));
        (found, , , dSec, recorded) = _lastRecorded(vm.getRecordedLogs());
        assertGt(got, 0, "the carrying swap settled");
        assertTrue(found && !recorded, "the in-swap report ran and failed softly");
        assertEq(pump.deliveredCumOf(id, ETH) - ledgerBefore, dSec, "ledger moved by the reported leg");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "the venue stays solvent");
    }

    /// N10 — a GAS-BURNING engine is CHARGED, never bounded: the callback runs at the carrying
    ///       call's gas (no stipend — the callee is a Glue-registered engine, and a fixed number in
    ///       this immutable hook would drift with engine upgrades and chain gas repricings), so a
    ///       burner eats what the call had; the report is flagged `recorded = false`, the leg still
    ///       landed, the ledger is exact. Whether the frame then FINISHES is the EVM's 1/64 rule:
    ///       (a) with a generous budget it does — the burner ate nearly all of it; (b) with a budget
    ///       an honest engine fits in, the harvest fails out of gas — the engine's OWN program, no
    ///       other pool, no ledger moved — and (c) the next well-behaved harvest lands.
    function test_N10_gasBurningEngineIsChargedNotBounded() public {
        _launchAsEngine(alice, _plain());

        // Baseline: a recording engine (second harvest so both frames are warm-ish alike)
        _genFees();
        _harvestAsEngine();
        _genFees();
        uint256 g0 = gasleft();
        _harvestAsEngine();
        uint256 recordCost = g0 - gasleft();
        emit log_named_uint("harvest gas, recording engine", recordCost);

        bytes memory harvestCall =
            abi.encodeCall(MockHookedEngine.exec, (address(pump), abi.encodeCall(IGlueHook.harvest, (key))));

        // (a) GENEROUS budget: the burner gets the call's gas and eats it; the frame still finishes.
        engine.setMode(MockHookedEngine.Mode.BurnGas);
        _genFees();
        uint256 ethBefore = address(engine).balance;
        uint256 budget = 30_000_000;
        vm.recordLogs();
        g0 = gasleft();
        (bool ok, ) = address(engine).call{gas: budget}(harvestCall);
        uint256 burnCost = g0 - gasleft();
        (bool found, , , uint256 dSec, bool recorded) = _lastRecorded(vm.getRecordedLogs());
        assertTrue(ok, "(a) the frame finished: the 1/64 the EVM kept was enough");
        assertTrue(found && !recorded, "(a) the burner failed softly");
        assertGt(dSec, 0, "(a) with a real leg");
        assertEq(address(engine).balance - ethBefore, dSec, "(a) which landed");
        assertGt(burnCost, budget / 2, "(a) the burner was charged the call's gas, not a stipend");
        emit log_named_uint("harvest gas, gas-burning engine (30M budget)", burnCost);

        // (b) A budget an HONEST engine fits in twice over: the burner takes 63/64 of what is left at
        //     the callback and the frame cannot finish on the rest — the harvest fails out of gas.
        //     Its own program, nothing else: no ledger moved, no leg landed, the venue is solvent.
        _genFees();
        uint256 cumBefore = pump.deliveredCumOf(id, ETH);
        ethBefore = address(engine).balance;
        (ok, ) = address(engine).call{gas: recordCost * 2}(harvestCall);
        assertFalse(ok, "(b) the harvest failed out of gas");
        assertEq(pump.deliveredCumOf(id, ETH), cumBefore, "(b) the ledger did not move");
        assertEq(address(engine).balance, ethBefore, "(b) nothing landed");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "(b) the venue stays solvent");

        // (c) The engine behaves again: the pending fees are still in the position and land whole.
        engine.setMode(MockHookedEngine.Mode.Record);
        vm.recordLogs();
        _harvestAsEngine();
        (found, , , dSec, recorded) = _lastRecorded(vm.getRecordedLogs());
        assertTrue(found && recorded, "(c) the next harvest records");
        assertGt(dSec, 0, "(c) and delivers what waited");
    }

    /// N11 — a RE-ENTERING engine: its `harvest` from inside the callback is thrown out by the
    ///       hook's guard, the report completes, and — inside a swap — the swap succeeds.
    function test_N11_reenteringEngineRejected() public {
        _launchAsEngine(alice, _plain());
        engine.setMode(MockHookedEngine.Mode.Reenter);
        engine.setReenterKey(key);

        _genFees();
        vm.recordLogs();
        _harvestAsEngine();
        (bool found, , , , bool recorded) = _lastRecorded(vm.getRecordedLogs());
        assertTrue(found && recorded, "the report completed");
        assertEq(engine.reenterError(), IGlueHook.Reentrancy.selector, "the re-entry hit the guard");
        assertEq(engine.calls(), 1, "one callback");

        // Inside a swap: same rejection, the swap settles
        _setConfigAsEngine(_cfg(0, 0, address(engine), address(engine), 1, 1));
        _genFees();
        engine.setMode(MockHookedEngine.Mode.Reenter); // re-assert after the config edit
        vm.recordLogs();
        (, int256 got) = helper.swap(key, true, -int256(1 ether));
        (found, , , , recorded) = _lastRecorded(vm.getRecordedLogs());
        assertGt(got, 0, "the carrying swap settled");
        assertTrue(found && recorded, "reported inside the swap");
        assertEq(engine.reenterError(), IGlueHook.Reentrancy.selector, "the in-swap re-entry hit the guard too");
    }

    // ── N12–N13: every harvest path ─────────────────────────────────────────────────

    /// N12 — the ARMED auto-harvest reports from inside the carrying swap — behind a buy and behind
    ///       a sell alike — and a disarmed program never reports on a swap.
    function test_N12_autoHarvestReportsInSwap() public {
        _launchAsEngine(alice, _cfg(0, 0, address(engine), address(engine), 1, 1));

        // With 1-wei mins every swap harvests its own fees in its afterSwap; observe a BUY's frame
        helper.swap(key, false, -int256(4_000e18));
        uint256 ledgerBefore = pump.deliveredCumOf(id, ETH);
        vm.recordLogs();
        helper.swap(key, true, -int256(2 ether));
        (bool found, , , uint256 dSec, bool recorded) = _lastRecorded(vm.getRecordedLogs());
        assertTrue(found && recorded, "a buy carried the report");
        assertGt(dSec, 0, "with a real ETH leg");
        assertEq(pump.deliveredCumOf(id, ETH) - ledgerBefore, dSec, "ledger in step");
        assertEq(engine.lastSec(), dSec, "callback in step");

        // And a SELL's frame
        uint256 callsBefore = engine.calls();
        vm.recordLogs();
        helper.swap(key, false, -int256(3_000e18));
        (found, , , , recorded) = _lastRecorded(vm.getRecordedLogs());
        assertTrue(found && recorded, "a sell carried the report");
        assertEq(engine.calls(), callsBefore + 1, "one callback per frame");

        // Disarmed: swaps never report
        _setConfigAsEngine(_plain());
        vm.recordLogs();
        _genFees();
        (found, , , , ) = _lastRecorded(vm.getRecordedLogs());
        assertFalse(found, "a disarmed program never reports on a swap");
    }

    /// N13 — the HARVEST-FIRST inside the program's own add and remove reports too, and the
    ///       principal legs never pollute the report (the remove pays principal to a third party).
    function test_N13_harvestFirstInAddAndRemoveReports() public {
        _launchAsEngine(alice, _plain());

        _genFees();
        uint256 ethBefore = address(engine).balance;
        vm.recordLogs();
        engine.exec{value: 60 ether}(address(pump), abi.encodeCall(IGlueHook.addProgramLiquidity, (key, SEED_LIQ / 2)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool h, uint256 fMain, uint256 fSec, , ) = _lastHarvested(logs);
        (bool found, , uint256 dMain, uint256 dSec, bool recorded) = _lastRecorded(logs);
        assertTrue(h && found && recorded, "the add harvested first and reported");
        assertEq(dMain, fMain, "add: main leg exact");
        assertEq(dSec, fSec, "add: secondary leg exact");
        assertEq(pump.programOf(id).liquidity, SEED_LIQ + SEED_LIQ / 2, "and the liquidity grew");
        // The engine paid principal and got its refund; the harvest leg is the only inflow the
        // ledger counts — checked through the ledger, not the balance, which the add moved
        assertEq(pump.deliveredCumOf(id, ETH), fSec, "ledger: the add's harvest only");
        ethBefore = address(engine).balance;

        _genFees();
        vm.recordLogs();
        engine.exec(address(pump), abi.encodeCall(IGlueHook.removeProgramLiquidity, (key, SEED_LIQ / 2, alice)));
        logs = vm.getRecordedLogs();
        (h, fMain, fSec, , ) = _lastHarvested(logs);
        (found, , dMain, dSec, recorded) = _lastRecorded(logs);
        assertTrue(h && found && recorded, "the remove harvested first and reported");
        assertEq(dMain, fMain, "remove: main leg exact");
        assertEq(dSec, fSec, "remove: secondary leg exact");
        assertEq(address(engine).balance - ethBefore, fSec, "the engine received the harvest leg only");
        assertGt(alice.balance, 0, "the principal went to the third party");
        assertEq(pump.programOf(id).liquidity, SEED_LIQ, "liquidity shrank");
    }

    // ── N14–N16: storage, exactly-once, coexistence ────────────────────────────────

    /// N14 — `native` packs into the program's slot 0 (byte 25, after `liquidity`, the two ticks,
    ///       `exists`, `publicHarvest`, `armed`); `owner` opens slot 1. A plain program reads 0.
    function test_N14_nativePackedInSlotZero() public {
        _launchAsEngine(alice, _plain());
        bytes32 slot0 = keccak256(abi.encode(id, uint256(1))); // _programs is the hook's slot 1
        uint256 w = uint256(vm.load(HOOK_ADDR, slot0));
        assertEq(uint128(w), SEED_LIQ, "bytes 0..15: liquidity");
        assertEq((w >> 176) & 0xff, 1, "byte 22: exists");
        assertEq((w >> 184) & 0xff, 0, "byte 23: publicHarvest");
        assertEq((w >> 192) & 0xff, 0, "byte 24: armed (disarmed config)");
        assertEq((w >> 200) & 0xff, 1, "byte 25: native");
        assertEq(w >> 208, 0, "nothing above it in slot 0");
        uint256 w1 = uint256(vm.load(HOOK_ADDR, bytes32(uint256(slot0) + 1)));
        assertEq(address(uint160(w1)), address(engine), "slot 1 opens with owner");

        // A plain program: byte 25 reads 0
        stick.setRegisteredEngine(address(engine), false);
        token = new MockERC20("Main2", "MAIN2", 18);
        token.mint(address(engine), 10_000_000e18);
        engine.exec(address(token), abi.encodeCall(token.approve, (address(pump), MAX)));
        key = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(token), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        id = keccak256(abi.encode(key));
        _launchAsEngine(address(engine), _plain());
        w = uint256(vm.load(HOOK_ADDR, keccak256(abi.encode(id, uint256(1)))));
        assertEq((w >> 176) & 0xff, 1, "plain: exists");
        assertEq((w >> 200) & 0xff, 0, "plain: not native");
    }

    /// N15 — EXACTLY ONCE over a mixed history: six frames alternating a recording, a reverting
    ///       and a gas-burning engine. At every step the ledger equals the engine's cumulative
    ///       balance delta, and `ledger − engine.cum` is exactly the sum of the legs whose callback
    ///       failed — the amount a reconcile against the ledger credits, nothing more, nothing less.
    function test_N15_exactlyOnceAcrossFailures() public {
        _launchAsEngine(alice, _plain());
        uint256 ethBase = address(engine).balance;
        uint256 tokBase = token.balanceOf(address(engine));
        uint256 missedEth;
        uint256 missedTok;
        MockHookedEngine.Mode[3] memory moods =
            [MockHookedEngine.Mode.Record, MockHookedEngine.Mode.Revert, MockHookedEngine.Mode.BurnGas];

        for (uint256 i; i < 6; ++i) {
            engine.setMode(moods[i % 3]);
            _genFees();
            vm.recordLogs();
            _harvestAsEngine();
            (bool found, , uint256 dMain, uint256 dSec, bool recorded) = _lastRecorded(vm.getRecordedLogs());
            assertTrue(found, "every frame reports");
            assertEq(recorded, moods[i % 3] == MockHookedEngine.Mode.Record, "the flag follows the mood");
            if (!recorded) {
                missedEth += dSec;
                missedTok += dMain;
            }
            assertEq(pump.deliveredCumOf(id, ETH), address(engine).balance - ethBase, "ledger == what landed (ETH)");
            assertEq(
                pump.deliveredCumOf(id, address(token)), token.balanceOf(address(engine)) - tokBase,
                "ledger == what landed (token)"
            );
            assertEq(pump.deliveredCumOf(id, ETH) - engine.cumSec(), missedEth, "ledger - recorded == missed (ETH)");
            assertEq(
                pump.deliveredCumOf(id, address(token)) - engine.cumMain(), missedTok, "ledger - recorded == missed (token)"
            );
        }
        assertEq(engine.calls(), 2, "two of six callbacks landed");
        assertGt(missedEth, 0, "the failing frames carried real value");
    }

    /// N16 — the report keeps OUT of the pot's and the pump's way: with a buyback share, a burn
    ///       share and a funded pot, the in-swap frame pumps, fuels, burns and reports — the report
    ///       carrying the REMAINDER legs only, the ledger matching what reached the engine.
    function test_N16_reportCarriesRemainderOnly() public {
        _launchAsEngine(alice, _cfg(uint64(4e17), uint64(25e16), address(engine), address(engine), 1, 1));
        _donateEth(key, 30 ether);
        helper.swap(key, false, -int256(4_000e18)); // accrue
        uint256 ethBefore = address(engine).balance;
        uint256 tokBefore = token.balanceOf(address(engine));
        uint256 potBefore = pump.potOf(id).balance;
        uint256 deadBefore = token.balanceOf(DEAD);

        vm.recordLogs();
        helper.swap(key, true, -int256(3 ether));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool h, uint256 fMain, uint256 fSec, uint256 burned, uint256 fueled) = _lastHarvested(logs);
        (bool found, , uint256 dMain, uint256 dSec, bool recorded) = _lastRecorded(logs);
        (bool pumped, uint256 spent, ) = _lastPumped(logs);

        assertTrue(h && found && recorded && pumped, "harvest, report and pump all ran in one frame");
        assertEq(fueled, (fSec * 4e17) / 1e18, "the pot's share is the WAD floor");
        assertEq(burned, (fMain * 25e16) / 1e18, "and so is the burn's");
        assertEq(dSec, fSec - fueled, "the report carries the ETH remainder only");
        assertEq(dMain, fMain - burned, "and the token remainder only");
        assertEq(address(engine).balance - ethBefore, dSec, "which is what landed");
        assertEq(token.balanceOf(address(engine)) - tokBefore, dMain, "on both sides");
        assertEq(pump.potOf(id).balance, potBefore + fueled - spent, "pot: fuelled by the split, debited by the pump");
        assertGe(token.balanceOf(DEAD) - deadBefore, burned, "the burn leg reached dead");
        assertEq(pump.deliveredCumOf(id, ETH), dSec, "ledger: remainder only");
        assertGe(address(pump).balance, pump.obligationOf(ETH), "solvent");
    }
}
