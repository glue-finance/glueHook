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
 * @title  IGlueWrapperMin
 * @notice The one door of a Glue Protocol GlueWrapper this hook talks to: the wrapper's OWN
 *         `unglue`. A GlueWrapper is the canonical glue of a sticky asset (its ERC20 face and its
 *         backing pot, one EIP-1167 clone per asset, code fixed for life). The hook burns a glued
 *         main by calling `unglue` on the main's wrapper directly with an EMPTY collateral list — a
 *         PURE BURN: the sticky is pulled from the caller's exact allowance and destroyed inside
 *         the protocol (which runs its own burn / dead-route fallbacks), redeeming nothing and
 *         concentrating the glue's backing for every remaining holder. No GlueStick hop, same
 *         `Unglued` indexing through GlueAlerts.
 * @dev    When the main IS a wrapper the hook never calls this: wrapper shares leave circulation by
 *         PARKING (a transfer to the wrapper's own address), which is what the Glue supply oracle
 *         subtracts from the circulating supply.
 */
interface IGlueWrapperMin {
    /// @notice Burn sticky tokens through the wrapper; an EMPTY `collaterals` array is a PURE BURN.
    /// @param collaterals Collaterals to redeem — EMPTY here, always: the hook only ever burns.
    /// @param amount Raw sticky amount, pulled from the caller's allowance.
    /// @param recipient Collateral recipient (irrelevant on a pure burn).
    function unglue(address[] calldata collaterals, uint256 amount, address recipient)
        external
        returns (
            uint256 supplyDelta,
            uint256 realAmount,
            uint256 beforeTotalSupply,
            uint256 afterTotalSupply,
            uint256[] memory uniqueIds
        );
}
