// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {GlueHook} from "../contracts/GlueHook.sol";
import {GluedV4Core, IPoolManagerMin} from "../contracts/libs/GluedV4Core.sol";
import {V4PoolHelper} from "./helpers/V4PoolHelper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {GlueHookHandler} from "./handlers/GlueHookHandler.sol";

/**
 * @title  GlueHookInvariant — stateful fuzzing of the buyback hook against a REAL Uniswap V4 pool.
 * @notice The pump settles inside somebody else's swap, and it moves value that belongs to donors.
 *         That combination is what makes a stateful campaign worth running: a unit test sees a
 *         successful swap and a happy swapper, and cannot see that the hook's books stopped matching
 *         its balances three pumps ago. So this campaign interleaves donations, buys, sells
 *         (exact-input and exact-output) and time skips in arbitrary order and asserts:
 *
 *   PP1 POT SOLVENCY        the hook's balance of the secondary covers everything it says it owes
 *   PP2 CONSERVATION        pot + Σ pump spends == Σ donations, exactly. Every wei that ever entered a
 *                           pot is either still there or was spent by a pump that logged it — the
 *                           hook cannot lose or invent secondary.
 *   PP3 NO OVERSHOOT        a pump behind a SELL never lifts main's price back above where the sell
 *                           started: it buys the dip, it never manufactures a rally
 *   PP4 PUMP BOUNDED        no pump ever spent more than 48% of the secondary the swap that carried it
 *                           moved (the haircut on the gate's full share), so the pot can never be
 *                           drained faster than real flow arrives
 *   PP5 MAIN ATTRIBUTED     every unit of main the hook holds is parked and accounted for; nothing the
 *                           pump acquired is sitting on the hook unowned
 *   PP6 DELIVERY IDENTITY   Σ main acquired == Σ main delivered: burned, dead-sent, held, or parked
 *
 * Plus a deterministic anti-vacuity walk, since the handler swallows reverts and every invariant above
 * is trivially true over an empty world.
 *
 * @dev The real PoolManager is etched from the same Sepolia runtime bytecode the Hardhat fixture injects,
 *      so both layers fuzz the identical venue. The hook itself is deployed to an address carrying the
 *      two permission bits the PoolManager reads out of a hook's address, which is what a real
 *      deployment mines a CREATE2 salt for.
 */
contract GlueHookInvariant is StdInvariant, Test {
    /// @dev The Sepolia PoolManager slot the Hardhat fixture also uses.
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    /// @dev An address carrying EXACTLY `beforeInitialize | afterSwap`.
    address constant HOOK_ADDR = 0x9111000000000000000000000000000000002040;
    /// @dev The REAL canonical GlueStick address (the hook's compile-time constant).
    address constant GLUE_STICK = 0x32b926e7D6ac6B92e50dF40dDfd3555691bc8b3b;
    /// @dev The chain's canonical wrapped native, as the hook's constructor arg.
    address constant NATIVEWRAP = 0x4200000000000000000000000000000000000006;
    address constant ETH = address(0);
    uint24 constant FEE = 3000;
    int24 constant SPACING = 120;
    int24 constant TICK_LO = -887160;
    int24 constant TICK_HI = 887160;
    /// @dev √(1000)·2^96 — a launch price of 1000 token per ETH, matching the Hardhat fixture.
    uint160 constant LAUNCH_SQRT = 2505413655765166104291548792414;

    GlueHook pump;
    MockERC20 token;
    V4PoolHelper helper;
    GlueHookHandler handler;
    bytes32 poolId;

    function setUp() public {
        // The real venue, etched from the same bytecode the Hardhat fixture injects.
        vm.etch(POOL_MANAGER, _poolManagerRuntime());

        // The linked GlueLiquidity library, at the foundry.toml sentinel the artifact points to.
        vm.etch(
            0xb0B0000000000000000000000000000000000B0B,
            vm.getDeployedCode("GlueLiquidity.sol:GlueLiquidity")
        );

        // The GlueStick stand-in at its real canonical address, so burn-intent deliveries run the
        // production Glue path.
        deployCodeTo("MockGlueStick.sol:MockGlueStick", "", GLUE_STICK);

        // The hook, at an address whose low bits ARE its permissions. `deployCodeTo` runs the real
        // constructor, so the immutables are baked in exactly as a mined CREATE2 deployment would.
        deployCodeTo("GlueHook.sol:GlueHook", abi.encode(POOL_MANAGER, NATIVEWRAP), HOOK_ADDR);
        pump = GlueHook(payable(HOOK_ADDR));
        assertEq(uint160(HOOK_ADDR) & GluedV4Core.ALL_HOOK_MASK, pump.REQUIRED_HOOK_FLAGS(), "hook bits");

        token = new MockERC20("PumpMain", "PMN", 18);
        helper = new V4PoolHelper(POOL_MANAGER);

        // THIS contract initialises the pool, so it is the pot's admin and can declare the roles:
        // the token is the defended main, native ETH the secondary the pot spends.
        IPoolManagerMin.PoolKey memory key = _key();
        poolId = keccak256(abi.encode(key));
        IPoolManagerMin(POOL_MANAGER).initialize(key, LAUNCH_SQRT);
        pump.initPot(key, address(token), address(0));

        // Seed the pool and stock the helper deeply enough that it is never the binding constraint.
        vm.deal(address(this), 20_000 ether);
        vm.deal(address(helper), 5_000 ether);
        token.mint(address(helper), 20_000_000e18);
        helper.addLiquidity(key, TICK_LO, TICK_HI, _launchLiquidity());

        handler = new GlueHookHandler(pump, token, helper, key);

        bytes4[] memory sel = new bytes4[](5);
        sel[0] = GlueHookHandler.donate.selector;
        sel[1] = GlueHookHandler.buy.selector;
        sel[2] = GlueHookHandler.sell.selector;
        sel[3] = GlueHookHandler.sellExactOut.selector;
        sel[4] = GlueHookHandler.passTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    function _key() internal view returns (IPoolManagerMin.PoolKey memory k) {
        // ETH is address(0), so it is always currency0 and the token is always currency1
        k = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(token), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
    }

    /**
     * @dev Full-range liquidity implied by 100 ETH against 100_000 token at the launch price. Over a range
     *      this wide the upper bound is effectively infinite, so the token-0 leg collapses to `x·√P` and
     *      the token-1 leg to `y/√P` — the exact V3/V4 formulas with the negligible `1/√P_upper` term
     *      dropped, which only ever under-states liquidity and so can never over-draw the seeder.
     */
    function _launchLiquidity() internal pure returns (uint128) {
        uint256 l0 = (100e18 * uint256(LAUNCH_SQRT)) / GluedV4Core.Q96;
        uint256 l1 = (100_000e18 * GluedV4Core.Q96) / (LAUNCH_SQRT - GluedV4Core.MIN_SQRT_RATIO);
        return uint128(l0 < l1 ? l0 : l1);
    }

    /**
     * @dev The PoolManager's runtime bytecode, read out of the SAME fixture the Hardhat suites use so the
     *      two layers can never drift onto different venues. The file is a TypeScript module whose only
     *      quoted string is the bytecode, so splitting on the quote character extracts it exactly.
     */
    function _poolManagerRuntime() internal view returns (bytes memory) {
        string[] memory parts = vm.split(
            vm.readFile("test/fixtures/v4PoolManagerBytecode.ts"), "\""
        );
        require(parts.length >= 2, "pm bytecode fixture");
        return vm.parseBytes(parts[1]);
    }

    // ── INVARIANTS ──────────────────────────────────────────────────────────────────────────────

    // PP1 — the hook can always honour every pot it hosts. Nothing else it does is meaningful if a
    // donor's secondary is not actually there.
    function invariant_PP1_potSolvency() public view {
        assertGe(handler.secondaryHeld(), handler.secondaryOwed(), "PP1: the hook owes more than it holds");
    }

    // PP2 — the secondary ledger closes exactly. The pump debits the pot before it moves anything, so
    // a swap that failed halfway would show up here as a shortfall or a surplus. The pot's only
    // inflows are donations and harvest fuel (zero in this program-less campaign; the program-armed
    // campaign asserts the same identity with real fuel).
    function invariant_PP2_conservation() public view {
        assertEq(
            handler.potBalance() + handler.ghostPumpSpent(),
            handler.ghostDonated() + handler.ghostFueled(),
            "PP2: pot + pump spends != donations + harvest fuel"
        );
    }

    // PP3 — the sell-side pump buys the dip and nothing more: spending under half of what the seller
    // received, it can never lift main's price back past where the sell started.
    function invariant_PP3_sellPumpNeverOvershoots() public view {
        assertFalse(handler.sellPumpOvershot(), "PP3: a pump behind a sell lifted the price past the sell's start");
    }

    // PP4 — the pump is flow-following by construction. Spending more than the gated share of the swap
    // that triggered it is the shape every pot-draining attack has to take.
    function invariant_PP4_pumpBoundedByItsSwap() public view {
        assertFalse(handler.pumpOutranDemand(), "PP4: a pump spent more than 48% of the swap that carried it");
    }

    // PP5 — main is never held loose. Whatever the cascade could not deliver is parked, and parked is
    // exactly what the hook's balance is: no residue, no rounding crumbs, nothing unowned.
    function invariant_PP5_mainAttributed() public view {
        assertEq(
            token.balanceOf(address(pump)),
            pump.parkedOf(address(token)) + pump.heldOf(address(token)),
            "PP5: the hook holds main it has not accounted for"
        );
    }

    // PP6 — delivery identity: every unit of main the pump acquired left through the cascade, to the
    // burn address, or sits attributed on the hook (held or parked). None of it evaporates.
    function invariant_PP6_deliveryIdentity() public view {
        uint256 acquired = handler.ghostPumpBought();
        uint256 delivered = token.balanceOf(0x000000000000000000000000000000000000dEaD)
            + pump.parkedOf(address(token)) + pump.heldOf(address(token));
        assertEq(delivered, acquired, "PP6: acquired main != delivered main");
    }

    // ── ANTI-VACUITY ────────────────────────────────────────────────────────────────────────────

    /// @notice Drive every action once and prove each landed, so the invariants above are asserted over a
    ///         world that contains real donations and real pumps behind buys and sells alike.
    function test_coverage_handlerActionsLand() public {
        handler.donate(0, 40 ether);
        assertEq(handler.donations(), 1, "the donation landed");
        assertEq(handler.potBalance(), 40 ether, "and credited the pot");

        handler.buy(3 ether);
        assertEq(handler.buys(), 1, "the buy landed");
        assertGt(handler.buyPumps(), 0, "and it pumped");
        assertGt(handler.ghostPumpBought(), 0, "which bought main");

        handler.sell(2_000e18);
        assertEq(handler.sells(), 1, "the sell landed");
        assertGt(handler.sellPumps(), 0, "and a pump fired behind it");

        handler.sellExactOut(1 ether);
        assertGt(handler.exactOutSells(), 0, "the exact-output branch landed");
        assertGt(handler.sellPumps(), 1, "with a pump behind it too");

        handler.passTime(5 minutes);
        assertEq(handler.skips(), 1, "time moved");

        // The pump has moved value both ways, and every ledger still closes
        assertGt(handler.ghostPumpSpent(), 0, "the pump spent from the pot");
        invariant_PP1_potSolvency();
        invariant_PP2_conservation();
        invariant_PP3_sellPumpNeverOvershoots();
        invariant_PP4_pumpBoundedByItsSwap();
        invariant_PP5_mainAttributed();
        invariant_PP6_deliveryIdentity();
    }

    /// @notice A pot far smaller than the pump it could carry spends 80% of itself (the haircut on a
    ///         pot-bound spend) — never overdrawn, never all of it in one pass. Walk it explicitly
    ///         rather than hoping the fuzzer lands on the boundary.
    function test_coverage_thinPotSpendsItsHaircutShare() public {
        handler.donate(1, 0.05 ether);
        uint256 funded = handler.potBalance();
        assertGt(funded, 0, "the pot is funded");

        handler.sell(60_000e18);
        assertGt(handler.sellPumps(), 0, "the thin pot still fired");
        assertEq(handler.ghostPumpSpent(), (funded * 8) / 10, "spending 80% of what it held");
        assertEq(handler.potBalance(), funded - (funded * 8) / 10, "and keeping the haircut's remainder");
        invariant_PP1_potSolvency();
        invariant_PP2_conservation();
        invariant_PP3_sellPumpNeverOvershoots();
        invariant_PP6_deliveryIdentity();
    }

    /// @notice An UNFUNDED pot must be completely invisible: the pump stands aside and the pool behaves
    ///         as though the hook were not there. This is the passthrough guarantee every pool
    ///         adopting the hook relies on before anybody has donated.
    function test_coverage_emptyPotIsInvisible() public {
        assertEq(handler.potBalance(), 0, "starting empty");
        uint160 before = handler.sqrtPrice();

        handler.buy(2 ether);
        handler.sell(1_000e18);

        assertEq(handler.pumps(), 0, "no pump without a pot");
        assertTrue(handler.sqrtPrice() != before, "and both swaps went through the pool");
        assertEq(token.balanceOf(0x000000000000000000000000000000000000dEaD), 0, "nothing was burned");
    }
}
