// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {console2} from "forge-std/console2.sol";
import {GlueHookFixture} from "./helpers/GlueHookFixture.sol";
import {IGlueHook} from "../contracts/interfaces/IGlueHook.sol";
import {IPoolManagerMin} from "../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookedEngine} from "./mocks/MockHookedEngine.sol";

/**
 * @title  GlueHookGas -- deterministic gas measurements for the audit's cost table.
 * @notice G1-G5 measure every user-facing entry and the swap overhead under each circumstance the
 *         hook can add work to a trade: idle, pump behind a buy, pump behind a sell, and the full in-swap
 *         auto-harvest + compound. Every number is a `gasleft()` delta around the external call
 *         (so it includes calldata and call overhead -- what a caller actually pays on top of the
 *         venue), printed for transcription into `audit/AUDIT.md` section 11. The assertions are
 *         generous ceilings so a regression that doubles a path fails loudly while normal compiler
 *         jitter never does.
 */
contract GlueHookGas is GlueHookFixture {
    MockERC20 token;
    address alice;

    function setUp() public {
        _deployCore();
        token = new MockERC20("Main", "MAIN", 18);
        alice = makeAddr("alice");
        vm.deal(alice, 2_000 ether);
        token.mint(alice, 2_000_000e18);
        token.mint(address(helper), 20_000_000e18);
        vm.prank(alice);
        token.approve(address(pump), type(uint256).max);
    }

    function _key() internal view returns (IPoolManagerMin.PoolKey memory key) {
        key = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(token), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
    }

    function _cfg(uint256 minMain, uint256 minSec) internal view returns (IGlueHook.ProgramConfig memory) {
        return IGlueHook.ProgramConfig({
            buybackShareWad: 0.2e18,
            burnShareWad: 0.2e18,
            compoundShareWad: 0.3e18,
            potCompoundShareWad: 0,
            potBurnShareWad: 0,
            publicHarvest: true,
            secondaryRecipient: alice,
            mainRecipient: alice,
            minMain: minMain,
            minSecondary: minSec
        });
    }

    /// @dev G1 -- the ONE-TRANSACTION launch vs the three-step path, byte-identical outcome.
    function test_G1_launchPaths() public {
        // Warm every contract both paths touch (hook, PoolManager, Stick, the wrapper
        // implementation the Stick clones) with a throwaway launch, so neither measured path pays
        // the other's cold-address costs -- a test transaction is one tx, real launches are not
        MockERC20 t0 = new MockERC20("M0", "M0", 18);
        t0.mint(alice, 2_000_000e18);
        uint128 seed = _launchLiquidity();
        vm.startPrank(alice);
        t0.approve(address(pump), type(uint256).max);
        pump.launchPool{value: 150 ether}(
            IPoolManagerMin.PoolKey({currency0: ETH, currency1: address(t0), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR}),
            LAUNCH_SQRT, address(t0), address(0), TICK_LO, TICK_HI, seed, alice, _cfg(type(uint256).max, type(uint256).max)
        );
        vm.stopPrank();

        // One transaction
        IPoolManagerMin.PoolKey memory key = _key();
        vm.prank(alice);
        uint256 g = gasleft();
        pump.launchPool{value: 150 ether}(
            key, LAUNCH_SQRT, address(token), address(0), TICK_LO, TICK_HI, seed, alice, _cfg(type(uint256).max, type(uint256).max)
        );
        uint256 oneTx = g - gasleft();
        console2.log("launchPool (init + roles + program + seed):", oneTx);

        // Three steps, second token / fresh key
        MockERC20 t2 = new MockERC20("M2", "M2", 18);
        t2.mint(alice, 2_000_000e18);
        vm.startPrank(alice);
        t2.approve(address(pump), type(uint256).max);
        IPoolManagerMin.PoolKey memory k2 = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(t2), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        g = gasleft();
        IPoolManagerMin(POOL_MANAGER).initialize(k2, LAUNCH_SQRT);
        uint256 stepInit = g - gasleft();
        g = gasleft();
        pump.initPot(k2, address(t2), address(0));
        uint256 stepPot = g - gasleft();
        g = gasleft();
        pump.addLiquidityAdvanced{value: 150 ether}(k2, TICK_LO, TICK_HI, seed, alice, _cfg(type(uint256).max, type(uint256).max));
        uint256 stepAdd = g - gasleft();
        vm.stopPrank();
        console2.log("  vs initialize:", stepInit);
        console2.log("  +  initPot:", stepPot);
        console2.log("  +  addLiquidityAdvanced:", stepAdd);
        console2.log("  =  three-step total:", stepInit + stepPot + stepAdd);
        console2.log("  all-in incl. 21k base per tx -- one tx:", oneTx + 21_000);
        console2.log("                       three txs:", stepInit + stepPot + stepAdd + 63_000);

        assertLt(oneTx, 1_000_000, "launch ceiling");
        // The real comparison includes the 21,000-gas base cost of each transaction
        assertLt(oneTx + 21_000, stepInit + stepPot + stepAdd + 63_000, "one tx cheaper all-in");
    }

    /// @dev G2 -- swap overhead per circumstance: hookless baseline, hooked idle, the pump behind a
    ///      buy and behind a sell (each carrying the reference observation).
    function test_G2_swapCircumstances() public {
        // Hookless twin: the pure V4 baseline
        IPoolManagerMin.PoolKey memory twin = _openTwinPool(address(token));
        uint256 g = gasleft();
        helper.swap(twin, true, -int256(1 ether));
        uint256 baseBuy = g - gasleft();
        g = gasleft();
        helper.swap(twin, false, -int256(500e18));
        uint256 baseSell = g - gasleft();
        console2.log("V4 baseline buy / sell:", baseBuy, baseSell);

        // Hooked pool, pot EMPTY, no program: the idle overhead
        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(token), makeAddr("treasury"));
        g = gasleft();
        helper.swap(key, true, -int256(1 ether));
        uint256 idleBuy = g - gasleft();
        g = gasleft();
        helper.swap(key, false, -int256(500e18));
        uint256 idleSell = g - gasleft();
        console2.log("hooked idle buy / sell:", idleBuy, idleSell);
        console2.log("  idle overhead buy / sell:", idleBuy - baseBuy, idleSell - baseSell);

        // Pot funded: the pump fires behind the buy and behind the sell
        _donateEth(key, 20 ether);
        g = gasleft();
        helper.swap(key, true, -int256(1 ether));
        uint256 pumpBuy = g - gasleft();
        g = gasleft();
        helper.swap(key, false, -int256(500e18));
        uint256 pumpSell = g - gasleft();
        console2.log("pump-firing buy:", pumpBuy);
        console2.log("pump-firing sell:", pumpSell);

        assertLt(idleBuy - baseBuy, 40_000, "idle overhead ceiling");
        assertLt(pumpBuy, baseBuy + 400_000, "pump ceiling (buy)");
        assertLt(pumpSell, baseSell + 400_000, "pump ceiling (sell)");
    }

    /// @dev G2b -- the ARMED bit: a pool whose program exists but has both mins disarmed (the plain
    ///      addLiquidity default, every Glue-engine pool) pays ONE storage read per swap on top of
    ///      the idle path -- the pending-fee scan never runs. An armed program pays the scan.
    function test_G2b_disarmedProgramIsFree() public {
        // Every measured sell is the THIRD identical sell on its pool, so all storage is equally
        // warm and only the hook's own path differs between the three numbers
        MockERC20 t2 = new MockERC20("M2", "M2", 18);
        t2.mint(address(helper), 20_000_000e18);
        (IPoolManagerMin.PoolKey memory idle, ) = _openEthPool(address(t2), makeAddr("treasury"));
        helper.swap(idle, false, -int256(500e18));
        helper.swap(idle, false, -int256(500e18));
        uint256 g = gasleft();
        helper.swap(idle, false, -int256(500e18));
        uint256 idleSell = g - gasleft();

        // Disarmed program (the plain entry's default): the fees accrue, nothing scans
        (IPoolManagerMin.PoolKey memory key, ) = _openEthPool(address(token), makeAddr("treasury"));
        token.mint(address(this), 1_000_000e18);
        token.approve(address(pump), type(uint256).max);
        pump.addLiquidity{value: 50 ether}(key, TICK_LO, TICK_HI, 1e21, alice); // pot admin seeds, alice owns
        helper.swap(key, false, -int256(500e18));
        helper.swap(key, false, -int256(500e18));
        g = gasleft();
        helper.swap(key, false, -int256(500e18));
        uint256 disarmedSell = g - gasleft();

        // Armed with unreachable mins: the scan runs on every swap, the harvest never fires
        vm.prank(alice);
        pump.setProgramConfig(keccak256(abi.encode(key)), _cfg(type(uint256).max - 1, type(uint256).max - 1));
        helper.swap(key, false, -int256(500e18));
        helper.swap(key, false, -int256(500e18));
        g = gasleft();
        helper.swap(key, false, -int256(500e18));
        uint256 armedSell = g - gasleft();

        console2.log("sell: idle / disarmed program / armed program (scan, no fire):", idleSell, disarmedSell, armedSell);
        console2.log("  disarmed program over idle:", disarmedSell > idleSell ? disarmedSell - idleSell : 0);
        console2.log("  pending-fee scan:", armedSell - disarmedSell);

        assertLt(disarmedSell, idleSell + 5_000, "a disarmed program costs a swap one slot read");
        assertGt(armedSell, disarmedSell + 3_000, "the armed scan is the real cost (anti-vacuity)");
    }

    /// @dev G3 -- the heaviest circumstance: armed auto-harvest + compound inside the carrying swap.
    function test_G3_inSwapHarvestCompound() public {
        IPoolManagerMin.PoolKey memory key = _key();
        bytes32 id = keccak256(abi.encode(key));
        // Disarmed while fees accrue on BOTH sides, so the measured swap is the one that finds
        // a two-sided pending window and runs the whole harvest + split + compound MINT inside
        // the carrying transaction (one merged modifyLiquidity: collect netted against the mint)
        vm.prank(alice);
        pump.launchPool{value: 150 ether}(
            key, LAUNCH_SQRT, address(token), address(0), TICK_LO, TICK_HI, _launchLiquidity(),
            alice, _cfg(type(uint256).max, type(uint256).max)
        );
        helper.swap(key, true, -int256(5 ether));
        helper.swap(key, false, -int256(2_000e18));
        vm.prank(alice);
        pump.setProgramConfig(id, _cfg(1, 1)); // armed: mins 1 wei each side

        uint256 liqBefore = pump.programOf(id).liquidity;
        uint256 g = gasleft();
        helper.swap(key, true, -int256(1 ether));
        uint256 harvestSwap = g - gasleft();
        console2.log("swap carrying auto-harvest + compound mint:", harvestSwap);

        assertGt(pump.programOf(id).liquidity, liqBefore, "the measured swap really minted (anti-vacuity)");
        assertLt(harvestSwap, 1_200_000, "in-swap harvest ceiling");
    }

    /// @dev G4 -- steady-state entries: donate, manual harvest, add, remove, claim-shaped ops.
    function test_G4_steadyStateEntries() public {
        IPoolManagerMin.PoolKey memory key = _key();
        vm.startPrank(alice);
        pump.launchPool{value: 150 ether}(
            key, LAUNCH_SQRT, address(token), address(0), TICK_LO, TICK_HI, _launchLiquidity(), alice, _cfg(type(uint256).max, type(uint256).max)
        );

        uint256 g = gasleft();
        pump.donate{value: 5 ether}(key, 5 ether);
        uint256 gDonate = g - gasleft();
        console2.log("donate (native):", gDonate);
        vm.stopPrank();

        // Fees on both sides
        helper.swap(key, true, -int256(5 ether));
        helper.swap(key, false, -int256(2_000e18));

        vm.startPrank(alice);
        g = gasleft();
        pump.harvest(key);
        uint256 gHarvest = g - gasleft();
        console2.log("manual harvest (split + compound + payouts):", gHarvest);

        g = gasleft();
        pump.addProgramLiquidity{value: 10 ether}(key, 1e20);
        uint256 gAdd = g - gasleft();
        console2.log("addProgramLiquidity:", gAdd);

        g = gasleft();
        pump.removeProgramLiquidity(key, 1e20, alice);
        uint256 gRemove = g - gasleft();
        console2.log("removeProgramLiquidity:", gRemove);
        vm.stopPrank();

        assertLt(gDonate, 120_000, "donate ceiling");
        assertLt(gHarvest, 900_000, "harvest ceiling");
    }

    /// @dev G5 -- the NATIVE report's marginal cost: the same manual harvest and the same in-swap
    ///      auto-harvest, once on a plain program (recipients = an EOA) and once on a native one
    ///      (recipients = a registered recording engine): the difference is the delivered-ledger
    ///      writes plus the `recordHarvest` call at forwarded gas (the mock's callback is the
    ///      engine-side bookkeeping's floor: five warm SSTOREs).
    function test_G5_nativeReportCost() public {
        // The registered engine and its pool
        MockHookedEngine engine = new MockHookedEngine(pump);
        stick.setRegisteredEngine(address(engine), true);
        vm.deal(address(engine), 2_000 ether);
        token.mint(address(engine), 2_000_000e18);
        engine.exec(address(token), abi.encodeCall(token.approve, (address(pump), type(uint256).max)));
        IPoolManagerMin.PoolKey memory nKey = _key();
        engine.exec{value: 150 ether}(
            address(pump),
            abi.encodeCall(
                IGlueHook.launchPool,
                (nKey, LAUNCH_SQRT, address(token), address(0), TICK_LO, TICK_HI, _launchLiquidity(), address(engine), _cfg(type(uint256).max, type(uint256).max))
            )
        );
        require(pump.programOf(keccak256(abi.encode(nKey))).native, "native");

        // The plain twin: a second main, same shape, alice's program
        MockERC20 token2 = new MockERC20("Main2", "MAIN2", 18);
        token2.mint(alice, 2_000_000e18);
        token2.mint(address(helper), 20_000_000e18);
        vm.prank(alice);
        token2.approve(address(pump), type(uint256).max);
        IPoolManagerMin.PoolKey memory pKey = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(token2), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        vm.prank(alice);
        pump.launchPool{value: 150 ether}(
            pKey, LAUNCH_SQRT, address(token2), address(0), TICK_LO, TICK_HI, _launchLiquidity(),
            alice, _cfg(type(uint256).max, type(uint256).max)
        );

        // Warm both: one harvest each (cold slots, compound mint), then measure the second
        for (uint256 round; round < 2; ++round) {
            helper.swap(nKey, true, -int256(5 ether));
            helper.swap(nKey, false, -int256(2_000e18));
            helper.swap(pKey, true, -int256(5 ether));
            helper.swap(pKey, false, -int256(2_000e18));
            if (round == 0) {
                engine.exec(address(pump), abi.encodeCall(IGlueHook.harvest, (nKey)));
                vm.prank(alice);
                pump.harvest(pKey);
            }
        }
        uint256 g = gasleft();
        engine.exec(address(pump), abi.encodeCall(IGlueHook.harvest, (nKey)));
        uint256 gNative = g - gasleft();
        vm.prank(alice);
        g = gasleft();
        pump.harvest(pKey);
        uint256 gPlain = g - gasleft();
        console2.log("manual harvest, plain program:", gPlain);
        console2.log("manual harvest, native program (ledger + recordHarvest):", gNative);
        // The engine forwarder adds one CALL frame of its own; net it out approximately
        console2.log("  native report marginal (incl. the mock engine's own bookkeeping):", gNative - gPlain);

        // In-swap: arm both, accrue, measure the carrying swap
        engine.exec(address(pump), abi.encodeCall(IGlueHook.setProgramConfig, (keccak256(abi.encode(nKey)), _cfgFor(address(engine), 1, 1))));
        vm.prank(alice);
        pump.setProgramConfig(keccak256(abi.encode(pKey)), _cfg(1, 1));
        helper.swap(nKey, true, -int256(5 ether));
        helper.swap(nKey, false, -int256(2_000e18));
        helper.swap(pKey, true, -int256(5 ether));
        helper.swap(pKey, false, -int256(2_000e18));
        uint256 callsBefore = engine.calls();
        g = gasleft();
        helper.swap(nKey, true, -int256(1 ether));
        uint256 sNative = g - gasleft();
        g = gasleft();
        helper.swap(pKey, true, -int256(1 ether));
        uint256 sPlain = g - gasleft();
        assertEq(engine.calls(), callsBefore + 1, "the measured native swap reported (anti-vacuity)");
        console2.log("swap carrying auto-harvest, plain program:", sPlain);
        console2.log("swap carrying auto-harvest, native program:", sNative);
        console2.log("  native report marginal in-swap:", sNative - sPlain);
        assertLt(sNative - sPlain, 120_000, "the report costs the frame a bounded few tens of k");
    }

    /// @dev The gas config with the recipients pointed at `who` (a native program's pin).
    function _cfgFor(address who, uint256 minMain, uint256 minSec) internal pure returns (IGlueHook.ProgramConfig memory c) {
        c = IGlueHook.ProgramConfig({
            buybackShareWad: 0.2e18,
            burnShareWad: 0.2e18,
            compoundShareWad: 0.3e18,
            potCompoundShareWad: 0,
            potBurnShareWad: 0,
            publicHarvest: true,
            secondaryRecipient: who,
            mainRecipient: who,
            minMain: minMain,
            minSecondary: minSec
        });
    }
}
