// SPDX-License-Identifier: MIT
// https://github.com/glue-finance/glue/blob/main/LICENCE-MIT.txt
pragma solidity ^0.8.35;

/**
 * @title  IGlueHookedEngine
 * @author @lalilulel0x - La Li Lu Le Lo
 * @notice The ONE callback a GlueHook fires on the engine that owns a NATIVE LP program: after every
 *         harvest of that program — the in-swap auto-harvest, the manual `harvest`, and the
 *         harvest-first inside the program's own add / remove — once the remainder legs have been
 *         PUSHED to the engine, the hook reports what actually landed so the engine can attribute
 *         it to its stakers at once, without ever reading its own balance.
 * @dev    CONTRACT BETWEEN THE TWO SIDES
 *         ─────────────────────────────
 *         - `deliveredMain` / `deliveredSec` are DELIVERED amounts, never gross: the exact wei that
 *           moved onto the engine in this frame (a push that succeeded, including any `owed` backlog
 *           it folded in). A leg the hook had to book as `owed` reports ZERO here and shows up in
 *           the frame that later pays it. The engine therefore never mirrors the hook's split math.
 *         - The hook calls with its gas forwarded (no stipend: the engine is Glue's own, pinned at
 *           pool creation) and the revert swallowed, AFTER all deliveries, burns and compounds of
 *           the frame: a revert here can never affect the carrying swap or any delivery. The hook keeps a monotonic per-`(pool, asset)` DELIVERED ledger
 *           (`IGlueHook.deliveredCumOf`) regardless of the callback's outcome — the engine
 *           reconciles any missed callback by diffing that ledger against its own cursor, so every
 *           unit is attributed EXACTLY ONCE (callback and reconcile advance the same cursor).
 *         - Only the bound hook may call it. The engine must be non-reentrant on its own entries
 *           and must never call back into the hook from here (the hook's `afterSwap` guard would
 *           reject it anyway).
 *         - Pure bookkeeping on the engine side: two accumulator writes, plus the STAKE_UNIT wrap
 *           of the sticky leg on the raw-ERC20 venue. With no tracked liquidity to attribute
 *           against, the engine CARRIES the legs to its next attribution — it never drops them.
 */
interface IGlueHookedEngine {
    /**
     * @notice Report a native program's harvest: the remainder legs that just LANDED on this engine.
     * @dev    Hook-only. Non-reverting by design on the engine side (the only external call is the
     *         sticky-side wrap, which dust-defers instead of reverting). Advances the engine's
     *         per-bucket delivered cursors so the later reconcile against `deliveredCumOf` credits
     *         nothing twice.
     * @param  poolId        The hooked pool whose program was harvested.
     * @param  deliveredMain Main-side (pooled sticky) remainder delivered to the engine this frame.
     * @param  deliveredSec  Secondary-side remainder delivered to the engine this frame.
     */
    function recordHarvest(bytes32 poolId, uint256 deliveredMain, uint256 deliveredSec) external;
}
