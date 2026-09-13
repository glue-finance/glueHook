// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IGlueHook} from "../../contracts/interfaces/IGlueHook.sol";
import {IGlueHookedEngine} from "../../contracts/interfaces/IGlueHookedEngine.sol";
import {IPoolManagerMin} from "../../contracts/libs/GluedV4Core.sol";

/**
 * @title  MockHookedEngine — a stand-in for a Glue LP engine that owns a NATIVE program.
 * @notice Records every `recordHarvest` the hook fires at it (caller, pool, both legs, cumulative
 *         sums) and can be put in a MOOD to model a misbehaving engine: revert, burn every unit
 *         of gas it is given, re-enter the hook from inside the callback, or refuse the native push (so the
 *         hook books the leg `owed` and the callback reports zero for it). It also forwards
 *         arbitrary calls ({exec}) so a test can drive the hook AS the engine — `launchPool`,
 *         `addLiquidityAdvanced`, `harvest`, `setProgramConfig`, approvals — because the hook
 *         reads `msg.sender` for the pot admin, the program owner and the native stamp.
 */
contract MockHookedEngine is IGlueHookedEngine {
    enum Mode { Record, Revert, BurnGas, Reenter }

    IGlueHook public immutable hook;
    Mode public mode;
    /// @dev While true the native `receive` reverts: the hook's bounded push bounces and books owed.
    bool public refuseEth;
    /// @dev The key {Mode.Reenter} tries to `harvest` from inside the callback.
    IPoolManagerMin.PoolKey internal _reenterKey;

    // ── what the callback saw ──
    uint256 public calls;
    address public lastSender;
    bytes32 public lastPoolId;
    uint256 public lastMain;
    uint256 public lastSec;
    uint256 public cumMain;
    uint256 public cumSec;
    /// @dev {Mode.Reenter}: the selector the hook answered the re-entrant `harvest` with.
    bytes4 public reenterError;

    constructor(IGlueHook hook_) {
        hook = hook_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setRefuseEth(bool r) external {
        refuseEth = r;
    }

    function setReenterKey(IPoolManagerMin.PoolKey calldata k) external {
        _reenterKey = k;
    }

    /// @notice Drive any contract as the engine (value forwarded, revert bubbled).
    function exec(address target, bytes calldata data) external payable returns (bytes memory out) {
        bool ok;
        (ok, out) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(out, 32), mload(out)) }
        }
    }

    /// @inheritdoc IGlueHookedEngine
    function recordHarvest(bytes32 poolId, uint256 deliveredMain, uint256 deliveredSec) external {
        Mode m = mode;
        if (m == Mode.Revert) revert("engine: refusing the report");
        if (m == Mode.BurnGas) {
            // INVALID consumes every unit of the forwarded gas (63/64 of the caller's), nothing bubbles
            assembly ("memory-safe") { invalid() }
        }
        if (m == Mode.Reenter) {
            // A well-formed re-entry attempt: the hook's guard must throw it out and the report
            // still completes normally
            try hook.harvest(_reenterKey) {
                reenterError = bytes4(0);
            } catch (bytes memory err) {
                reenterError = bytes4(err);
            }
        }
        calls++;
        lastSender = msg.sender;
        lastPoolId = poolId;
        lastMain = deliveredMain;
        lastSec = deliveredSec;
        cumMain += deliveredMain;
        cumSec += deliveredSec;
    }

    receive() external payable {
        require(!refuseEth, "engine: not now");
    }
}
