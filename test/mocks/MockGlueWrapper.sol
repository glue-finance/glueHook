// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title  MockGlueWrapper — a faithful stand-in for a Glue Protocol GlueWrapper clone.
 * @notice The ERC20 face + backing pot of ONE sticky asset, in either mode:
 *
 *         - ERC20 mode (`isFungible`): {unglue} with an EMPTY collateral list is the PURE BURN the
 *           hook runs on a glued main. Like the real wrapper it pulls the RAW sticky from
 *           `msg.sender`'s exact allowance and destroys it in-protocol with its own fallbacks: the
 *           token's `burn(uint256)` (verified by a balance drop), then a transfer to `0xdead`, then
 *           custody on the glue itself. A failing pull reverts — the shape the hook's tolerant
 *           call must absorb.
 *         - NFT mode: the empty-collateral shape is REJECTED (`BadAsset`) and any amount must be a
 *           whole `1e18` unit (`BadInput`) — the two doors that made a wrapper main unburnable
 *           before the park path existed.
 *
 *         As an ERC20 it mirrors the real wrapper's transfer rule: `0xdead` is blocked, a transfer
 *         to ITSELF is allowed and becomes {parkedShares} — the custody Glue's supply oracle
 *         subtracts from the circulating supply.
 */
contract MockGlueWrapper is ERC20 {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    error BadAsset();
    error BadInput();

    /// @dev The sticky asset this wrapper glues (an ERC20 in fungible mode, a collection otherwise).
    address public sticky;
    /// @dev ERC20 mode when true, NFT mode when false.
    bool public isFungible;

    /// @dev Call counter, so tests can assert the hook's burn really ran through this wrapper.
    uint256 public unglueCalls;

    constructor() ERC20("Glued", "gSTK") {}

    /// @notice One-shot clone initialiser (the real wrapper is an EIP-1167 clone stamped by the Stick).
    function initialize(address sticky_, bool fungible) external {
        require(sticky == address(0), "wrapper: initialised");
        sticky = sticky_;
        isFungible = fungible;
    }

    /// @notice Shares owned by the wrapper itself — out of circulation for Glue.
    function parkedShares() external view returns (uint256) {
        return balanceOf(address(this));
    }

    /// @notice Test helper: hand out shares (a wrap, without the collateral).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice The wrapper's own pure burn (ERC20 mode) — no GlueStick hop.
    function unglue(address[] calldata collaterals, uint256 amount, address recipient)
        external
        returns (
            uint256 supplyDelta,
            uint256 realAmount,
            uint256 beforeTotalSupply,
            uint256 afterTotalSupply,
            uint256[] memory uniqueIds
        )
    {
        unglueCalls++;
        if (recipient == address(0)) recipient = msg.sender;
        if (!isFungible) {
            // NFT mode: whole units only, and an NFT leaves circulation by custody — the
            // empty-collateral shape cannot express it
            if (amount == 0 || amount % 1e18 != 0) revert BadInput();
            if (collaterals.length == 0) revert BadAsset();
        }
        // The hook only ever runs the pure-burn shape
        require(collaterals.length == 0, "wrapper: collaterals");
        require(amount != 0, "wrapper: amount");

        // Pull the raw sticky from the caller's exact allowance (reverts if the token blocks us)
        IERC20 token = IERC20(sticky);
        require(token.transferFrom(msg.sender, address(this), amount), "wrapper: pull");

        // The protocol's own burn fallbacks: true burn -> dead route -> custody on the glue
        beforeTotalSupply = token.totalSupply();
        uint256 balBefore = token.balanceOf(address(this));
        (bool ok, ) = sticky.call(abi.encodeWithSignature("burn(uint256)", amount));
        if (!ok || token.balanceOf(address(this)) > balBefore - amount) {
            // No (honest) burn: try the dead route; a refusal leaves custody here (still burned
            // from the world's point of view — the glue has no withdrawal path either)
            (ok, ) = sticky.call(abi.encodeCall(IERC20.transfer, (DEAD, amount)));
        }
        afterTotalSupply = token.totalSupply();
        supplyDelta = beforeTotalSupply - afterTotalSupply;
        realAmount = amount;
        uniqueIds = new uint256[](0);
    }

    /// @dev The real wrapper's transfer rule: the dead address is blocked, self is allowed (a PARK).
    function _update(address from, address to, uint256 amount) internal override {
        if (to == DEAD) revert BadInput();
        super._update(from, to, amount);
    }
}
