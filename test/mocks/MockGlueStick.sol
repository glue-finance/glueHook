// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MockGlueWrapper} from "./MockGlueWrapper.sol";

/**
 * @title  MockGlueStick — a faithful stand-in for the Glue Protocol's GlueStick singleton.
 * @notice The fixture etches this at the REAL canonical GlueStick address, so the hook's Glue
 *         integration runs exactly as it does in production:
 *
 *         - {wrapperOf}: the authoritative registry read the hook classifies a main with. A
 *           registered wrapper clone resolves to ITSELF, a glued sticky to its wrapper, anything
 *           else to zero — exactly `_wrapper[_stickyOf(ctx)]` on the real Stick.
 *         - {ensureWrapper}: the validated creation chokepoint — clones a real {MockGlueWrapper}
 *           (ERC20 mode) for a fresh sticky, is idempotent on a glued one, and REFUSES a
 *           registered wrapper (the wrap-of-a-wrap guard) or an armed asset ({setRefuse},
 *           modelling WETH / a non-conforming contract).
 *         - {registerWrapper}: test door to register an externally deployed clone (NFT mode, say)
 *           as the canonical wrapper of a sticky, as the real Stick does at `applyTheGlue`.
 *         - {unglue}: the Stick-routed burn the hook USED to run. Kept so tests can assert the
 *           V3 hook never calls it any more (`unglueCalls` stays at zero).
 *         - {isRegisteredEngine}: the LP-engine registry read the hook stamps NATIVE programs
 *           with. Toggleable per address ({setRegisteredEngine}), and the answer's SHAPE can be
 *           bent ({setRegistryMode}) to model a misbehaving Stick: a revert, a short return, a
 *           non-boolean word — every one of which the hook must read as "not native".
 */
contract MockGlueStick {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev How {isRegisteredEngine} answers: the truth, a revert, one byte, or a garbage word.
    enum RegistryMode { Normal, Revert, Short, Garbage }

    /// @dev engine => registered (the real Stick's `_engineFlags[engine] & 1`).
    mapping(address => bool) public registeredEngine;
    /// @dev The registry read's answer shape.
    RegistryMode public registryMode;

    /// @dev sticky => its canonical glue (wrapper) clone.
    mapping(address => address) internal _wrapper;
    /// @dev wrapper clone => the sticky it glues (the real Stick's `_ctxData` stamp).
    mapping(address => address) internal _stickyOfCtx;
    /// @dev asset => Glue refuses to admit it (models WETH / wrap-of-wrap / non-conforming).
    mapping(address => bool) public refused;
    /// @dev The wrapper implementation every glue is an EIP-1167 clone of (as on the real Stick).
    address public immutable wrapperImplementation;

    constructor() {
        wrapperImplementation = address(new MockGlueWrapper());
    }

    /// @dev Call counters, so tests can assert what the hook really ran.
    uint256 public ensureCalls;
    uint256 public unglueCalls;

    /// @notice Arm/disarm the admission refusal for an asset.
    function setRefuse(address asset, bool r) external {
        refused[asset] = r;
    }

    /// @notice Admit / expel an LP engine from the registry.
    function setRegisteredEngine(address engine, bool r) external {
        registeredEngine[engine] = r;
    }

    /// @notice Bend the shape of the registry read's answer.
    function setRegistryMode(RegistryMode m) external {
        registryMode = m;
    }

    /// @notice The real Stick's `isRegisteredEngine`, with the answer shaped by {registryMode}.
    ///         `view`, as the hook probes it under STATICCALL.
    function isRegisteredEngine(address engine) external view returns (bool) {
        RegistryMode m = registryMode;
        if (m == RegistryMode.Revert) revert("GlueStick: registry down");
        if (m == RegistryMode.Short) {
            assembly ("memory-safe") { mstore(0x00, 1) return(0x1f, 1) } // ONE byte, not a word
        }
        if (m == RegistryMode.Garbage) {
            assembly ("memory-safe") { mstore(0x00, 2) return(0x00, 32) } // a word that is not 0/1
        }
        return registeredEngine[engine];
    }

    /// @notice Register an externally deployed wrapper clone as the canonical glue of `sticky`.
    function registerWrapper(address clone, address sticky) external {
        _wrapper[sticky] = clone;
        _stickyOfCtx[clone] = sticky;
    }

    /// @notice The real Stick's `wrapperOf`: any registered context → the canonical wrapper.
    function wrapperOf(address context) external view returns (address wrapper) {
        address sticky = _stickyOfCtx[context];
        if (sticky == address(0)) sticky = context;
        return _wrapper[sticky];
    }

    /// @notice The real Stick's `getWrapperAddress`: the sticky only.
    function getWrapperAddress(address asset) external view returns (address) {
        return _wrapper[asset];
    }

    function ensureWrapper(address asset) public returns (address wrapperAddress) {
        ensureCalls++;
        if (refused[asset]) revert("GlueStick: not glueable");
        // Wrap-of-a-wrap guard: a wrapper clone is never itself glued
        if (_stickyOfCtx[asset] != address(0)) revert("GlueStick: BadAsset");
        wrapperAddress = _wrapper[asset];
        if (wrapperAddress == address(0)) {
            wrapperAddress = Clones.clone(wrapperImplementation);
            MockGlueWrapper(wrapperAddress).initialize(asset, true);
            _wrapper[asset] = wrapperAddress;
            _stickyOfCtx[wrapperAddress] = asset;
        }
    }

    /// @notice The Stick-routed burn (LEGACY for this hook: V3 burns through the wrapper itself).
    function unglue(
        address context,
        address[] calldata collaterals,
        uint256 amount,
        address recipient,
        bool wrapper
    ) external returns (
        uint256 supplyDelta,
        uint256 realAmount,
        uint256 beforeTotalSupply,
        uint256 afterTotalSupply,
        uint256[] memory uniqueIds
    ) {
        unglueCalls++;
        require(collaterals.length == 0, "mock: collaterals");
        require(!wrapper, "mock: wrapper");
        require(recipient != address(0), "mock: recipient");
        require(amount != 0, "mock: amount");

        ensureWrapper(context);

        IERC20 token = IERC20(context);
        require(token.transferFrom(msg.sender, address(this), amount), "mock: pull");

        beforeTotalSupply = token.totalSupply();
        uint256 balBefore = token.balanceOf(address(this));
        (bool ok, ) = context.call(abi.encodeWithSignature("burn(uint256)", amount));
        if (!ok || token.balanceOf(address(this)) > balBefore - amount) {
            (ok, ) = context.call(abi.encodeCall(IERC20.transfer, (DEAD, amount)));
        }
        afterTotalSupply = token.totalSupply();
        supplyDelta = beforeTotalSupply - afterTotalSupply;
        realAmount = amount;
        uniqueIds = new uint256[](0);
    }
}
