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
 *         asset it admits gets one canonical glue (a GlueWrapper) whose backing pot makes the asset
 *         redeemable — and BURNABLE through the wrapper's own `unglue` ({IGlueWrapperMin}).
 * @dev    The hook uses exactly three doors — two at pot declaration and (lazily) at burn time,
 *         one at program creation:
 *
 *         - {wrapperOf}: the authoritative registry read. Resolves ANY registered Glue address to
 *           the canonical wrapper of its sticky: a GlueWrapper resolves to ITSELF, a glued sticky
 *           to its wrapper, an unglued asset to `address(0)`. Only the GlueStick writes the
 *           registry, so the answer cannot be faked by the asset.
 *         - {ensureWrapper}: the validated creation chokepoint — clones the asset's glue if it does
 *           not exist yet (idempotent), classifying the asset and REJECTING the unglueable (the
 *           network wrapper, a wrap-of-a-wrap, non-conforming contracts).
 *         - {isRegisteredEngine}: the LP-engine registry read. A program whose creator it reports
 *           as registered is stamped NATIVE (see {IGlueHook}).
 */
interface IGlueStickMin {
    /// @notice The canonical GlueWrapper behind `context` (itself for a wrapper, `address(0)` when
    ///         the asset is not glued yet).
    function wrapperOf(address context) external view returns (address wrapper);

    /// @notice Create (or return) the asset's canonical glue. Reverts on an unglueable asset.
    function ensureWrapper(address asset) external returns (address wrapperAddress);

    /// @notice True when `engine` is a registered Glue LP engine.
    function isRegisteredEngine(address engine) external view returns (bool);
}
