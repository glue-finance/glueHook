// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GlueHookFixture} from "../helpers/GlueHookFixture.sol";
import {IGlueHook} from "../../contracts/interfaces/IGlueHook.sol";
import {IGlueHookedEngine} from "../../contracts/interfaces/IGlueHookedEngine.sol";
import {IPoolManagerMin, GluedV4Core} from "../../contracts/libs/GluedV4Core.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title  ExtBase — the local fixture of the external auditor-skill suites.
 * @notice Every `Ext*` suite starts from the same shape: the campaign fixture's ETH pool around a
 *         plain 18-decimal MAIN (ETH is the secondary, the pot's recipient is BURN), three funded
 *         actors, and the hostile contracts the firms' checklists call for — a USDT-style
 *         missing-return ERC20, a return-false ERC20, a MAIN that rides the PoolManager's unlock
 *         from inside its own transfer, a native recipient that observes / re-enters / burns gas
 *         at the hook's full-gas push, and a registered Glue engine that does the same from the
 *         full-gas report callback. Helpers live HERE, not on {GlueHookFixture}: the main fixture
 *         stays byte-identical for the suites of record.
 */
abstract contract ExtBase is GlueHookFixture {
    MockERC20 token;
    IPoolManagerMin.PoolKey key;
    bytes32 id;
    address alice;
    address bob;
    address stranger;

    uint128 constant SEED_LIQ = 1e21;
    uint256 constant MAX = type(uint256).max;
    uint256 constant WAD = 1e18;
    bytes32 constant PUMPED_SIG = keccak256("Pumped(bytes32,uint256,uint256)");
    bytes32 constant DELIVERED_SIG = keccak256("Delivered(bytes32,address,uint256,uint8)");
    bytes32 constant RECORDED_SIG = keccak256("HarvestRecorded(bytes32,address,uint256,uint256,bool)");

    function setUp() public virtual {
        _deployCore();
        token = new MockERC20("Main", "MAIN", 18);
        (key, id) = _openEthPool(address(token), address(0));
        token.mint(address(this), 10_000_000e18);
        token.approve(address(pump), MAX);
        alice = makeAddr("ext.alice");
        bob = makeAddr("ext.bob");
        stranger = makeAddr("ext.stranger");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    // ── config shapes ───────────────────────────────────────────────────────────────

    function _cfg(
        uint64 bb,
        uint64 burn,
        uint64 comp,
        address secR,
        address mainR,
        uint256 mm,
        uint256 ms
    ) internal pure returns (IGlueHook.ProgramConfig memory) {
        return IGlueHook.ProgramConfig({
            buybackShareWad: bb,
            burnShareWad: burn,
            compoundShareWad: comp,
            potCompoundShareWad: 0,
            potBurnShareWad: 0,
            publicHarvest: false,
            secondaryRecipient: secR,
            mainRecipient: mainR,
            minMain: mm,
            minSecondary: ms
        });
    }

    /// @dev Everything off, both legs to `who`: what the plain `addLiquidity` ships.
    function _plainCfg(address who) internal pure returns (IGlueHook.ProgramConfig memory) {
        return _cfg(0, 0, 0, who, who, MAX, MAX);
    }

    /// @dev 50% buyback / 50% burn, remainder legs to `secR` / `mainR`, ARMED at 1 wei on both sides.
    function _armedCfg(address secR, address mainR) internal pure returns (IGlueHook.ProgramConfig memory) {
        return _cfg(uint64(WAD / 2), uint64(WAD / 2), 0, secR, mainR, 1, 1);
    }

    /// @dev Create the pool's program from the test contract (the pot admin) with `cfg`.
    function _openProgram(IGlueHook.ProgramConfig memory cfg) internal returns (uint256 a0, uint256 a1) {
        return _openProgramFor(address(this), cfg);
    }

    /// @dev Same, naming the program's owner (and first operator) explicitly.
    function _openProgramFor(address owner, IGlueHook.ProgramConfig memory cfg)
        internal returns (uint256 a0, uint256 a1)
    {
        return pump.addLiquidityAdvanced{value: 50 ether}(key, TICK_LO, TICK_HI, SEED_LIQ, owner, cfg);
    }

    // ── trading shorthands (ETH is currency0 of the fixture pool, MAIN is currency1) ──

    /// @dev Buy MAIN with `eth` of ETH (exact input).
    function _buy(uint256 eth) internal returns (int256 d0, int256 d1) {
        return helper.swap(key, true, -int256(eth));
    }

    /// @dev Sell `amt` of MAIN for ETH (exact input).
    function _sell(uint256 amt) internal returns (int256 d0, int256 d1) {
        return helper.swap(key, false, -int256(amt));
    }

    /// @dev Move the reference onto the live tick and wait one block, so every gate is open.
    function _open() internal {
        _settleReference(key);
        _refill();
    }

    // ── log readers ─────────────────────────────────────────────────────────────────

    /// @dev Number of `Pumped` events the hook emitted in a recorded window.
    function _countPumped(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pump) && logs[i].topics[0] == PUMPED_SIG) ++n;
        }
    }

    /// @dev Number of `Delivered` events the hook emitted in a recorded window.
    function _countDelivered(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pump) && logs[i].topics[0] == DELIVERED_SIG) ++n;
        }
    }

    /// @dev The inner selector of a revert the PoolManager wrapped (`WrappedError(target, selector,
    ///      reason, details)`), or the raw selector when the data is not a wrap.
    function _innerSelector(bytes memory data) internal pure returns (bytes4) {
        if (data.length < 4) return bytes4(0);
        bytes4 outer = bytes4(data);
        if (outer != bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)"))) return outer;
        bytes memory body = new bytes(data.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = data[i + 4];
        ( , , bytes memory reason, ) = abi.decode(body, (address, bytes4, bytes, bytes));
        return reason.length >= 4 ? bytes4(reason) : bytes4(0);
    }

    /// @dev {obligationOf} rebuilt from the hook's OTHER views for the fixture pool alone: its pot
    ///      (when denominated in `asset`), the parked and held ledgers, the program's carry, and the
    ///      `owed` of the recipients the caller names. Equal to `obligationOf(asset)` exactly when the
    ///      named recipients are the only ones ever booked.
    function _obligationFromParts(address asset, address[] memory owedTo) internal view returns (uint256 t) {
        IGlueHook.Pot memory p = pump.potOf(id);
        if (p.secondary == asset) t += p.balance;
        t += pump.parkedOf(asset) + pump.heldOf(asset);
        IGlueHook.Program memory g = pump.programOf(id);
        if (g.exists) t += asset == p.main ? g.carryMain : g.carrySecondary;
        for (uint256 i; i < owedTo.length; ++i) t += pump.owedOf(owedTo[i], asset);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════════
// HOSTILE ACTORS
// ═══════════════════════════════════════════════════════════════════════════════════════

/// @dev USDT-style ERC20: `transfer` / `transferFrom` / `approve` return NOTHING. SafeERC20 must
///      accept the empty return; a naïve `require(token.transfer(...))` would revert.
contract MissingReturnERC20 {
    string public constant name = "MissingReturn";
    string public constant symbol = "MRT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external {
        allowance[msg.sender][spender] = amt;
    }

    function transfer(address to, uint256 amt) external {
        _move(msg.sender, to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) external {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _move(from, to, amt);
    }

    function _move(address from, address to, uint256 amt) private {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @dev Tether-Gold-class ERC20: `transfer` / `transferFrom` return FALSE and move nothing.
contract ReturnFalseERC20 is ERC20 {
    constructor() ERC20("ReturnFalse", "RF") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev A MAIN that RIDES the PoolManager's unlock: while the hook pulls the program's seed from its
///      creator (the transient PAYER window), this token's transfer hook calls `PoolManager.swap`
///      on the same pool — the manager IS unlocked — trying to summon a pump whose settle would be
///      pulled from the payer's allowance instead of the pot. Records what the hook answered.
contract RiderMain is ERC20 {
    address public immutable pm;
    address public victim;
    IPoolManagerMin.PoolKey internal _key;
    int256 public rideAmount;
    bool public armed;
    bool public attempted;
    bool public landed;
    bytes public revertData;

    constructor(address pm_) ERC20("Rider", "RIDE") {
        pm = pm_;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function arm(address victim_, IPoolManagerMin.PoolKey calldata k, int256 amount) external {
        victim = victim_;
        _key = k;
        rideAmount = amount;
        armed = true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (armed && to == pm && from == victim) {
            armed = false;
            attempted = true;
            bool zeroForOne = address(this) == _key.currency0;
            try IPoolManagerMin(pm).swap(
                _key,
                IPoolManagerMin.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: rideAmount,
                    sqrtPriceLimitX96: zeroForOne ? GluedV4Core.MIN_SQRT_RATIO + 1 : GluedV4Core.MAX_SQRT_RATIO - 1
                }),
                ""
            ) returns (int256) {
                // Must never happen: if it did, the frame would be left with an unsettled delta and
                // the outer add would revert — which is what the suite would then observe
                landed = true;
            } catch (bytes memory err) {
                revertData = err;
            }
        }
        super._update(from, to, amount);
    }
}

/// @dev A NATIVE recipient paid at the carrying call's gas (no stipend). `Observe` records what the
///      hook looks like mid-frame (in transient storage); `BurnGas` loops until the gas it was
///      given is gone; `Refuse` reverts. A refusal books the leg and the swap lands; a burner is
///      charged to the swap, which lands iff the 1/64 the EVM keeps can finish the frame (QS7).
contract ProbeRecipient {
    enum Mode { Accept, Observe, BurnGas, Refuse }

    IGlueHook public immutable hook;
    Mode public mode;
    uint256 public pushes;

    // Transient slots (literals: inline assembly only takes direct number constants)
    uint256 private constant OBS_BAL = 0x01;
    uint256 private constant OBS_OBL = 0x02;
    uint256 private constant OBS_HIT = 0x03;

    constructor(IGlueHook hook_) {
        hook = hook_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    /// @notice What the probe saw during the push: the hook's ETH balance and its ETH obligation.
    function observed() external view returns (bool hit, uint256 hookBalance, uint256 obligation) {
        assembly ("memory-safe") {
            hit := tload(OBS_HIT)
            hookBalance := tload(OBS_BAL)
            obligation := tload(OBS_OBL)
        }
    }

    function pull(address asset) external returns (uint256) {
        return hook.claim(asset);
    }

    receive() external payable {
        Mode m = mode;
        if (m == Mode.Refuse) revert("probe: no");
        if (m == Mode.BurnGas) {
            uint256 x;
            while (true) { x = x + 1; } // spins until the forwarded gas is exhausted
        }
        if (m == Mode.Observe) {
            // Transient on purpose: what the probe saw must not depend on the gas it was given
            uint256 bal = address(hook).balance;
            uint256 obl = hook.obligationOf(address(0));
            assembly ("memory-safe") {
                tstore(OBS_HIT, 1)
                tstore(OBS_BAL, bal)
                tstore(OBS_OBL, obl)
            }
            return;
        }
        ++pushes;
    }
}

/// @dev A registered Glue LP engine with the carrying call's gas of callback to misuse. `Observe` snapshots the
///      hook's books at report time; `Matrix` tries EVERY value-moving entry of the hook plus a
///      direct `PoolManager.swap` from inside the report and records what each answered.
contract ProbeEngine is IGlueHookedEngine {
    enum Mode { Record, Observe, Matrix }

    IGlueHook public immutable hook;
    address public immutable pm;
    Mode public mode;
    IPoolManagerMin.PoolKey internal _key;
    bytes32 internal _id;

    uint256 public calls;
    uint256 public lastMain;
    uint256 public lastSec;

    // Observe
    uint256 public obsHookBalance;
    uint256 public obsObligation;
    uint256 public obsPotBalance;
    uint256 public obsDeliveredSec;
    uint256 public obsOwedSec;

    // Matrix: the selector each re-entry attempt was answered with, in entry order
    bytes4[7] public answers;

    constructor(IGlueHook hook_, address pm_) {
        hook = hook_;
        pm = pm_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setPool(IPoolManagerMin.PoolKey calldata k, bytes32 id_) external {
        _key = k;
        _id = id_;
    }

    /// @notice Drive any contract as the engine (value forwarded, revert bubbled).
    function exec(address target, bytes calldata data) external payable returns (bytes memory out) {
        bool ok;
        (ok, out) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(out, 32), mload(out)) }
        }
    }

    function recordHarvest(bytes32 poolId, uint256 deliveredMain, uint256 deliveredSec) external {
        ++calls;
        lastMain = deliveredMain;
        lastSec = deliveredSec;
        Mode m = mode;
        if (m == Mode.Observe) {
            obsHookBalance = address(hook).balance;
            obsObligation = hook.obligationOf(address(0));
            obsPotBalance = hook.potOf(poolId).balance;
            obsDeliveredSec = hook.deliveredCumOf(poolId, address(0));
            obsOwedSec = hook.owedOf(address(this), address(0));
        } else if (m == Mode.Matrix) {
            answers[0] = _try(address(hook), abi.encodeCall(IGlueHook.donate, (_key, 1)), 1);
            answers[1] = _try(address(hook), abi.encodeCall(IGlueHook.claim, (address(0))), 0);
            answers[2] = _try(address(hook), abi.encodeCall(IGlueHook.flushDirect, (_id)), 0);
            answers[3] = _try(address(hook), abi.encodeCall(IGlueHook.harvest, (_key)), 0);
            answers[4] = _try(address(hook), abi.encodeCall(IGlueHook.addProgramLiquidity, (_key, 1)), 0);
            answers[5] = _try(
                address(hook), abi.encodeCall(IGlueHook.removeProgramLiquidity, (_key, 1, address(this))), 0
            );
            answers[6] = _try(
                pm,
                abi.encodeCall(
                    IPoolManagerMin.swap,
                    (
                        _key,
                        IPoolManagerMin.SwapParams({
                            zeroForOne: true,
                            amountSpecified: -1e15,
                            sqrtPriceLimitX96: GluedV4Core.MIN_SQRT_RATIO + 1
                        }),
                        ""
                    )
                ),
                0
            );
        }
    }

    function _try(address target, bytes memory data, uint256 value) private returns (bytes4 sel) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (ok) return bytes4(0xFFFFFFFF); // "it went through" — the suites assert this never shows
        if (ret.length < 4) return bytes4(0);
        sel = bytes4(ret);
        if (sel == bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)"))) {
            bytes memory body = new bytes(ret.length - 4);
            for (uint256 i; i < body.length; ++i) body[i] = ret[i + 4];
            ( , , bytes memory reason, ) = abi.decode(body, (address, bytes4, bytes, bytes));
            sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
        }
    }

    receive() external payable {}
}
