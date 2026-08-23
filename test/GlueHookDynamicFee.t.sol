// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {GlueHookFixture} from "./helpers/GlueHookFixture.sol";
import {IGlueHook} from "../contracts/interfaces/IGlueHook.sol";
import {IPoolManagerMin} from "../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title  GlueHookDynamicFee — dynamic-fee pools are refused at the door.
 * @notice DR1–DR4. GlueHook serves STATIC-FEE pools only: the fee is part of the pool's identity
 *         (a million distinguishable static values per pair, usable as a creation namespace), and
 *         every price the hook quotes reads the one immutable fee the key declares. A key carrying
 *         the LPFeeLibrary sentinel (0x800000) is rejected on BOTH creation doors — the
 *         `beforeInitialize` callback for a direct `PoolManager.initialize`, and `launchPool`
 *         itself (which the PoolManager's callback-skip would otherwise let through). Nothing
 *         half-made survives a rejection, and static pools are untouched.
 */
contract GlueHookDynamicFee is GlueHookFixture {
    /// @dev LPFeeLibrary.DYNAMIC_FEE_FLAG — `key.fee` for every dynamic-fee pool.
    uint24 constant DYNAMIC_FEE = 0x800000;

    address constant RECIPIENT = address(0xBEEF);

    MockERC20 main;
    IPoolManagerMin.PoolKey key;
    bytes32 id;

    function setUp() public {
        _deployCore();
        main = new MockERC20("Main", "MAIN", 18);
        // The would-be dynamic pool: the fixture's usual ETH-secondary shape, fee = the sentinel
        key = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(main), fee: DYNAMIC_FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        id = keccak256(abi.encode(key));
    }

    /// @dev A config literal with everything off (recipients live, auto-harvest disarmed).
    function _plainCfg(address owner) internal pure returns (IGlueHook.ProgramConfig memory) {
        return IGlueHook.ProgramConfig({
            buybackShareWad: 0,
            burnShareWad: 0,
            compoundShareWad: 0,
            potCompoundShareWad: 0,
            potBurnShareWad: 0,
            publicHarvest: false,
            secondaryRecipient: owner,
            mainRecipient: owner,
            minMain: type(uint256).max,
            minSecondary: type(uint256).max
        });
    }

    /// DR1 — A direct `PoolManager.initialize` with the sentinel key reverts inside
    ///      `beforeInitialize`: no pool is created and no pot admin is captured.
    function test_DR1_directInitializeRejected() public {
        vm.expectRevert(); // the PoolManager wraps the hook's BadConfig
        IPoolManagerMin(POOL_MANAGER).initialize(key, LAUNCH_SQRT);
        assertEq(pump.potOf(id).admin, address(0), "no admin captured");
    }

    /// DR2 — `launchPool` re-runs the same gate itself (the PoolManager skips `beforeInitialize`
    ///      when the hook is the caller): the launch reverts BadConfig atomically — no pool, no
    ///      pot, the attached value untouched.
    function test_DR2_launchPoolRejected() public {
        _mintTo(address(main), address(this), 10_000_000e18);
        main.approve(address(pump), type(uint256).max);

        uint256 balBefore = address(this).balance;
        vm.expectRevert(IGlueHook.BadConfig.selector);
        pump.launchPool{value: 150 ether}(
            key, LAUNCH_SQRT, address(main), RECIPIENT,
            TICK_LO, TICK_HI, _launchLiquidity(), address(this), _plainCfg(address(this))
        );
        assertEq(pump.potOf(id).admin, address(0), "no pot left behind");
        assertEq(address(this).balance, balBefore, "the value never left");
    }

    /// DR3 — The rejection is the SENTINEL's, not the fee magnitude's: a static pool at the very
    ///      same shape initialises, declares its pot and swaps exactly as everywhere else.
    function test_DR3_staticTwinUnaffected() public {
        (IPoolManagerMin.PoolKey memory staticKey, bytes32 sid) = _openEthPool(address(main), RECIPIENT);
        assertTrue(pump.potOf(sid).configured, "static pool fully alive");

        // Trades flow: a buy on the static pool executes
        (int256 d0, int256 d1) = helper.swap(staticKey, true, -int256(1 ether));
        assertLt(d0, 0, "paid ETH");
        assertGt(d1, 0, "received main");
    }

    /// DR4 — Every static fee value is its own pool: two pools of the SAME pair at fee 3000 and
    ///      3001 coexist independently (the fee field is a creation namespace) — while the
    ///      sentinel value stays unreachable between them.
    function test_DR4_feeNamespaceCoexists() public {
        (, bytes32 idA) = _openEthPool(address(main), RECIPIENT);

        IPoolManagerMin.PoolKey memory keyB = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(main), fee: 3001, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        bytes32 idB = keccak256(abi.encode(keyB));
        IPoolManagerMin(POOL_MANAGER).initialize(keyB, LAUNCH_SQRT);
        pump.initPot(keyB, address(main), RECIPIENT);

        assertTrue(idA != idB, "distinct pools");
        assertTrue(pump.potOf(idA).configured && pump.potOf(idB).configured, "both pots alive");
        assertEq(pump.potOf(idB).admin, address(this), "the +1-fee pool has its own admin");
    }
}
