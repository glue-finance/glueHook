// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title  MockGlueStick — a faithful stand-in for the Glue Protocol's GlueStick singleton.
 * @notice The fixture etches this at the REAL canonical GlueStick address, so the hook's Glue
 *         integration runs exactly as it does in production:
 *
 *         - {isStickyAsset} / {ensureWrapper}: the lazy-glue registry. `ensureWrapper` is the
 *           validated chokepoint — it can be armed to refuse ({setRefuse}), modelling an asset
 *           Glue will not admit (WETH, a wrap-of-a-wrap, a non-conforming contract).
 *         - {unglue} with an EMPTY collateral list: the PURE BURN. Like the real protocol it pulls
 *           the sticky from the caller and destroys it in-protocol, running its own fallbacks:
 *           the token's own `burn(uint256)` (verified by a balance drop), then a transfer to
 *           `0xdead`, then custody on the glue itself. A refused asset ({setRefuse}) or a failing
 *           pull reverts, exactly the shape the hook's try/catch must absorb.
 */
contract MockGlueStick {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev asset => its glue (wrapper) clone, lazily created.
    mapping(address => address) public wrapperOf;
    /// @dev asset => Glue refuses to admit it (models WETH / wrap-of-wrap / non-conforming).
    mapping(address => bool) public refused;

    /// @dev Call counters, so tests can assert the hook's creation-time ensure really ran.
    uint256 public ensureCalls;
    uint256 public unglueCalls;

    /// @notice Arm/disarm the admission refusal for an asset.
    function setRefuse(address asset, bool r) external {
        refused[asset] = r;
    }

    function isStickyAsset(address asset) external view returns (bool isSticky, address navAddress) {
        navAddress = wrapperOf[asset];
        isSticky = navAddress != address(0);
    }

    function ensureWrapper(address asset) public returns (address wrapperAddress) {
        ensureCalls++;
        if (refused[asset]) revert("GlueStick: not glueable");
        wrapperAddress = wrapperOf[asset];
        if (wrapperAddress == address(0)) {
            wrapperAddress = address(uint160(uint256(keccak256(abi.encode("glue", asset)))));
            wrapperOf[asset] = wrapperAddress;
        }
    }

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
        // The hook only ever runs the pure-burn shape
        require(collaterals.length == 0, "mock: collaterals");
        require(!wrapper, "mock: wrapper");
        require(recipient != address(0), "mock: recipient");
        require(amount != 0, "mock: amount");

        // LAZY-GLUE like the real chokepoint: an unadmitted asset reverts here too
        ensureWrapper(context);

        // Pull the sticky from the caller (reverts if the token blocks the stick)
        IERC20 token = IERC20(context);
        require(token.transferFrom(msg.sender, address(this), amount), "mock: pull");

        // The protocol's own burn fallbacks: true burn -> dead route -> custody on the glue
        beforeTotalSupply = token.totalSupply();
        uint256 balBefore = token.balanceOf(address(this));
        (bool ok, ) = context.call(abi.encodeWithSignature("burn(uint256)", amount));
        if (!ok || token.balanceOf(address(this)) > balBefore - amount) {
            // No (honest) burn: try the dead route; a refusal leaves custody here (still burned
            // from the world's point of view — the glue has no withdrawal path either)
            (ok, ) = context.call(abi.encodeCall(IERC20.transfer, (DEAD, amount)));
        }
        afterTotalSupply = token.totalSupply();
        supplyDelta = beforeTotalSupply - afterTotalSupply;
        realAmount = amount;
        uniqueIds = new uint256[](0);
    }
}
