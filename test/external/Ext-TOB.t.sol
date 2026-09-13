// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {ExtBase, MissingReturnERC20, ReturnFalseERC20, ProbeRecipient} from "./ExtBase.sol";
import {IGlueHook} from "../../contracts/interfaces/IGlueHook.sol";
import {IPoolManagerMin} from "../../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "../mocks/MockFeeOnTransferERC20.sol";
import {BlockingERC20} from "../mocks/HostileTokens.sol";

/**
 * @title  ExtTOB — Trail of Bits skills, transposed to the hook.
 * @notice NOT an official audit: Trail of Bits did not review, endorse or sign this suite. It is the
 *         hook's own integration of the firm's PUBLISHED skills (`trailofbits/skills`): the
 *         entry-point analyzer (every state-changing door classified and pinned), sharp-edges
 *         (argument swaps, value/amount confusion, silent no-ops), insecure-defaults (what a plain
 *         creation ships with), the token-integration analyzer (missing-return, return-false,
 *         fee-on-transfer, blocklist) and property-based testing (round trips that never mint
 *         value, quotes that never revert). Check table: audit/external/trail-of-bits.md.
 */
contract ExtTOB is ExtBase {
    bytes4 constant UNAUTHORIZED = bytes4(keccak256("Unauthorized()"));
    bytes4 constant SAFE_ERC20_FAILED = bytes4(keccak256("SafeERC20FailedOperation(address)"));

    // ── entry-point analyzer ────────────────────────────────────────────────────────

    /// TOB1 — pot-admin doors (`initPot`, `setRecipient`, `addLiquidity`, `addLiquidityAdvanced`)
    ///        refuse a stranger with `NotAllowed` and leave the pot untouched; the admin's own call
    ///        goes through (control).
    function test_TOB1_potAdminDoors() public {
        vm.startPrank(stranger);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.initPot(key, address(token), stranger);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.setRecipient(id, stranger);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.addLiquidity{value: 1 ether}(key, 0, 0, SEED_LIQ, stranger);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.addLiquidityAdvanced{value: 1 ether}(key, 0, 0, SEED_LIQ, stranger, _plainCfg(stranger));
        vm.stopPrank();

        assertEq(pump.potOf(id).recipient, address(0), "recipient untouched");
        assertFalse(pump.programOf(id).exists, "no program was created");

        pump.setRecipient(id, alice);
        assertEq(pump.potOf(id).recipient, alice, "the admin's own call moves it");
    }

    /// TOB2 — owner doors (`addProgramLiquidity`, `removeProgramLiquidity`, closed `harvest`,
    ///        `transferProgramOwnership`) and operator doors (`setProgramConfig`, `setProgramOperator`)
    ///        refuse a stranger; once the operator role moves, the OWNER is refused on the operator
    ///        doors and the OPERATOR on the owner doors.
    function test_TOB2_ownerAndOperatorDoors() public {
        _openProgram(_plainCfg(address(this)));
        _buy(1 ether);

        vm.startPrank(stranger);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.addProgramLiquidity{value: 1 ether}(key, 1e18);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.removeProgramLiquidity(key, 1e18, stranger);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.harvest(key);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.transferProgramOwnership(id, stranger);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.setProgramConfig(id, _plainCfg(stranger));
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.setProgramOperator(id, stranger);
        vm.stopPrank();

        // Hand the rules to alice: the owner loses the operator doors, alice never gains the owner's
        pump.setProgramOperator(id, alice);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.setProgramConfig(id, _plainCfg(address(this)));
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.setProgramOperator(id, address(this));

        vm.startPrank(alice);
        pump.setProgramConfig(id, _plainCfg(alice));
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.addProgramLiquidity{value: 1 ether}(key, 1e18);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.removeProgramLiquidity(key, 1e18, alice);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.transferProgramOwnership(id, alice);
        vm.stopPrank();

        IGlueHook.Program memory g = pump.programOf(id);
        assertEq(g.owner, address(this), "owner unchanged");
        assertEq(g.operator, alice, "operator moved exactly once");
        assertEq(g.mainRecipient, alice, "the operator's edit landed");
    }

    /// TOB3 — contract-only doors: the PoolManager callbacks and the hook's self-calls refuse any
    ///        other caller (`NotAllowed`), the V4 unlock callback refuses a non-manager
    ///        (`Unauthorized`), and a manager-driven callback with an UNKNOWN op is refused too.
    function test_TOB3_contractOnlyDoors() public {
        IPoolManagerMin.SwapParams memory params =
            IPoolManagerMin.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});

        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.beforeInitialize(address(this), key, 0);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.afterSwap(address(this), key, params, 0, "");
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.executePump(id, key, true, 1, 1);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.executeHarvest(id, key, 0, 0, false);
        vm.expectRevert(UNAUTHORIZED);
        pump.unlockCallback(abi.encode(uint8(1)));

        // Even the manager cannot make the hook run an op it does not know (OP_SWAP is reserved)
        vm.prank(POOL_MANAGER);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.unlockCallback(abi.encode(uint8(4)));
        vm.prank(POOL_MANAGER);
        vm.expectRevert(IGlueHook.NotAllowed.selector);
        pump.unlockCallback(abi.encode(uint8(99)));
    }

    /// TOB4 — the permissionless doors are really permissionless: a stranger funds the pot, retries
    ///        a parked delivery, and harvests a PUBLIC program; a recipient pulls its own backlog.
    ///        None of them can redirect value to themselves.
    function test_TOB4_permissionlessDoors() public {
        // donate
        vm.prank(stranger);
        assertEq(pump.donate{value: 1 ether}(key, 1 ether), 1 ether, "a stranger funds the pot");
        assertEq(pump.potOf(id).balance, 1 ether, "and the pot booked it");

        // flushDirect — on a pool whose live recipient refused (blocklist main)
        BlockingERC20 blocky = new BlockingERC20();
        address treasury = makeAddr("treasury");
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openEthPool(address(blocky), treasury);
        blocky.setBlocked(treasury, true);
        pump.donate{value: 10 ether}(k2, 10 ether);
        helper.swap(k2, true, -int256(1 ether));
        uint256 parked = pump.parkedDirectOf(id2);
        assertGt(parked, 0, "the refused delivery parked");
        blocky.setBlocked(treasury, false);
        vm.prank(stranger);
        uint256 flushed = pump.flushDirect(id2);
        assertEq(flushed, parked, "a stranger retried the whole park");
        assertEq(blocky.balanceOf(treasury), parked, "to the pot's recipient, not to the caller");
        assertEq(pump.parkedDirectOf(id2), 0, "park cleared");

        // public harvest — legs go to the configured recipients, never to the harvester
        ProbeRecipient probe = new ProbeRecipient(pump);
        IGlueHook.ProgramConfig memory cfg = _cfg(0, 0, 0, address(probe), bob, MAX, MAX);
        cfg.publicHarvest = true;
        _openProgram(cfg);
        _buy(2 ether);
        _sell(2_000e18);
        uint256 strangerEth = stranger.balance;
        uint256 strangerTok = token.balanceOf(stranger);
        vm.prank(stranger);
        (uint256 fM, uint256 fS) = pump.harvest(key);
        assertGt(fM, 0);
        assertGt(fS, 0);
        assertEq(stranger.balance, strangerEth, "the harvester got no ETH");
        assertEq(token.balanceOf(stranger), strangerTok, "and no token");
        assertEq(token.balanceOf(bob), fM, "the main leg went to the main recipient");
        assertEq(address(probe).balance, fS, "the secondary leg to the secondary recipient");

        // claim — only one's own backlog
        probe.setMode(ProbeRecipient.Mode.Refuse);
        _buy(1 ether);
        pump.harvest(key);
        uint256 owed = pump.owedOf(address(probe), address(0));
        assertGt(owed, 0, "the refusal booked a backlog");
        vm.prank(stranger);
        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.claim(address(0)); // a stranger has nothing to claim
        probe.setMode(ProbeRecipient.Mode.Accept);
        uint256 before = address(probe).balance;
        assertEq(probe.pull(address(0)), owed, "the recipient pulls exactly its backlog");
        assertEq(address(probe).balance - before, owed, "and it landed");
        assertEq(pump.owedOf(address(probe), address(0)), 0, "cleared");
    }

    // ── insecure defaults ───────────────────────────────────────────────────────────

    /// TOB5 — the plain `addLiquidity` ships with EVERYTHING off: zero shares, both remainder
    ///        recipients the owner, manual harvest closed, auto-harvest disarmed (both mins at max,
    ///        `armed == false`), owner == operator, not native — and it is SILENT behind swaps: no
    ///        harvest, no delivery, no pump on an unfunded pot.
    function test_TOB5_plainCreationDefaults() public {
        pump.addLiquidity{value: 50 ether}(key, TICK_LO, TICK_HI, SEED_LIQ, alice);
        IGlueHook.Program memory g = pump.programOf(id);
        assertTrue(g.exists);
        assertEq(g.buybackShareWad, 0);
        assertEq(g.burnShareWad, 0);
        assertEq(g.compoundShareWad, 0);
        assertEq(g.potCompoundShareWad, 0);
        assertEq(g.potBurnShareWad, 0);
        assertFalse(g.publicHarvest, "manual harvest closed");
        assertFalse(g.armed, "auto-harvest disarmed");
        assertFalse(g.native, "not native");
        assertEq(g.minMain, MAX);
        assertEq(g.minSecondary, MAX);
        assertEq(g.owner, alice);
        assertEq(g.operator, alice);
        assertEq(g.mainRecipient, alice);
        assertEq(g.secondaryRecipient, alice);
        assertEq(g.liquidity, SEED_LIQ);
        assertEq(pump.potOf(id).recipient, address(0), "the pot's own recipient is untouched by the program");

        vm.recordLogs();
        _buy(1 ether);
        _sell(1_000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countPumped(logs), 0, "no pump (empty pot)");
        assertEq(_countDelivered(logs), 0, "no delivery (disarmed program)");
        assertEq(pump.potOf(id).balance, 0, "nothing flowed into the pot");
    }

    // ── sharp edges ─────────────────────────────────────────────────────────────────

    /// TOB6 — argument swaps are type-identical and must fail loudly: `initPot(key, RECIPIENT, MAIN)`
    ///        is `BadRoles`, so is a native main, and `launchPool` on a key that names another hook.
    function test_TOB6_argumentSwapsFailLoudly() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        IPoolManagerMin.PoolKey memory k2 = IPoolManagerMin.PoolKey({
            currency0: ETH, currency1: address(other), fee: FEE, tickSpacing: SPACING, hooks: HOOK_ADDR
        });
        IPoolManagerMin(POOL_MANAGER).initialize(k2, LAUNCH_SQRT);

        vm.expectRevert(IGlueHook.BadRoles.selector);
        pump.initPot(k2, alice, address(other)); // swapped: `alice` is not a currency of the pool
        vm.expectRevert(IGlueHook.BadRoles.selector);
        pump.initPot(k2, ETH, alice); // the network token can never be the defended side

        IPoolManagerMin.PoolKey memory foreign = k2;
        foreign.hooks = address(0);
        foreign.fee = 500;
        foreign.tickSpacing = 10;
        vm.expectRevert(IGlueHook.BadRoles.selector);
        pump.launchPool{value: 1 ether}(
            foreign, LAUNCH_SQRT, address(other), address(0), 0, 0, SEED_LIQ, alice, _plainCfg(alice)
        );

        assertFalse(pump.potOf(keccak256(abi.encode(k2))).configured, "nothing was declared");
    }

    /// TOB7 — value/amount confusion on `donate`: a native pot refuses `msg.value != amount` in
    ///        BOTH directions and a zero donation; an ERC20 pot refuses any value, a zero amount,
    ///        and an unapproved pull (the token's own error bubbles — no silent zero credit).
    function test_TOB7_donateValueAmountConfusion() public {
        vm.expectRevert(IGlueHook.BadDonation.selector);
        pump.donate{value: 1 ether}(key, 2 ether);
        vm.expectRevert(IGlueHook.BadDonation.selector);
        pump.donate{value: 2 ether}(key, 1 ether);
        vm.expectRevert(IGlueHook.BadDonation.selector);
        pump.donate(key, 0);
        assertEq(pump.potOf(id).balance, 0, "nothing credited");

        MockERC20 main2 = new MockERC20("Main2", "MN2", 18);
        MockERC20 sec2 = new MockERC20("Sec2", "SC2", 18);
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openErc20Pool(address(main2), address(sec2), address(0), false);
        sec2.mint(address(this), 10e18);

        vm.expectRevert(IGlueHook.BadDonation.selector);
        pump.donate{value: 1}(k2, 1e18);
        vm.expectRevert(IGlueHook.BadDonation.selector);
        pump.donate(k2, 0);
        vm.expectRevert(); // no allowance: the ERC20 reverts, the hook never books a phantom credit
        pump.donate(k2, 1e18);
        assertEq(pump.potOf(id2).balance, 0, "nothing credited");

        sec2.approve(address(pump), 1e18);
        assertEq(pump.donate(k2, 1e18), 1e18, "the well-formed call credits exactly the amount");
    }

    /// TOB8 — silent no-ops are refused: zero liquidity on creation and on add, a removal of zero,
    ///        of more than the program holds, or to `address(0)`, are all `BadConfig`.
    function test_TOB8_zeroAndBoundsAreLoud() public {
        vm.expectRevert(IGlueHook.BadConfig.selector);
        pump.addLiquidity{value: 1 ether}(key, 0, 0, 0, alice);

        _openProgram(_plainCfg(address(this)));
        vm.expectRevert(IGlueHook.BadConfig.selector);
        pump.addProgramLiquidity{value: 1 ether}(key, 0);
        vm.expectRevert(IGlueHook.BadConfig.selector);
        pump.removeProgramLiquidity(key, 0, address(this));
        vm.expectRevert(IGlueHook.BadConfig.selector);
        pump.removeProgramLiquidity(key, SEED_LIQ + 1, address(this));
        vm.expectRevert(IGlueHook.BadConfig.selector);
        pump.removeProgramLiquidity(key, 1, address(0));
        assertEq(pump.programOf(id).liquidity, SEED_LIQ, "liquidity untouched");
    }

    // ── token-integration analyzer ──────────────────────────────────────────────────

    /// TOB9 — weird-ERC20 "missing return value" (USDT class) as the pot's secondary: the donation
    ///        pulls through SafeERC20, credits exactly, and the obligation equals what the hook holds.
    function test_TOB9_missingReturnSecondary() public {
        MockERC20 main2 = new MockERC20("Main2", "MN2", 18);
        MissingReturnERC20 mrt = new MissingReturnERC20();
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openErc20Pool(address(main2), address(mrt), address(0), false);
        mrt.mint(address(this), 1_000e18);
        mrt.approve(address(pump), MAX);

        assertEq(pump.donate(k2, 1_000e18), 1_000e18, "credited 1:1");
        assertEq(pump.potOf(id2).balance, 1_000e18, "pot");
        assertEq(pump.obligationOf(address(mrt)), 1_000e18, "obligation");
        assertEq(mrt.balanceOf(address(pump)), 1_000e18, "held");
    }

    /// TOB10 — weird-ERC20 "returns false" (Tether-Gold class) as the secondary: the donation reverts
    ///         `SafeERC20FailedOperation(token)` and nothing is credited — no phantom pot.
    function test_TOB10_returnFalseSecondary() public {
        MockERC20 main2 = new MockERC20("Main2", "MN2", 18);
        ReturnFalseERC20 rf = new ReturnFalseERC20();
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openErc20Pool(address(main2), address(rf), address(0), false);
        rf.mint(address(this), 1_000e18);
        rf.approve(address(pump), MAX);

        vm.expectRevert(abi.encodeWithSelector(SAFE_ERC20_FAILED, address(rf)));
        pump.donate(k2, 1_000e18);
        assertEq(pump.potOf(id2).balance, 0, "nothing credited");
        assertEq(pump.obligationOf(address(rf)), 0, "nothing owed");
    }

    /// TOB11 — fee-on-transfer secondary: the credit is the MEASURED arrival (900 of 1000 at 10%),
    ///         never the nominal amount, and the obligation equals the hook's real balance.
    function test_TOB11_feeOnTransferSecondaryMeasured() public {
        MockERC20 main2 = new MockERC20("Main2", "MN2", 18);
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20("Taxed", "TAX", 18, 1_000); // 10%
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openErc20Pool(address(main2), address(fot), address(0), false);
        fot.mint(address(this), 1_000e18);
        fot.approve(address(pump), MAX);

        assertEq(pump.donate(k2, 1_000e18), 900e18, "credited what arrived");
        assertEq(pump.potOf(id2).balance, 900e18, "pot");
        assertEq(pump.obligationOf(address(fot)), fot.balanceOf(address(pump)), "obligation == balance");
    }

    /// TOB12 — blocklist main: a refused live delivery PARKS (booked per pool, never lost); once the
    ///         recipient is unblocked `flushDirect` pays the whole park and clears it.
    function test_TOB12_blocklistRecipientParksThenFlushes() public {
        BlockingERC20 blocky = new BlockingERC20();
        address treasury = makeAddr("treasury");
        (IPoolManagerMin.PoolKey memory k2, bytes32 id2) = _openEthPool(address(blocky), treasury);
        blocky.setBlocked(treasury, true);
        pump.donate{value: 10 ether}(k2, 10 ether);

        vm.recordLogs();
        helper.swap(k2, true, -int256(1 ether));
        (bool pumped, , uint256 bought) = _lastPumped(vm.getRecordedLogs());
        assertTrue(pumped);
        assertEq(pump.parkedDirectOf(id2), bought, "the whole buy parked");
        assertEq(pump.parkedOf(address(blocky)), bought, "in the asset ledger too");
        assertEq(blocky.balanceOf(address(pump)), bought, "and the hook holds it");

        vm.expectRevert(IGlueHook.PotNotReady.selector);
        pump.flushDirect(id2); // still blocked: the park stays
        assertEq(pump.parkedDirectOf(id2), bought);

        blocky.setBlocked(treasury, false);
        assertEq(pump.flushDirect(id2), bought, "paid in full");
        assertEq(blocky.balanceOf(treasury), bought);
        assertEq(pump.parkedDirectOf(id2), 0);
        assertEq(pump.parkedOf(address(blocky)), 0);
    }

    // ── property-based testing ──────────────────────────────────────────────────────

    /// TOB13 — round trip never mints value: `addProgramLiquidity(L)` then
    ///         `removeProgramLiquidity(L)` returns at most what was put in (V4 rounds the mint up
    ///         and the burn down, one wei per side at most), the principal lands on `to`, the
    ///         program's liquidity is back where it was, and the hook's own inventory is unchanged.
    function testFuzz_TOB13_roundTripNeverMintsValue(uint128 liq) public {
        liq = uint128(bound(liq, 1e12, 1e21));
        _openProgram(_plainCfg(address(this)));
        uint256 hookEth = address(pump).balance;
        uint256 hookTok = token.balanceOf(address(pump));

        (uint256 a0, uint256 a1) = pump.addProgramLiquidity{value: 50 ether}(key, liq);
        assertEq(pump.programOf(id).liquidity, SEED_LIQ + liq, "tracked");

        uint256 bobEth = bob.balance;
        uint256 bobTok = token.balanceOf(bob);
        (uint256 r0, uint256 r1) = pump.removeProgramLiquidity(key, liq, bob);

        assertLe(r0, a0, "ETH out <= ETH in");
        assertLe(r1, a1, "token out <= token in");
        assertLe(a0 - r0, 1, "at most one wei of rounding on ETH");
        assertLe(a1 - r1, 1, "at most one wei of rounding on token");
        assertEq(bob.balance - bobEth, r0, "principal landed on `to`");
        assertEq(token.balanceOf(bob) - bobTok, r1);
        assertEq(pump.programOf(id).liquidity, SEED_LIQ, "back to the seed");
        assertEq(address(pump).balance, hookEth, "hook inventory: ETH unchanged");
        assertEq(token.balanceOf(address(pump)), hookTok, "hook inventory: token unchanged");
    }

    /// TOB14 — `quotePump` never reverts for any demand and is bounded by the pot, by the gate's
    ///         maximum share after the haircut, and is monotone in the demand; a zero spend always
    ///         comes with a zero floor and vice versa.
    function testFuzz_TOB14_quoteBoundedAndTotal(uint256 demand) public {
        demand = bound(demand, 1, type(uint256).max >> 80);
        _donateEth(key, 20 ether);
        _open();

        (uint256 spend, uint256 minOut) = pump.quotePump(key, demand);
        assertLe(spend, 20 ether, "never above the pot");
        // demand · 60% share · 80% haircut is the loosest demand ceiling; +1 for the two floors
        assertLe(spend, (demand * pump.PUMP_SHARE_MAX_WAD() / WAD) * 8_000 / 10_000 + 1, "never above the demand ceiling");
        assertEq(spend == 0, minOut == 0, "a spend and its floor come together");

        (uint256 half, ) = pump.quotePump(key, demand / 2 + 1);
        assertLe(half, spend, "monotone in the demand");
    }
}
