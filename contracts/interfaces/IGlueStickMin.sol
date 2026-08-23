// SPDX-License-Identifier: BUSL-1.1
//
// Licensed Work: GlueHook
// The Licensed Work is (c) 2026 gluefinance.eth and is owned exclusively by Glue Labs Inc. (Delaware).
// Licensor: Glue Labs Inc. (Delaware)
// Change Date: the earlier of 2030-08-05 or a date specified at gluehook-license-date.gluefinance.eth
// Change License: GNU General Public License v2.0 or later
// Full licence text: https://github.com/glue-finance/GlueHook/blob/main/LICENCE.txt

pragma solidity ^0.8.35;

/**
 * @title  IGlueStickMin
 * @notice The minimal slice of the Glue Protocol's GlueStick this hook talks to. The GlueStick is
 *         the Glue V2 singleton factory/router, deployed at the SAME address on every chain; every
 *         asset it admits gets one canonical glue (wrapper) whose backing pot makes the asset
 *         redeemable — and BURNABLE through {unglue}.
 * @dev    The hook uses exactly three doors:
 *
 *         - {isStickyAsset}: has the asset already been glued?
 *         - {ensureWrapper}: the validated creation chokepoint — clones the asset's glue if it does
 *           not exist yet (idempotent), classifying the asset and REJECTING the unglueable (the
 *           network wrapper, a wrap-of-a-wrap, non-conforming contracts).
 *         - {unglue} with an EMPTY collateral list: a PURE BURN — the sticky is pulled from the
 *           caller and destroyed inside the protocol (which runs its own burn / dead-route
 *           fallbacks), redeeming nothing and concentrating the glue's backing for every remaining
 *           holder.
 */
interface IGlueStickMin {
    /// @notice Whether `asset` already has a glue, and where its NAV lives.
    function isStickyAsset(address asset) external view returns (bool isSticky, address navAddress);

    /// @notice Create (or return) the asset's canonical glue. Reverts on an unglueable asset.
    function ensureWrapper(address asset) external returns (address wrapperAddress);

    /// @notice Burn sticky tokens; an EMPTY `collaterals` array is a PURE BURN (nothing redeemed).
    /// @param context The sticky asset (or any of its clones).
    /// @param collaterals Collaterals to redeem — EMPTY here, always: the hook only ever burns.
    /// @param amount Raw sticky amount, pulled from the caller's allowance.
    /// @param recipient Collateral recipient (irrelevant on a pure burn, must not be the zero address).
    /// @param wrapper True when `amount` is wrapper shares — never, for this hook.
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
    );
}
