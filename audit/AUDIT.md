# GlueHook — Security Audit

**Contract:** `contracts/GlueHook.sol` (contract `GlueHook`, a Uniswap V4 buyback-and-burn hook) + its
DELEGATECALL-linked `contracts/libs/GlueLiquidity.sol` harvest engine
**Version reviewed:** commit at the tip of `main` at the time of this report
**Compiler:** solc `0.8.35`, EVM target `prague`, `viaIR`, `optimizer_runs = 1`, revert strings stripped
**Runtime size:** `GlueHook` 19,439 bytes (under the 24,576-byte EIP-170 limit), `GlueLiquidity`
19,612 bytes (the pump's sizing arithmetic and the native report live in the library, next to the
harvest engine)
**License:** BUSL-1.1 (`LICENCE.txt`)

This is a self-audit performed alongside development. It is written to be independently
reproducible: every claim below is backed by a test in `test/` that a reader can run with
`forge test`. Where a property is a theorem it is stated as one and then discharged by a fuzzed or
stateful test; where the review found a real, non-obvious behaviour it is written up as a finding
with its exact economic bound.

---

## 1. Scope

### In scope
- `contracts/GlueHook.sol` — the hook: pot factory (STATIC-FEE pools only — a key carrying the
  dynamic-fee sentinel is refused on both creation doors), the pump (`afterSwap`, behind swaps in
  BOTH directions, sized by the fee ceiling, the spend bucket, the demand ceiling and the
  reference gate), the pool's time-weighted reference tick, donations, the Glue burn/delivery
  cascade (unglue, wrapper park, held-forever), the LP PROGRAM layer (single
  owner-controlled liquidity position per pool with auto-harvest, auto-compound, and a per-side
  fee split), the ONE-TRANSACTION launch (`launchPool`: initialise + roles + program + seed in a
  single call), the NATIVE-program report to a Glue LP engine (`deliveredCumOf` +
  `recordHarvest`), and all views.
- `contracts/libs/GlueLiquidity.sol` — the hook's DELEGATECALL-linked engine (the pump's SIZING —
  the four ceilings, the bucket's credit and spend, the gate's share — the pot role
  declaration — including the glueable-main gate and the best-effort `ensureWrapper` — and the
  recipient move, program creation and the seed/add liquidity mint, the two role
  hand-offs, the two fee collects, config validation, the flat harvest split,
  the compound mint, the whole DELIVERY engine — the buyback split's placement, the Glue
  burn, recipient pushes and the parked/held/owed booking — and the NATIVE stamp, pin, delivered
  ledger and `recordHarvest` report). It declares no state of its own:
  every function runs in the hook's own storage,
  address and balance through storage pointers passed from the hook's declarations, and `msg.sender`
  is preserved so the admin/owner gates are unchanged — it is security-equivalent to inlined hook
  code and is reviewed as part of the hook.
- `contracts/interfaces/IGlueHook.sol` — the external surface.
- `contracts/interfaces/IGlueStickMin.sol` / `IGlueWrapperMin.sol` — the minimal Glue Protocol
  surface the hook talks to (`wrapperOf`, `ensureWrapper`, `isRegisteredEngine`, and the wrapper's
  pure-burn `unglue`).
- `contracts/interfaces/IGlueHookedEngine.sol` — the ONE callback a native program's engine
  receives (`recordHarvest`), MIT so any engine may implement it.
- `contracts/libs/GluedV4Core.sol` — the V4 primitives the hook relies on (`computeSwapStep`,
  `quoteSwapStep`, `tangentReserve`, `swapFee`, `getSqrtRatioAtTick`, liquidity math, the unlock
  callback frame, batched slot0/liquidity/position reads).
- `contracts/libs/GluedMath.sol` — 512-bit muldiv.

### Out of scope (dependencies, trusted)
- The Uniswap V4 `PoolManager` itself. The suite etches the real Sepolia runtime bytecode and trades
  against it, so the hook's interaction with the real venue is exercised, but the PoolManager is not
  the subject of this review.
- The Glue Protocol's `GlueStick` singleton (`GLUE_STICK`, the same address on every chain). The
  hook talks to it defensively on every path: creation-time `ensureWrapper` under `try/catch`
  (a refusal never blocks a pool), and every burn's `unglue` accepted only on the hook's own
  verified balance drop, falling through to the held-forever ledger otherwise — so a missing,
  reverting or lying GlueStick degrades a burn into a hold, never into a stuck swap or a fake burn.
  The suite exercises the integration against a faithful stand-in etched at the real canonical
  address.
- OpenZeppelin's `SafeERC20`/`Address` (vendored as a git submodule at a release tag).

---

## 2. System model

A single hook singleton is deployed once per chain to a mined address whose low 14 bits equal the
two permission flags the PoolManager reads (`beforeInitialize | afterSwap` = `0x2040`). The
constructor asserts this, so a mis-mined address fails at deploy time. The hook never touches a
swapper's own trade: it has no `beforeSwap` and returns no delta.
It takes two immutable arguments — the chain's PoolManager and **`NATIVEWRAP`**, the chain's
canonical wrapped native (the WETH9-style wrapper Uniswap's own periphery uses; `address(0)` on a
chain with no spendable native coin). The Glue Protocol's **`GLUE_STICK`** singleton is a
compile-time constant, the same address on every chain. The recommended deployment is two
plain-CREATE transactions from a mined fresh key — the
`GlueLiquidity` library at nonce 0, the hook (linked against it) at nonce 1 — giving the same two
addresses on every EVM chain regardless of the per-chain constructor arguments.

Any pool that names the hook gets a **pot**. The pool's initialiser is captured as the pot's
**admin** (`beforeInitialize`), and the admin declares the roles once (`initPot`): one of the pool's
two currencies is **MAIN** (defended, bought back, delivered) and the other is **SECONDARY** (the
only currency the pot holds and the only currency `donate` accepts). The SECONDARY may be native
ETH or any ERC20, so the hook is pair-agnostic on the buying side. The MAIN must be **GLUEABLE**:
the network token and `NATIVEWRAP` are rejected as main outright, because every burn is the Glue
Protocol's own `unglue` and neither can run it. Declaring a pot also **ensures the main's glue
exists** (`GLUE_STICK.ensureWrapper`, best effort under `try/catch` — a refused or missing
GlueStick never blocks the pool; that main's burns settle to the held ledger instead).

The same three steps collapse into ONE transaction through **`launchPool`**: the hook calls
`PoolManager.initialize` itself, then runs the `initPot` and `addLiquidityAdvanced` bodies with
identical validation, events and funding rules. The admin capture stays sound because the
PoolManager **skips hook callbacks when the hook itself is the caller**: `beforeInitialize` never
runs on a launch, the pot's admin slot is provably virgin (a successful initialise proves the pool
was fresh, and only `beforeInitialize` — one shot per pool — could ever have written it), and
`launchPool` records its own caller as the admin, exactly what the callback would have recorded
had the launcher initialised the pool directly. A hook-driven initialise OUTSIDE `launchPool` is
unreachable in production (the hook calls `initialize` nowhere else); forced in a test, it leaves
an inert pot (admin never set, `initPot` permanently refused) rather than one the hook owns.

ONE mechanic spends the pot, settled inside a third party's swap in either direction:

| Mechanic | Trigger | Effect |
|---|---|---|
| **Pump** (`afterSwap`) | ANY swap on a funded pool — a SECONDARY → MAIN buy or a MAIN → SECONDARY sell | spends pot secondary to buy main behind the swapper's trade (adding to a buy, buying the dip a sell just made) and delivers it |

The swapper's own trade is the pool's plain execution; the pump is the hook's own swap, run in an
isolated `try/catch` frame, sized by the smallest of FOUR ceilings and then an 80% haircut: the
**fee ceiling** `f·R`, the **spend bucket** (at most one fee ceiling, credited `k = 4` times the
fee every funded swap pays plus one ceiling per 30 minutes of time — the pot's pace is tied to what
the pool earns), the **demand ceiling** (a share of the secondary the swap moved) and the
**reference gate** that sets that share — 60% at or below the pool's time-weighted **reference
tick**, `f/d` above it, where `d` is main's premium over the reference. The reference is a per-pot
observation (a ten-minute time constant, fed only by ticks that stood across a block boundary, the
pot's own pumps excluded; free to fall, capped to rise at most 296 ticks ≈ 3% a minute), stored in
the pot's own storage slot, seeded at `initPot` and whenever a donation funds an empty pot, bounded
integer arithmetic throughout. §4 proves each ceiling's property.

Everything the pump acquires is routed through the **delivery cascade** to the pot's recipient.
`recipient == address(0)` means BURN, and the burn is the Glue Protocol's own — the hook never
destroys supply itself. The pot's main is **classified once** at declaration through the GlueStick
registry (`wrapperOf`): a glued main burns through an exact-amount approval to its **own
GlueWrapper**, then `unglue` with an **empty collateral list** (a PURE BURN — the main is pulled
from the hook and destroyed in-protocol; nothing is redeemed and the glue's backing concentrates
for every remaining holder); a main that IS a GlueWrapper (the ERC20 face of a wrapped collection,
which no unglue can burn by the wei) is **parked on the wrapper's own address** — the one custody
Glue's supply oracle subtracts from circulation; a fresh main has its glue ensured best-effort at
declaration and lazily at its first burn. The unglue is accepted **only on the hook's verified
balance drop** — a codeless wrapper or a lying token never counts as burned — and a refusal falls
through to the terminal sink: the amount is **held on the hook FOREVER**. The hold is terminal by
design: there is no withdrawal path for it, so custody IS the burn (`heldOf`), and the asset is
flagged unburnable on the first refusal so the probe never runs again. Every leg is tolerant (a
failure reports sideways, never reverts), so no burn can ever revert the carrying swap. A live
recipient is a literal target; a refusal parks per-pool, retryable through `flushDirect`.

**The LP PROGRAM layer.** The pot admin may additionally create the pool's ONE hook-held liquidity
position (`addLiquidity` = everything off, `addLiquidityAdvanced` = full rules at creation, both
naming an explicit `owner`). The program carries TWO INDEPENDENT roles: the OWNER holds the
property (add/remove liquidity, harvest, transferable via `transferProgramOwnership`) and the
OPERATOR edits the split rules (`setProgramConfig`; the role starts on the owner and moves via
`setProgramOperator`). Each surrenders on its own terms: a zeroed operator freezes the rules
forever while the owner keeps the position, and a zeroed owner (at creation or by transfer) locks
the liquidity forever and force-opens the manual harvest. The program's fees are harvested —
automatically inside `afterSwap`
when the accrued fees reach the configured minimums (inherently public: any swap triggers it), or
manually through `harvest(key)`, which is OWNER-ONLY unless the config's `publicHarvest` opens it
to anyone. The
split is FLAT: every share reads off the GROSS fees of its side, and the two shares that can claim
a side (`compound + buyback` on the secondary, `compound + burn` on the main) must sum to at most
100% at set-time. The buyback share is credited straight to the pool's own pot (the buyback fuel),
the burn share runs the Glue burn, and each side's exact remainder goes to its single
recipient (which must be live whenever the side's shares sum below 100%). The COMPOUND budget —
`compoundShareWad` of both sides PLUS the program's CARRY (whatever earlier mints could not
place) — is re-minted into the program's own position at the live price across its fixed range;
whichever side binds caps the mint, and the unplaced rest returns to the carry, retried at every
next harvest without ever leaking to the pot or a recipient. The mint runs in its own external
frame with a hard budget check — it can never consume more than its budget or block the harvest;
any revert simply leaves the budget in the carry. Recipient pushes run at the carrying call's
gas and never revert; a refusal books in a per-`(recipient, asset)` owed ledger that folds into the next successful push
and is always claimable with full gas (`claim`). The two surrenders are independent one-way
levers, both by the same mechanism (`msg.sender` can never be zero): the operator's
`setProgramOperator(poolId, address(0))` freezes the split rules forever without touching the
owner's property, and the owner's zero (creation or `transferProgramOwnership(poolId, address(0))`)
locks the liquidity forever with `publicHarvest` forced on so an ownerless program is never
manually unharvestable. Richer custody policy (timelocks, vesting, DAO control) is built ON TOP by
transferring ownership to a contract that implements it. All booking precedes every external send
(CEI), and a burn share is always legal — the main is glueable by construction (`initPot` enforced
it). The pool's LP fee is NOT an operator surface: the hook serves STATIC-FEE pools only (a key
carrying the dynamic-fee sentinel `0x800000` is refused at `beforeInitialize` AND at `launchPool`,
which the PoolManager's callback-skip would otherwise let through), so the fee every trader and LP
sees is immutable in the key. The swap math still reads the LIVE `slot0.lpFee` — on the pools the
hook serves the two always agree, and the slot is the authoritative source that composes with the
protocol fee.

**The BUYBACK SPLIT.** The same operator additionally owns two shares over the POT'S OUTPUT
(`potCompoundShareWad`, `potBurnShareWad`): before the pot's recipient logic runs, every delivery
of bought main carves `⌊out·potCompound/1e18⌋` into the program's compound CARRY
(booked as delivery mode `COMPOUNDED`, it becomes position liquidity at the next harvest's mint)
and `⌊out·potBurn/1e18⌋` into the Glue burn; the exact subtraction remainder follows the pot's
recipient unchanged. Set-time laws mirror the fee split: the two shares sum to at most 100%,
and a pool with no program reads both shares as zero (the whole
output follows the pot's recipient — plain `addLiquidity` also ships with both at zero, so nothing
is armed without the operator's explicit opt-in). When the pot's recipient is itself `address(0)`,
the burn share and the remainder merge into ONE cascade walk. The carry credit is pure accounting
inside the already-`try/catch`-isolated placement, so the split introduces no new swap-revert path;
the carry is a term of `obligationOf`, so custody covers it at all times, and it survives a full
liquidity exit (pumps keep filling the carry while the position is empty; a later re-add re-mints
it).

**NATIVE programs (the Glue staking integration).** At program creation (`createProgram`, reached
through `launchPool`, `addLiquidity` and `addLiquidityAdvanced`) the hook asks the `GLUE_STICK`
whether the creator is a REGISTERED Glue LP engine — a tolerant raw `staticcall` to
`isRegisteredEngine(msg.sender)`: a codeless Stick, a revert, a short return or a word other than
`1` all read `false`, so the plain path is never blocked. A `true` stamps the program `native`
(one bool in the program's slot 0) and PINS it: the engine becomes owner, first operator and BOTH
remainder recipients whatever was passed; `transferProgramOwnership` refuses (a new owner and a
surrender alike) and a config moving either recipient off the owner is `BadConfig`, while shares,
`publicHarvest`, the mins and the operator seat stay editable so the engine's config sync keeps
working. On EVERY harvest of a native program — the in-swap auto-harvest, the manual `harvest`,
the harvest-first inside the program's own add / remove — the settlement (`place`) runs the
program's two remainder pushes with `_payRecipient` now returning what actually LANDED (push +
any `owed` backlog folded in; zero when the leg was booked owed), and, after every send, burn and
compound of the frame, advances `deliveredCum[pool][asset]` by those amounts and fires
`IGlueHookedEngine.recordHarvest(poolId, dMain, dSec)` at the engine as a raw call at the
carrying call's gas (no stipend), return data ignored, revert swallowed — `HarvestRecorded(..., recorded)`
tells which. The ledger advances whether or not the callback succeeded; a frame that landed
nothing is not reported. The callback runs inside the hook's transient guard (every entry that
reaches `place` — `afterSwap`, `harvest`, `addProgramLiquidity`, `removeProgramLiquidity` — is
`guarded`), so an engine re-entering the hook is thrown out with `Reentrancy` while its report
still completes. The hook hardcodes no engine and trusts none: the engine sees only what the hook
already delivered, and the monotonic ledger (`deliveredCumOf`) is the exactly-once source of truth
it reconciles a missed callback against. A non-native program takes ZERO new code paths.

---

## 3. Threat model

The hook holds other people's money (donations) and spends it inside strangers' swaps. The attacker
surface is therefore:

1. **Farm the pump at an artificial price** by pushing spot before trading, so the pump buys at
   the pusher's inflated price and the pusher sells into it (manipulate–dump–unwind).
2. **Farm the pump** by sandwiching it (front-run the swap that triggers it, back-run the price
   bump), or by manufacturing volume to make the pot spend itself while holding a bag.
3. **Brick a pool** so the hook makes its swaps revert (griefing).
4. **Steal or strand main** through a hostile main token or recipient in the delivery cascade.
5. **Double-spend or invent secondary** through reentrancy or accounting drift.
6. **Hijack a pot's configuration** (admin capture, role re-declaration).
7. **Abuse the LP program** (harvest-split drift, re-entering a bounded push, editing rules after
   the operator role was zeroed, taking another owner's liquidity, mixing principal with fees on an
   add/remove).
8. **Fake or grief the Glue burn** (a lying/absent GlueStick "succeeding" without pulling, a main
   that blocks the stick's pull, a main Glue refuses to admit) — closed by the verified balance
   drop and the held-forever fall-through: the worst case is a hold, never a fake burn, a stuck
   swap or a blocked pool creation.
9. **Smuggle in a dynamic-fee pool** (whose fee an operator could then move under traders, and
   whose sentinel `key.fee` would poison any math that read it) — closed at the door: BOTH
   creation paths refuse the sentinel outright, so every pool the hook serves carries one
   immutable fee for its whole life.

Each is addressed below and mapped to the test that exercises it.

---

## 4. Formal properties (the math, with proofs)

### 4.1 The swapper's trade is the pool's own — exactly

**Claim.** A swapper on a hooked pool receives *precisely* what the same pool without the hook
would have paid for the same input at the same price — LP fee and price impact included. The pump
runs AFTER their trade has settled and never touches it.

**Why.** The hook has no `beforeSwap` and returns no delta: the PoolManager executes the swapper's
trade untouched, and only then calls `afterSwap`, where the pump is the hook's OWN swap in an
isolated frame. Nothing the hook does can change what the swapper was paid. There is no internal
fill to price and therefore no fill price to manipulate — the one surface V2's shield had.

**Discharge.**
- `test_A1_sellerPaidPoolEquivalent` — three sell sizes, each measured under a state snapshot
  against a hookless twin pool (same currencies, fee, spacing, price, liquidity). Wei-exact
  equality of the seller's payout while the pump fires behind them.
- `testFuzz_FM3_sellerParity` — the same property over 512 random sell sizes, plus: the pump behind
  a sell never lifts main past where the sell started.
- Invariant **PP3** — over the whole random walk, no sell-side pump ever overshoots the sell's
  starting price.

### 4.2 The reference gate closes manipulate–dump–unwind — `s(d) = min(s_max, f/d)`

**Claim.** An attacker who pushes main's spot a premium `d` above the reference and then trades so
that pumps fire at the inflated price cannot profit from them, for any push size.

**Derivation.** Pushing main up by a factor `(1+d)` on a constant-product pool and unwinding costs
the pusher `2·f` per unit of value pushed in fees alone (the round trip's impact cancels; the fees
do not). A pump of size `V` at the pushed price buys main `d` dearer than the reference, so the most
the pusher can capture by selling into it is `d·V` (to leading order). BOTH legs of the round trip
present demand at the premium — the push itself carries a pump behind it (the bag is at its largest
then) and every slice of the dump carries another — so with the pump a share `s` of each leg the
pumps hand back at most `s·d·(X + X)` for a push of `X`, against fees `2·f·X`. The round trip pays
only if `2·s·d > 2·f`, i.e. `s·d > f`. The gate therefore sets

```
    s(d) = min(s_max, f / d),   s_max = PUMP_SHARE_MAX_WAD = 60%
```

which is break-even at best before the haircut and a loss after it, at EVERY premium. (An earlier
draft of this design set `2·f/d`, counting the dump alone; with the bucket's volume credit letting
each leg summon its own pump, `M1` then showed an 8 ETH push turning ETH-positive by a sliver. The
suite caught it; `f/d` closes it with the same 20% margin the haircut gives everywhere else.)
Below the reference (`d ≤ 0`) there is no premium to sell into and the share is `s_max`. The premium
is read from whole ticks on the strict side (the reference rounded so the gap never under-states),
so the share is never a hair too generous. At a 0.3% fee the full share holds up to a 0.5% premium
and halves for every doubling beyond: 15% at 2%, 3% at 10%, 0.4% at 69%.

**Why the reference cannot be moved for free.** The reference is a time-weighted average of the
pool's tick: an observation `dt` after the last moves it `min(1, dt/τ)` of the way toward the tick
that STOOD since the last observation — the tick the PREVIOUS swap left, never the current one, and
read before the pump behind that swap lifted main further. A swap in the same block as the last
one (`dt == 0`) moves nothing. So nothing a transaction does to spot inside its own block enters
the reference, and the pot's own buying never ratchets it: moving the reference means holding a
price against the whole market across block boundaries for minutes, exposed to every arbitrageur
and seller the whole time. `τ = REFERENCE_TAU = 10 minutes`.

**The rise cap.** The reference may FALL freely — a dip reopens the gate at once, so the pot buys
every dip at full size — but may RISE (main getting dearer) at most `REFERENCE_MAX_RISE_PER_MINUTE
= 296` ticks (≈3%) per minute, whatever stood. For pushes under ~34% (`296·τ/60` ticks) the time
constant is the slower of the two and nothing changes; above it the cap governs, and believing a
`+d` push takes `d / 3%` minutes of a HELD price: a +69% push (a 30 ETH buy on a 100 ETH-deep pool)
reopens the gate after twenty minutes instead of ten, a ×4 spike after forty-seven. This is the
answer to the two residuals a time-weighted reference alone leaves: on a single-venue token there
is no arbitrageur to punish a held price, and a sequencer or validator who controls consecutive
blocks can hold one at zero market risk — either now pays in minutes (blocks) proportional to the
move they want the pot to believe, and the pot spends almost nothing on their touches in the
meantime (`A14`: fifty blocks of holding a +69% push cost the pot under 0.001 ETH of a 100 ETH pot).

**Discharge.** `test_A3_spotManipulationLoses` (a 30 ETH push, a sliced dump, an unwind: token-flat,
ETH-negative, the pot out under 1%), `test_M1_manipulateDumpUnwindLosesAtEverySize` (the same at
0.5, 2, 8, 30 and 90 ETH, the gate's share checked against `f/d` at each, the pot out at most four
haircut ceilings), `test_M4_shareTable` (the share equals `min(60%, f/d)` to within 0.01% across
seven premiums from 0.15% to 300%), `testFuzz_FM4_gateShareSane` (512 runs across random premiums:
bounded, monotone, `≤ f/d`), `test_M3b`/`test_M3c` (same-block pushes never move the reference;
standing time moves it linearly on a fall), `test_M10` (premium and rise cap read the right way
round when main is `currency0`), `test_M11a`/`test_M11b`/`test_M11c` (a held +69% opens at the cap
not at τ; a held ×4 needs 47 minutes; a fall is never capped), `testFuzz_FM14_riseBound` (between
any two observations the reference rises at most `296·dt/60` ticks and never past the tick that
stood), `test_A14_blockControllerHoldingPriceStaysGated`, and on mixed decimals `test_D7` and
`testFuzz_D10` (the gate reads ticks only: the same human push gives the same share on a 6/18 and
an 18/8 pool, under every (6|8|18)² decimals pair and either key orientation).

### 4.3 The pump cannot be sandwiched on its own — `V ≤ f·R`

**Claim.** An attacker whose own buy triggers a pump and who then dumps the acquired bag cannot
profit, for any attacker size, pot depth or price.

**Derivation.** Model a constant-product pool of depth `R` (the tangent reserve at the live price on
the side the pot spends) with fee `f`. An attacker opens with a buy of size `X` and closes by selling
the same bag, and a pump of size `V` lands between the two legs (this is the sandwich shape — the
pump is the "victim" the attacker brackets). To leading order the gross price-impact profit of the
bracket is

```
    profit ≈ 2·X·V / R
```

and the attacker pays fees `f·X` on the way in and `f·X`-worth on the way out, so `fees ≈ 2·f·X`.
The bracket is profitable iff `profit > fees`, i.e.

```
    2·X·V / R  >  2·f·X    ⟺    V > f·R
```

The attacker's own size `X` cancels: a single bound on the pump's spend closes the attack at every
attacker size simultaneously. The hook therefore caps the pump at `f·R` — computed live as
`swapFee(protocolFee, lpFee, direction)` times `tangentReserve(sqrtPrice, liquidity, side)`, so a
deeper pool or a fatter fee tier earns a proportionally larger pump and nothing is hardcoded — and
then applies a further `PUMP_HAIRCUT_BPS = 80%` factor, putting the realised spend at `0.8·f·R`,
strictly *inside* the break-even.

**Discharge.** `test_A2_pumpNotSelfSandwichable` — the attacker's own buy carries the pump and the
attacker immediately dumps; the round trip loses to fees at every size from 0.05 to 40 ETH.
`test_A6_zeroFeePoolNeverPumps` — with `f = 0` the ceiling `f·R` is zero, so the pump never fires:
a zero-fee pool cannot host an unsandwichable buyback and the design refuses to try.

> **Scope note.** This bound governs ONE pump. What a thousand pumps in a block can do for a holder
> is the subject of §4.4; what a third party sandwiching an *unrelated* buy gains is written up,
> with its full two-sided accounting, as finding **GH-1** below.

### 4.4 The spend bucket paces the pot to what the pool earns — `k·f` per unit of volume, plus a slow floor

**Claim.** Over any window the pot spends at most

```
    k · f · Σ demand  +  f·R · (1 + window / PUMP_REFILL),    k = PUMP_FEE_LEVERAGE = 4,  PUMP_REFILL = 30 min
```

— `k` times the LP fees the flow through the pool earned, plus one ceiling per half hour of time,
plus the one ceiling the bucket may have started with — regardless of how many swaps arrive or who
sends them.

**Why it is needed.** The fee ceiling and the gate bound a pump at a fair price; neither bounds the
RATE. At or below the reference a holder of a large bag could manufacture volume — cheap round
trips, each leg summoning a pump of up to 48% of its size for a 0.3% fee — and compress the pot's
entire future spend into one block they alone are positioned for. The pot's money would go where it
always goes (into buying and burning main), but all at once, into one holder's exit.

**Why volume, not time.** A purely time-based bucket (one ceiling a minute, the first draft) makes
the pot's pace independent of whether anyone is trading — which is exactly what a patient farmer
wants: in a quiet market they alone supply the volume and collect the pace. Tying the credit to the
fee each swap pays makes manufactured volume unlock only `k ×` what it cost. A farmer with a bag `B`
on depth `R` running round trips of volume `v` pays `2·f·v` and the pot spends at most
`0.8·k·f·2v` on their pumps, of which the bag is lifted by `2·B/R` — so the farm pays only if
`B/R > 1/(1.6·k) ≈ 15.6%`, and even then captures at most `2·B/R` of what the pot spends, holding the
bag the whole time. Below that a farmer loses; with no bag at all (`A13`) they recover under a tenth
of their fees. In a live market the pot's pace follows the market: `4 × 0.3% = 1.2%` of the volume
that goes through the pool, capped at one ceiling per pump — a hot pool is bought hard, a dead one
barely (the floor: one ceiling per half hour), and a single sell of `R/k` (25% of depth) fills
the bucket on its own so a real dump is always bought at full size however busy the block has been.

**Mechanism.** A token bucket encoded in ONE timestamp packed with `main` in the pot record. The
level is kept as the seconds of time-refill it is worth (full at `PUMP_REFILL`): the pump reads
`level = min(PUMP_REFILL, now − ts)`, adds the swap's credit `k·demand·PUMP_REFILL/R` seconds
(`k·f·demand` of the ceiling), clamps at full, spends at most `feeCap·level/PUMP_REFILL`, and
writes back the timestamp that encodes what is left. The credit lands whether or not a pump follows
(a gated or dust swap still credits; a reverted pump keeps the credit and not the spend). A fresh
pot reads as full, and `quotePump` mirrors the sizing, the demand's own credit included.

**What it leaves.** A large holder can still sell into the pot's buying — that is what a buyback IS
for its holders — but only at `k ×` the pool's earnings, holding the bag the whole time and lifted
no more than every other holder. Measured (`M6a–c`, a 100 ETH-deep pool, the reference settled on
the bag's price, thirty 1 ETH round trips a minute apart, nobody else trading): a 4% bag LOSES
(−0.075 ETH); a 20% bag nets ~0.21 ETH while the pot spends ~1.4 ETH; a 25% bag nets ~0.28 ETH of
~1.4 ETH the pot spent — every figure under the bound and strictly less than the pot spent. In one
block (`M7g`) a 4% bag manufacturing twenty round trips loses ~0.065 ETH while the pot spends the
opening bucket plus `k·f` of the volume. `k` is the tunable: it was set at 4 (from an earlier 8)
to put the bag threshold at a sixth of the pool rather than a thirteenth, at the price of half the
pace in a hot market; `PUMP_REFILL` sets the dead-market floor.

**Discharge.** `test_M7a_bucketBoundedInsideBlock` (eight in-block pumps: the first 80% of the
ceiling, each within 80% of its level, the sum at most the ceiling plus the credits earned),
`test_M7b_bucketRefillsLinearly`, `test_M7c_paceIsLeveragedFees` (fifty 2 ETH round trips over ten
minutes spend within a few percent of `k·f·volume + floor`), `test_M7d_dustPumpLeavesBucketFull`,
`test_M7e_quoteMirrorsBucket`, `test_M7f_bigSellFillsBucketAlone`,
`test_M7g_quietMarketManufacturingLoses`, `test_M6a_patientBagFarmBoundedByPace`,
`test_M6b_bagUnderThresholdLoses`, `test_M6c_bagOverThresholdGainsLessThanPotSpent`,
`test_A13_baglessManufacturingPaysTheAttackerNothing`, `testFuzz_FM13_paceBound` (512 fuzzed
trade-and-wait sequences, the bound above never exceeded), `testFuzz_FM15_creditExact` (from a
drained bucket a dip of demand `D` pumps `0.8·min(f·R, left + k·f·D, 60%·D)`), and in raw
mixed-decimals units `test_D8_bucketCreditRaw8dec` and `test_D9_paceBoundRaw6dec`.

### 4.5 The pump is demand-following and pot-bounded

**Claim.** `spend ≤ 0.8·min(pot, f·R, bucket, s(d)·demand)`, where `demand` is the secondary the
carrying swap actually moved — paid on a buy of main, received on a sell — read from the swap delta,
not quoted.

**Why.** `_pumpSize` takes `min(pot, budget)` (the bucket never exceeds `f·R`), then
`min(…, s(d)·demand)`, then applies the haircut. So the pump never exceeds the pot, never exceeds
the fee ceiling or the bucket, and never spends more than the gated share of the swap in front of
it — a dust trade unlocks only a dust pump, and the pot tracks real demand instead of emptying all
at once. `demand` is the *measured* secondary leg of the delta rather than a re-quote of the other
side, because re-quoting a pot-sized swap divides by an average (not marginal) execution price and
would read a fat pot's own impact as extra demand.

**Discharge.** `testFuzz_FM1_pumpSpendBounds` and `testFuzz_FM2_pumpMonotoneInBuy` (512 runs each),
`testFuzz_FM5_livePumpWithinQuote`, `test_U14_dustSellCarriesNoPump`, and invariant **PP4** (no
pump ever spent more than 48% of the secondary the carrying swap moved).

### 4.6 The pump can never revert a swap

**Claim.** No pool state, pot state, timestamp or tick can make `afterSwap` revert the carrying
swap.

**Why.** The pump's own swap runs in a `try/catch` self-call; a failure rolls back the pump alone.
Everything before it is bounded arithmetic: the reference step is a convex combination of two
in-range ticks in `int256` (`unchecked`, wrapping `uint32` clocks), the gate clamps its gap to the
tick range before the sqrt-ratio port, the bucket's division is by a constant, and every ceiling
returns zero rather than throwing when a pool has no depth, no fee, or no pool-exact quote.

**Discharge.** `testFuzz_M8a_neverReverts` (512 runs of twelve random trades and waits from zero to
three time constants, with a ten-year jump), `test_M8b_extremeTickPoolSurvives` (a pot on a pool
initialised at tick 887,000 trades both ways), `test_A10_pumpFailureNeverBreaksTheBuy`,
`testFuzz_FM6_quotesArePure`.

### 4.7 Conservation and delivery identity

**Claim (secondary conservation).** `pot + Σ pump spends == Σ donations (+ Σ harvest fuel)`, exactly.
Every wei that ever entered a pot is either still there or was spent by a pump that logged it.

**Claim (delivery identity).** `Σ main acquired == Σ main delivered` — sent to a recipient, burned
through the Glue unglue, held forever, or parked. Nothing the two mechanics acquire evaporates or
sits unowned.

**Claim (solvency).** The hook's balance of any asset is always `≥ obligationOf(asset)` = every pot
denominated in it, plus everything parked in it, plus everything held forever in it, plus the owed
backlog booked in it, plus every program's compound carry in it. There is no withdrawal path for
any of them beyond the named creditor's own.

**Discharge.** Invariants **PP1** (solvency), **PP2** (conservation), **PP5** (main attributed),
**PP6** (delivery identity), each over 384 runs × 64 calls with zero reverts, ghost-ledgered from the
hook's own events (not inferred from balances). `testFuzz_FM6_quotesArePure` confirms the view
functions never mutate a pot. `test_L12_solvencyAcrossTheDance` closes the same solvency claim over
a full LP-program lifecycle (entries, trades, harvests, refusals, a removal).

### 4.8 The harvest split is exactly conservative

**Claim.** For a harvest of `fMain` main-side and `fSec` secondary-side fees under a config
`(compoundShareWad, buybackShareWad, burnShareWad)` — where `compound + buyback ≤ 1e18` and
`compound + burn ≤ 1e18`, enforced at set-time — every leg is the floor of its WAD product against
the GROSS of its side:

```
    cMain  = ⌊fMain · compoundShareWad / 1e18⌋,  cSec = ⌊fSec · compoundShareWad / 1e18⌋
    fueled = ⌊fSec · buybackShareWad / 1e18⌋     → credited to the pool's own pot
    burned = ⌊fMain · burnShareWad / 1e18⌋       → the Glue burn
    secondaryRecipient receives fSec − cSec − fueled   (exactly — division dust lands here)
    mainRecipient      receives fMain − cMain − burned (exactly)
```

and the compound mints against its budget PLUS the standing carry, returning the unplaced rest to
the carry:

```
    budgetMain = cMain + carryMain,  budgetSec = cSec + carrySecondary
    (uMain, uSec) = what the mint ACTUALLY consumed (0 on any mint failure)
    uMain ≤ budgetMain and uSec ≤ budgetSec       (hard budget check — QuoteMismatch otherwise)
    carryMain' = budgetMain − uMain,  carrySecondary' = budgetSec − uSec
```

The legs plus the mint's real consumption plus the carry delta sum to the harvest byte-for-byte on
both sides, so no wei is minted or lost by the split, the WAD floor's dust is absorbed by the
recipient leg, and the carry never leaks to the pot or a recipient — it only ever converts into
position liquidity. The carry is a per-asset term of `obligationOf`, so custody covers it at all
times, and a config edit only shapes future harvests (nothing already split or carried is
re-touched).

**Why.** The engine books each leg from a single subtraction against the collected total before any
external send (CEI); the carry is updated from the mint's REAL settlement deltas, not re-derived
from a second multiplication; the send phase pays from already-final books, and a bounced push
converts its leg into an owed booking of the identical amount instead of re-deriving anything. The
mint itself runs in an isolated external frame (`try/catch`): a revert consumes nothing, so the
whole budget stays in the carry and the harvest never blocks on the compound.

**Discharge.** `test_L5_manualHarvestExactSplit` (exact equalities per leg against the `Harvested`
event), `test_L13_compoundExactSplit` (the flat gross-referenced identity above, carry included),
`test_L14_compoundInSwap` (the in-swap mint), `test_L15_fullCompound` (the 100%-compound corner:
nobody else sees a wei; the unplaced budget waits whole in the carry),
`test_L16_compoundValidation` (the per-side sum bound and the exact-100% recipient-less corner),
`test_L17_compoundSolvencyDance` (solvency held across compounding interleaved with everything
else), `test_L23_compoundGrowsAcrossRounds` (five auto-harvest rounds: liquidity monotone,
compounds stack, solvency every round), `test_L24_carryAccumulatesAndRetries` (a skewed round's
unplaced budget joins the next harvest's mint and is drawn down by exactly its arithmetic),
`test_L25_oneSidedFeesCompound` (fees skewed entirely to one side never revert the harvest; the
anchored mint stays within both budgets or abandons cleanly), `test_L11_surrenderedAtBirth` (the
100%/100% corner with both roles zeroed), `test_L9_owedBacklogAndClaim` (a bounced
leg books at the identical amount, folds into the next push, and is claimable),
`test_A11_reentrantHarvestRecipientBooked` (a re-entering recipient cannot double-dip),
`test_L26_zeroFeeHarvestRetriesCarry` (a harvest with NO fresh fees still retries a standing carry
and touches no other ledger), `test_L27_carrySurvivesConfigEdit` (a share edit never releases or
re-routes what was already carried — the earmark keeps retrying under the new rules). Fuzzed:
`testFuzz_FM7` (split conservation over arbitrary share pairs), `testFuzz_FM8` (compound within
budget over every legal triple, conservation carry-inclusive), `testFuzz_FM11` (an armed program's
liquidity NEVER decreases through any trade — the auto-compound can only grow the position, with
custody solvent after every swap), `testFuzz_FM12` (global carry conservation: over a whole
sequence of harvests, Σ compound slices == Σ mint consumption + the final carry, per side to the
wei) — 512 runs each. Stateful: the program-armed campaign (§5, PI1–PI6) fuzzes the same ledgers
under random interleavings of harvests, compounds and pumps behind both directions.

### 4.9 The native report is exactly-once and cannot touch a delivery

**Claim.** For a native program, at every point in time and for each pool currency `a`,

```
    deliveredCum[pool][a]  ==  Σ over harvest frames of (what the engine's push in `a` LANDED)
                           ==  the engine's cumulative balance delta in `a` from harvest pushes
```

and the callback carries exactly the frame's two terms, so an engine that attributes from the
callback and credits `deliveredCum − cursor` at its next own harvest (advancing the cursor on both
paths) attributes every unit ONCE: the two paths partition the ledger's increments by whether the
callback landed. Nothing the engine does in the callback can change what the frame delivered: the
report is the LAST action of `place`, after the pot delivery, the burn cascade, the compound
credit and both recipient pushes, and it is a raw call whose failure only flips the event flag.

**Proof.** `_payRecipient` returns `amount + backlog` on a successful `_pushRaw` and `0` on a
booked refusal — by construction the wei that moved onto the recipient this frame, since the
backlog was booked (not moved) earlier and is now cleared only because it moved. `_recordHarvest`
adds exactly those two returns to the ledger before the call, in the same frame, so the ledger's
increment IS the frame's landed amount; the callback's arguments are the same two locals. The
engine receives value from the hook ONLY through those pushes (the pot delivers to the pot's
recipient, the burn to Glue, principal to the `to` of a remove), so Σ landed == the balance delta
from harvest pushes. Ordering: `place` runs `_deliver` → `_burn` → the two `_payRecipient` →
`_recordHarvest`, and every entry that reaches `place` holds the transient guard, so a re-entrant
`harvest`/`claim`/`afterSwap` from the callback reverts `Reentrancy` inside the engine's frame; a
PoolManager re-entry is impossible (the manager is locked in the swap case and the hook opens no
unlock in the manual case after `place`). The callback runs at the carrying call's gas — NO
stipend, on purpose. The callee is a Glue-registered engine pinned at pool creation, so its cost is
the engine's own; a fixed number baked into this immutable hook would drift with every engine
upgrade (the first build's 300k was outgrown by the engine's in-callback program route) and with
every chain gas repricing (the `transfer()`-2300 lesson of EIP-1884), and unused gas is refunded
either way. What an adversarial engine can do with the gas is bounded by the guard, not by gas: it
cannot bubble a revert (`call`, not `try` on a typed interface — no return-data decode), cannot
re-enter a value-moving entry, and cannot move a delivery (all sends precede the report). What it
CAN do is burn the gas it was given: the frame then finishes iff the 1/64 the EVM keeps covers the
tail, so a broken engine can fail swaps on ITS OWN program's pool — the standing Uniswap gives a
hook that breaks — and nothing else (N10). The same holds for the recipient pushes (`_sendEth`
forwards gas): a recipient that burns gas fails the swap on the pool whose program named it, a
recipient that refuses is booked and pulls via the full-gas `claim` (QS7, QS8). A non-native
program never reaches `_recordHarvest` (`g.native` gate), and the ledger for it is identically
zero.

**Discharge.** `test_N7_manualHarvestExactReport` (exact legs, `msg.sender == hook`, ledger ==
landed, event flag true, an empty frame silent), `test_N8_owedLegReportsWhenItLands` (a refused
leg reports zero and the ledger stands; the folding frame reports `push + backlog` and the ledger
moves by exactly that), `test_N9_revertingEngineNeverBubbles` (flag false, ledger advanced, money
landed, carrying swap settled), `test_N10_gasBurningEngineIsChargedNotBounded` (a burner is charged the
call's gas — over half a 30M budget — and the frame finishes; under a budget an honest engine fits
in twice the harvest fails out of gas with no ledger moved; the next honest harvest lands),
`test_N11_reenteringEngineRejected` (`Reentrancy` from a manual harvest and from inside a swap, the
swap succeeds), `test_N12_autoHarvestReportsInSwap`, `test_N13_harvestFirstInAddAndRemoveReports`
(every harvest path reports; principal never pollutes), `test_N15_exactlyOnceAcrossFailures` (six
frames of mixed succeeding / failing callbacks: ledger == landed at every step and
`ledger − recorded` == the failed frames' legs exactly), `test_N16_reportCarriesRemainderOnly` (a
pump, a fuel leg and a burn leg in the same frame; the report carries the remainder only).
Stateful: `GlueHookNativeProgramInvariant` (§5, PN1–PN4) fuzzes the armed walk over a native
program — ledger == balance delta on both assets, recorded == ledger, monotonic, solvent. On a
live chain: `test_FK6_nativeLaunchAgainstTheRealStick` asks the REAL Stick.

---

## 5. Invariants (stateful campaigns)

Three campaigns drive the real hook against the real PoolManager on a real hooked pool, interleaving
donations, buys, sells (exact-input and exact-output) and time skips (up to three reference time
constants, so the reference and the bucket both move) from five actors in arbitrary order.
`foundry.toml` runs each at **384 runs × depth 64**.

**`test/GlueHookInvariant.t.sol`** — the bare pool (no LP program), isolating the pump:

| ID | Property | Result |
|----|----------|--------|
| PP1 | Pot solvency: `held ≥ owed` in the secondary | ✅ 0 reverts |
| PP2 | Secondary conservation: `pot + spends == donations + fuel` | ✅ 0 reverts |
| PP3 | A pump behind a sell never lifts main past where the sell started | ✅ 0 reverts |
| PP4 | No pump spends more than 48% of the secondary the carrying swap moved | ✅ 0 reverts |
| PP5 | Every unit of main the hook holds is accounted (== parked + held) | ✅ 0 reverts |
| PP6 | Delivery identity: `main acquired == main delivered` | ✅ 0 reverts |

**`test/GlueHookProgramInvariant.t.sol`** — the SAME random walk with the LP program LIVE and armed
for in-swap auto-harvest with every split leg on at once (40% compound + carry, 30% buyback fuel,
30% burn, the buyback split at 25% compound + 25% burn, live recipients pushed real money inside
the swaps). Harvests, compounds and pumps behind both directions all settle in the same frames, which is exactly
where a bookkeeping slip between the four ledgers (pot, carry, owed, parked/held) would hide:

| ID | Property | Result |
|----|----------|--------|
| PI1 | ETH solvency: balance ≥ `obligationOf(ETH)` (pot + carry + owed) | ✅ 0 reverts |
| PI2 | Token solvency: balance ≥ `obligationOf(token)` | ✅ 0 reverts |
| PI3 | Main attributed exactly: balance == parked + held + carry + owed | ✅ 0 reverts |
| PI4 | Pot conservation with harvest fuel as a real inflow | ✅ 0 reverts |
| PI5 | Delivery identity incl. harvest burn legs and the buyback split's `COMPOUNDED` carry credits | ✅ 0 reverts |
| PI6 | Program liquidity NEVER decreases (nobody removes; compound only grows) | ✅ 0 reverts |

**`test/GlueHookProgramInvariant.t.sol` — `GlueHookNativeProgramInvariant`** — the same armed walk
over a NATIVE program: launched by a registered (mock) engine that records every `recordHarvest`,
so every in-swap harvest pushes the remainder legs to the engine, advances the delivered ledger and
reports. The engine receives nothing else in this world, which makes the ledger's exactly-once
claim directly checkable against balances:

| ID | Property | Result |
|----|----------|--------|
| PN1 | Ledger == landed: `deliveredCumOf(pool, a)` == the engine's cumulative balance delta in `a`, both assets, to the wei | ✅ 0 reverts |
| PN2 | Recorded == ledger: the engine's `recordHarvest` sums equal the ledger (a reconcile credits zero) | ✅ 0 reverts |
| PN3 | The ledger never decreases between two observations | ✅ 0 reverts |
| PN4 | Solvency under native load (ETH and token) | ✅ 0 reverts |

Five deterministic anti-vacuity walks prove the campaigns trade a non-empty world: actions land and
pumps fire behind buys AND sells (`test_coverage_handlerActionsLand`); a thin pot spends its haircut
share (`test_coverage_thinPotSpendsItsHaircutShare`); an unfunded pot is completely invisible
(`test_coverage_emptyPotIsInvisible`); and under the armed program, harvests, compounds, fuel, burn
legs, recipient pushes and the buyback split's compound leg all actually fire inside the fuzzed
swaps (`test_coverage_programMechanismsLand`); and under the native program every fuzzed harvest
reported exactly once with real value on both sides (`test_coverage_nativeReportsLand`).

---

## 6. Test inventory

`forge clean && forge test` — **191 tests, 0 failures** (197 with `FORK_RPC_URL` set: the live-chain
fork suite self-skips offline).

| Suite | File | Count | What it proves |
|---|---|---:|---|
| Invariant | `GlueHookInvariant.t.sol` | 9 | PP1–PP6 + 3 anti-vacuity walks (bare pool, with time skips in the walk) |
| Program invariant | `GlueHookProgramInvariant.t.sol` | 7 | PI1–PI6 + 1 anti-vacuity walk: the same random walk with the LP program live and every split leg armed — solvency, exact main attribution, pot conservation with harvest fuel, delivery identity, monotone liquidity |
| Native program invariant | `GlueHookProgramInvariant.t.sol` (`GlueHookNativeProgramInvariant`) | 5 | PN1–PN4 + 1 anti-vacuity walk: the armed walk over a NATIVE program owned by a registered recording engine — the delivered ledger equals the engine's balance delta on both assets to the wei, the engine's recorded sums equal the ledger, the ledger never decreases, solvency |
| Native programs | `GlueHookNative.t.sol` | 16 | N1–N16: the stamp through `launchPool` / `addLiquidityAdvanced` / `addLiquidity` with passed owner and recipients ignored; a stranger's and an un-registered engine's program plain (no report, ledger zero, transferable); a codeless / reverting / short-answering / garbage-answering Stick never blocking creation (control: the truthful Stick stamps); ownership pinned — no transfer, no surrender — while shares, gate, mins and the operator seat stay editable and a moved recipient is `BadConfig`; the manual harvest's exact report (`msg.sender == hook`, exact `(poolId, dMain, dSec)`, ledger == landed, `HarvestRecorded(..., true)`, an empty frame silent); the owed leg reporting zero then `push + backlog`; a reverting engine flagged false with the ledger advancing, the money landed and the carrying swap untouched; a gas-burning engine charged the call's gas, never bounded (a 30M budget finishes the frame with the burn on the caller's bill, a tight one fails the harvest on the engine's own program only, the next honest harvest lands); a re-entering engine thrown out by the guard with `Reentrancy` from a manual harvest and from inside a swap; the in-swap report behind a buy and behind a sell, never when disarmed; the harvest-first report inside add and remove with principal kept out; `native` at byte 25 of slot 0 with `owner` opening slot 1 via `vm.load`; exactly-once across six frames of mixed succeeding / failing callbacks; the report carrying the remainder only alongside a pump, a fuel leg and a burn leg |
| Unit | `GlueHookUnit.t.sol` | 14 | U1–U14: deploy gate, callback auth, admin capture, initPot/setRecipient validation, native + ERC20 + FoT donations, the pump behind a buy and behind a sell, a thin pot, recipient delivery, views/quotes (incl. `pumpShareOf`), a dust sell carrying no pump |
| Adversarial | `GlueHookAdversarial.t.sol` | 14 | A1–A14: seller parity against the hookless twin, self-sandwich unprofitability, manipulate–dump–unwind losing, hostile recipient park, reentrant donate, zero-fee refusal, 100% FoT refusal, the pump behind both directions, pot isolation, pump-failure isolation, reentrant harvest recipient, sandwiching a stranger's credited full pump losing at four sizes (the pump runs inside the victim's transaction, so the front-run must eat the victim's dump), bag-less volume manufacturing recovering under a tenth of its fees, a block-controller holding a +69% push for fifty blocks still gated under 2% with the pot out under 0.001 ETH |
| MEV | `GlueHookMev.t.sol` | 25 | M1–M11: manipulate–dump–unwind losing at five push sizes with the gate's share checked against `f/d` and the pot out at most four haircut ceilings; a pre-positioned bag farmed inside a block losing (sixty pumps handing back at most the haircut of `f` per unit of volume); the reference's mechanics — seeded at init, deaf inside a block, linear in standing time on a fall, re-seeded when a donation funds an empty pot, asleep while empty; the share table `min(60%, f/d)` to the tick across seven premiums; a dip at full share whatever the history; the pace bound on a PATIENT bag holder (pot spend ≤ `k·f·volume + floor + opening bucket`; a 4% bag loses; a 25% bag gains strictly less than the pot spent and at most `2·bag/depth` of it); the bucket — bounded inside a block by the ceiling plus the credits, linear time refill, `k·f·volume` pace over fifty trades in ten minutes, a `depth/k` sell refilling it alone, dust immunity, quote parity credit included, quiet-market manufacturing losing; revert-freeness under 512 fuzzed trade-and-wait sequences and on a pool at tick 887,000; the reference and bucket per pool; gate AND rise-cap orientation with main as `currency0`; the rise cap — a held +69% opens at 296 ticks a minute not at τ, a held ×4 needs 47 minutes, a fall is never capped |
| Glue burn | `GlueHookBurn.t.sol` | 15 | B1–B13 (+2): the pure `unglue` on the main's OWN GlueWrapper with an exact allowance consumed whole (the GlueStick's `unglue` provably out of the path), the held-forever terminal for a refused unglue, the unburnable flag's permanent short-circuit, per-asset flag isolation, `flushDirect` retries, the glueable-main gate (network token and NATIVEWRAP rejected on `initPot` AND `launchPool`), the creation-time classification (fresh main glued, glued main skipped, wrapper main never ensured), an NFT-mode and an ERC20-mode GlueWrapper main PARKING on themselves (`parkedShares` grows by exactly the burn, supply untouched, nothing held, no unglue), the harvest's and the pot's burn legs parking in ONE walk from a `launchPool`-created program, lazy glue (a main the Stick refused at declaration is glued at its first burn; one it keeps refusing is flagged and never probed again), wrapper/plain mains isolated across pools |
| LP program | `GlueHookLiquidity.t.sol` | 17 | L1–L12 + L18–L22: normal/advanced entries, full-range sentinel, creation gates, config validation (incl. the native-main rejection at declaration and the per-side share-sum bound), exact gross-referenced harvest split, auto-harvest mins, harvest-first adds, removes, owed backlog + claim, the operator-zero config freeze, surrendered-at-birth, lifecycle solvency, the owner-only harvest gate + `publicHarvest`, owner/operator separation, ownership transfer + surrender, a timelock locker owning a program, frozen rules travelling across a transfer |
| Compound + carry | `GlueHookCompound.t.sol` | 10 | L13–L17 + L23–L27: compound exact split + conservation, in-swap compound, 100% compound (the carry holds everything), share-sum validation + the exact-100% recipient-less corner, compound solvency dance, multi-round compound growth, carry accumulation + retry drawn down wei-for-wei, one-sided-fee compound skew, zero-fee harvest retrying a standing carry, the carry surviving a config edit |
| One-tx launch | `GlueHookLaunch.t.sol` | 10 | LA1–LA10: the single-transaction `launchPool` — happy path (launcher becomes admin, pool at the requested price, program owned/configured/seeded, native excess refunded to the wei, `PotOpened` carries the LAUNCHER not the hook), ERC20/ERC20 launch from allowances (+ value-on-tokenless-pool rejection), foreign-hook key rejection, existing-pool rejection, bad-main atomic rollback (no pool, no pot left behind), native-main rejection, config legality + zero-seed rejection, the hook-initialised-outside-launch pool staying inert (no admin spoof), a launched pool fully operational (donate → pumps behind a buy and a sell → manual harvest), and surrendered-at-birth through the launch path |
| Gas | `GlueHookGas.t.sol` | 6 | G1–G5 + G2b: deterministic `gasleft()` measurements behind generous regression ceilings — the one-tx launch vs the three-step path, swap overhead per circumstance (hookless baseline, hooked idle, pump behind a buy, pump behind a sell), the armed bit (a disarmed program costs a swap one slot read; the batched pending-fee scan is the armed cost), the in-swap auto-harvest + merged compound mint, the steady-state entries (donate, manual harvest, add, remove), and the native report's marginal cost on a manual and an in-swap harvest against a plain twin. Source of the numbers in §11 |
| Mixed decimals | `GlueHookDecimals.t.sol` | 10 | D1–D10: ERC20/ERC20 pools launched at a HUMAN 1:1 price so the raw sqrtPrice carries the whole decimals gap (6/18 and 8/18 pairs, roles both ways) — a 100-unit buy delivers ~100 units in the OTHER side's own raw scale, the pump fires behind both directions and delivers in correct raw units, the WAD harvest split is exactly conservative over 6-dec raw fee amounts, the compound mints real liquidity from mixed-scale fees, the pot ledger stays fully backed after a trading burst; the gate is decimals-blind (the same human push reads the same `min(60%, f/d)` share on a 6/18 and an 18/8 pool, and under 512 fuzzed (6\|8\|18)² pairs on either side of the key), the bucket's ceiling and volume credit are exact in 8-dec raw, the pace bound holds in 6-dec raw. V4 and the hook never read `decimals()`; this suite proves the raw-units model end to end |
| Formal (fuzz) | `GlueHookFormal.t.sol` | 15 | FM1–FM15: pump spend bounds (pot, fee ceiling, gated share), pump monotonicity in demand, seller parity against the hookless twin (and no overshoot), the gate's share sane at every premium (`≤ f/d`), live-pump within quote, quote purity, exact split conservation over arbitrary share pairs, compound-within-budget + carry-inclusive conservation over every legal (compound, buyback, burn) triple, owed-ledger exactness through refusal and claim, self-sandwich accounting (the attacker loses ETH, every spend converts into bought main, the pump capped by the gated share of the attacker's own trade), auto-compound monotone growth, global carry conservation across whole harvest sequences, the pace bound over fuzzed trade-and-wait sequences (`spend ≤ k·f·Σdemand + f·R·(1 + elapsed/PUMP_REFILL)`), the rise bound between any two observations (never past the standing tick either way), the volume credit exact from a drained bucket — 512 runs each |
| Buyback split | `GlueHookPotSplit.t.sol` | 14 | SP1–SP10 + NS1–NS4: zero-default parity with the unsplit delivery, the wei-exact three-way carve on the pump's output behind a buy AND behind a sell, the burn-intent single-cascade merge, no-program neutrality, set-time validation (sum bound, native-main rejection at declaration, exact-100% legality), operator gating + the operator-zero freeze, plain-`addLiquidity` defaults (owner == operator, split off, burns whole on a burn-intent pot), the remove-all-liquidity carry cycle closed with the exact identity `carry' = carry + slice − minted`, the 100%-compound corner — and the never-stop matrix: a refusing recipient parks the rest while the other legs settle, a main that blocks the GlueStick's pull holds forever under a burn share, a main Glue refuses to admit is held (and its refused ensure never blocks creation), and a re-entering harvest recipient bounces off the transient guard with the delivery landing |
| Dynamic-fee rejection | `GlueHookDynamicFee.t.sol` | 4 | DR1–DR4: a key carrying the `0x800000` sentinel is refused on BOTH creation doors — `beforeInitialize` for a direct `PoolManager.initialize` and `launchPool` itself (the PoolManager skips the callback when the hook is the caller) — with nothing half-made left behind (no pool, no pot, value untouched); a static twin of the same shape is untouched, and same-pair pools at adjacent static fees (3000 vs 3001) coexist independently — the fee field as a creation namespace |
| Live-chain fork | `GlueHookFork.t.sol` | 6 | FK1–FK6: the pump behind a buy, the pump behind a sell, manual harvest + compound, in-swap auto-harvest, the buyback split settling a live pump (compound carry + Glue burn + remainder to a live recipient, wei-exact) against the LIVE deployed PoolManager on a forked real chain — real code, real storage, real gas accounting — and a NATIVE launch against the REAL GlueStick at `0xdac0…`: the hook asking the live registry `isRegisteredEngine` about a registered engine's address (the GlueHook V0 pair's engine, `0xdb47…`, wearing a recording mock), the program stamped and pinned, the swap-carried harvest reporting to it (all verified on Ethereum mainnet `0x0000…8A90`); gated on `FORK_RPC_URL`, the engine overridable with `FORK_ENGINE` |

Test infrastructure (`test/helpers`, `test/mocks`, `test/fixtures`) is fixture-only: the PoolManager
is etched from its real runtime bytecode, the hook is deployed to an address carrying its real
permission bits, and the `GlueLiquidity` runtime is etched at the `foundry.toml` link sentinel —
the same delegatecall topology as production. The fork suite goes one step further and runs the
same topology against the LIVE PoolManager singleton on a forked real chain, with its real deployed
code and storage.

### 6.1 External layer — auditor-skill suites (49 tests, separate profile)

`test/external/` restates the campaign in the shape of four public audit firms' published skill
checklists. **This is not an official audit**: none of the firms reviewed, endorsed or signed the
suites; each is the hook's own integration of the firm's public methodology. The layer is skipped by
`forge test` and runs through `./scripts/run-external.sh` (`FOUNDRY_PROFILE=external`) on its own
fixture (`ExtBase.sol`: the main fixture plus a MAIN that rides the manager's unlock, a probing /
re-entering / gas-burning recipient, a probing / re-entering engine, weird ERC20s). Every row of every
check table carries a verdict — `ALREADY SAFE` (the main-suite twin named alongside carried the proof
first) or `NEW COVERAGE` (the only place that exact property is pinned) — in
[`audit/external/`](external/README.md). No firm check found a defect; the layer added coverage,
not fixes.

| Firm | Suite | Count | New coverage worth naming |
|---|---|---:|---|
| Trail of Bits | `Ext-TOB.t.sol` | 14 | zero/bounds refusals on every liquidity door (TOB8); USDT-class missing-return and Tether-Gold-class returns-false secondaries through SafeERC20 (TOB9, TOB10) |
| Pashov | `Ext-PSH.t.sol` | 13 | the transient PAYER window cannot be hijacked — a hostile MAIN summoning a pump from inside the seed pull is thrown out by the guard (PSH9); the admin-variant sandwich extracts nothing (PSH5); `uint128.max` liquidity reverts instead of truncating (PSH8) |
| QuillShield | `Ext-QS.t.sol` | 12 | the full guard matrix from a native engine's full-gas report — seven doors inside a swap and from a manual harvest (QS1); read-only reentrancy sees solvent books (QS2); a gas-burning recipient charged to the swap, never bounded — a generous budget lands the swap with the leg booked, a tight one fails the swap on its own pool only (QS7); force-feeding inert (QS10); under-gassed swaps never half-book (QS12) |
| Panther | `Ext-PAN.t.sol` | 10 | the floor is the pool's own quote minus 1e-6 (PAN1); the add settles V4's round-up formula to the wei (PAN2); the spend is exactly `floor(min(pot, f·R, 60%·demand)·80%)` (PAN5); the uint32 clock across 2^32 (PAN6); a failing pump still observes (PAN7); the pump sizes on the delta, never `amountSpecified` (PAN8) |

One finding surfaced and was fixed, in a library helper the hook never calls:
`GluedV4Core.getAmount0ForLiquidity` was ~1% low on a full-range position (it floored the
intermediate `L·2^96/sqrtUpper` — a two-digit integer at the max tick — before scaling it back). It
is now V4's own floor-form `getAmount0Delta` (`md512(L << 96, Δsqrt, sqrtUpper) / sqrtLower`).
Nothing on chain was affected — the helper is not in the deployed bytecode (sizes unchanged) — and
`PAN2` now asserts the helper is the floor form of the wei-exact settled amounts. The same two-step
implementation existed in the sibling `glue-v2-foundry` library where the engines DO call it (a display
leg and the default min-out floor on removal, looser never tighter); fixed there with the same form
and pinned by its `Glue-V4-LiquidityMath` suite. Recorded in
[`audit/external/README.md`](external/README.md).

---

## 7. Findings

### GH-1 — Informational: MEV surfaces around a swap-triggered buyback — and why every one of them fills the pot's order

**Severity:** Informational (economically bounded, inherent to buybacks that trade behind user flow,
not a pot drain).

**The frame that makes this finding legible.** The pot is not a treasury the hook defends — it is a
**standing buy order**. Its mandate is to convert its entire inventory into bought-and-burned main
at the pool's own execution price, as demand arrives. Every "attack" below is an attempt to get the
pot to trade; the question in each case is not *"did the attacker gain?"* but *"did the pot pay a
fair price for real main, at a pace real flow set?"* — and in every posture the answer is yes.

**Posture 1 — sandwiching the pump itself: CLOSED.** The attacker trades to summon the pump, then
dumps the bag to sell into the bump they financed. The fee ceiling `V ≤ f·R` makes this strictly
unprofitable: the recapturable price impact is haircut (`0.8·f·R`) below the double fee bill the
round trip pays. Proven at fixed sizes from dust to pool-scale (`test_A2_pumpNotSelfSandwichable`)
and refused structurally on zero-fee pools (`test_A6`).

**Posture 2 — pushing the price, then summoning pumps at the inflated price: CLOSED.** This was
the surface V2's shield had (it priced an internal fill at the pusher's spot). V3 has no internal
fill, and its pump is gated: a push of `d` above the reference shrinks every pump the pusher can
summon to `f/d` of the leg that summoned it — exactly the break-even before the haircut, with BOTH
legs of the round trip counted (§4.2). Nothing done inside the pusher's own block reaches the
reference, and a held price is believed at most 3% a minute, so the bigger the push the longer it
must be held — a single-venue token with no arbitrageur to punish the hold, or a validator holding
it across blocks, pays in minutes proportional to the move. Proven at push sizes from 0.5 to 90 ETH
(`test_M1`), as a sixty-pump farm inside one block (`test_M2`), against a sliced dump (`test_A3`),
against fifty blocks of a held +69% push (`test_A14`), across held pushes of +69% and ×4 (`M11`),
and in the fuzzed self-sandwich accounting (`testFuzz_FM10`: the attacker loses ETH, every wei the
pot spent became bought-and-burned main).

**Posture 3 — sandwiching an unrelated victim's swap: bounded uplift on a pre-existing attack.** Any
pump that lands behind a *separate* large trade makes that trade marginally more profitable to
sandwich, because the back-runner sells into a price lifted by both. The victim was sandwichable
with or without the hook — the pump does not create the opportunity, it adds a fraction bounded by
`0.8·f·R` to one that already existed. And the attacker cannot *summon* the pump for this: it only
rides behind the victim's genuine trade, capped by the gated share of the victim's own input (§4.5,
PP4).

**Posture 4 — the patient bag holder: PACED, and the residual stated.** A holder of a large bag
whose spot sits at or below the reference (bought slowly, or bought and then held for a reference
time constant against the whole market) faces an open gate. Each of their round trips summons a
pump of up to 48% of the leg for a 0.3% fee, and every pump lifts their bag. Without a rate bound
they would compress the pot's entire spend into one block they alone are positioned for. The spend
bucket (§4.4) paces the pot to `k = 4` times the fees the pool earns (plus a slow time floor), so
manufactured volume unlocks only `4×` what it cost: the farm pays only for a bag above ~16% of the
pool's depth, it captures at most `2·bag/depth` of what the pot spends, the bag is held the whole
time, every other holder is lifted alongside, and any seller is free to sell into the price the
farmer is holding up. Measured (`test_M6a–c`, 100 ETH pot, 100 ETH-deep pool, a round trip a minute
for thirty minutes in a world where nobody else trades): a 4% bag LOSES 0.075 ETH; a 20% bag nets
~0.21 ETH while the pot spends ~1.4 ETH buying and burning main; a 25% bag nets ~0.28 ETH of ~1.4
ETH. Read from the hook's side of the ledger:

- the pot paid the **pool's own price** for every token it bought — the mandate was executed, not
  subverted, and the tokens are burned;
- the extraction is **never leveraged**: the farmer's gain is strictly less than what the pot
  deliberately spent, the difference going to LPs as fees and to every other holder as price;
- the farmer's cost is **real and at-risk**: a pool-scale bag held for as long as the pot takes to
  spend, exposed to the market and to anyone else's sandwich the whole time;
- the pot cannot be milked idle: with no pot inventory nothing fires, and every pump rides behind a
  real, fee-paying swap.

**Resolution.** Accepted and documented. Posture 4 is inherent to *every* buyback that trades behind
user flow — a holder can always sell into the pot's buying — and the design's answer is pace tied
to use, not prevention: `PUMP_FEE_LEVERAGE` (`k = 4`) is the tunable — a smaller `k` raises the
bag threshold (`1/(1.6k)`: 15.6% at 4, 7.8% at 8) and slows the buyback alike — and `PUMP_REFILL`
(thirty minutes) sets the dead-market floor. `REFERENCE_TAU` (ten minutes) and
`REFERENCE_MAX_RISE_PER_MINUTE` (296 ticks) set how long a pushed price must be held against the
market before the gate reopens on it — the cap making that time grow with the size of the push.
Operators who want a smaller residual can also lower `PUMP_SHARE_MAX_WAD` or `PUMP_HAIRCUT_BPS`,
trading buyback aggressiveness for it. The fee ceiling (`V ≤ f·R`) is the load-bearing bound on
posture 1 and the gate `f/d` on posture 2; both are unchanged by any tuning of the pace.

### No other findings

The review found no path to: farm the pump at an artificial price (§4.2), double-credit a donation
(reentrancy guard + measured pull; `test_A5`), touch a swapper's own trade (§4.1), make a swap
revert through the hook (§4.6), hijack a pot's roles (`test_U4`), re-declare roles
(`PotAlreadyReady`), steal main through a hostile token or recipient (the delivery holds or parks,
accounted, and never reverts a swap; `test_A4`, `test_B1`, `test_B3`), fake a burn through a lying
GlueStick or token (the unglue counts only on the hook's verified balance drop; `test_B2`,
`test_B3`), block a pool's creation through a hostile GlueStick (the ensure is best-effort;
`test_B9`, `test_NS3`), sneak a dynamic-fee pool past either creation door (`test_DR1`,
`test_DR2`), drift the harvest split by a
wei (§4.6), double-dip a bounced push (`test_A11`), edit rules after the operator role was zeroed
(`test_L10`, `test_L11`, `test_L22`), move a surrendered program's liquidity (`test_L11`,
`test_L20`), exercise another owner's property rights (`test_L19`, `test_L20`, `test_L21`), move
a native program's owner or recipients off its engine (`test_N5`, `test_N6`), make a native
program's engine — reverting, gas-burning or re-entering — affect a delivery, the ledger or the
carrying swap (`test_N9`–`test_N11`), or double-count a harvest leg between the callback and the
ledger (`test_N15`, PN1–PN2).

---

## 8. Trust assumptions & operational notes

- **Admin trust is scoped to configuration, not funds.** A pot admin sets the roles once and can
  re-point the recipient, but has **no** withdrawal path and cannot touch donated secondary or parked
  main. A malicious admin can at worst route a *future* buyback's main to an address of their choice
  (including themselves) — donors should verify a pool's recipient before donating, exactly as they
  would verify any on-chain destination.
- **The program's two roles split settings from property, and neither reaches funds.** The OPERATOR
  edits shares, recipients, mins and the `publicHarvest` gate — nothing else; the OWNER adds/removes
  the program's own liquidity and harvests — but neither can reach donated secondary, another pool's
  anything, or funds already booked to a recipient. The manual harvest is owner-only unless the
  config opens it; opening it is safe by construction (a public harvester can only trigger the
  frozen-at-call-time split, never redirect a wei). The two surrenders are independent:
  `setProgramOperator(poolId, address(0))` freezes the rules while the owner keeps the pool, and a
  zeroed owner locks the liquidity forever (with the harvest gate forced open) while a live operator
  may still edit rules. Nobody is ever forced to trade one for the other, and richer custody —
  timelocks, vesting, DAO control — is built by transferring ownership to a contract on top
  (proven by `test_L21_lockerOnTop`).
- **The burn is the Glue Protocol's, and the hook trusts it only as far as its own balance.** Every
  burn is a pure `unglue` (empty collateral list) through the canonical `GLUE_STICK` singleton,
  accepted only on the hook's verified balance drop. The GlueStick is outside this review's scope;
  the integration is designed so its worst behaviours degrade, never escalate: a missing, reverting
  or lying GlueStick turns a burn into a hold and a creation-time ensure into a no-op — it can
  never fake a burn, revert a swap, or block a pool.
- **The terminal hold is deliberate.** A burn-intent main whose unglue refuses (Glue won't admit
  it, or it blocks the pull) is held on the hook with no withdrawal path — out of circulation by
  custody. This is a feature, not stranding: the alternative (any retrieval path) would be a burn
  that someone can reverse.
- **MAIN must be glueable.** `initPot` and `launchPool` reject the network token and `NATIVEWRAP`
  (the chain's canonical wrapped native, a constructor immutable) as main, because neither can run
  the Glue burn. Both remain fully legal as SECONDARY — the buying side is unrestricted.
- **The pool fee is immutable, by refusal.** The hook serves static-fee pools only — a key
  carrying the dynamic-fee sentinel is rejected on both creation doors — so no operator, admin or
  hook path can ever move the fee a pool's traders and LPs signed up for. The refusal also turns
  the fee field into a creation namespace: a million distinguishable static values per pair for
  otherwise-identical pools.
- **Refused deliveries are never lost.** A live recipient that bounces a transfer (blocklist,
  reverting `receive()`) parks the main per-pool; anyone may retry through `flushDirect(poolId)`,
  which always pays the pot's *current* recipient. Harvest-split recipients book into the owed
  ledger instead (folded into the next push, claimable with full gas).
- **Fee-on-transfer secondary** is credited at the measured amount that arrived; a 100%-fee donation
  is refused. **Fee-on-transfer / rebasing MAIN** should be wrapped before use — the pump's
  delivery accounting assumes the main that leaves the PoolManager is the main the hook receives.
- **Zero-fee pools never pump** (§4.3) — this is by design, not a bug.
- **The pump paces itself to the pool's use.** A pot spends at most `4×` the LP fees the pool
  earns plus one fee ceiling (`fee × depth`) per half hour, whoever is trading (§4.4), and follows
  a rally at a share that shrinks with main's premium over the pool's ten-minute reference, which
  itself rises at most ~3% a minute (§4.2). A pot that seems to "under-spend" in a quiet market, in
  a burst or in a spike is doing exactly what closes GH-1's postures 2 and 4; it buys every dip at
  full size, and a dump of an eighth of the pool's depth always gets a full pump. The economics
  are an AMPLIFIER of trading, not life support: a dead pool with a full pot spends one ceiling
  per half hour at most.
- **A native program's engine is trusted with nothing.** The hook learns of an engine from the
  Glue registry alone (`isRegisteredEngine` at creation — one tolerant `staticcall`, never a
  hardcoded address) and afterwards only PUSHES to it: the remainder legs it would have pushed to
  any recipient, then a fire-and-forget `recordHarvest` at the carrying call's gas whose revert
  is swallowed. The engine cannot redirect a wei (its recipients are pinned to itself), cannot block
  or re-enter a harvest or a swap (guard + raw call), and cannot lie about what it
  received: `deliveredCumOf` is written by the hook from the push's own outcome and is the
  exactly-once source the engine reconciles against. The one operational duty is on the Glue
  side: **register the engine pair (`GlueLP_GlueHook`, `GlueLockerLPV0`) on the Stick BEFORE its
  first launch** — the stamp is read once at creation, so a program created by a not-yet-registered
  engine is plain forever (its recipients are then the engine as passed, but nothing is reported
  and the ledger stays zero).
- **The reference is the pool's own, not an oracle.** It is fed only by the pool's ticks that stood
  across block boundaries, lives in the pot's own storage, and is re-seeded from the live tick
  whenever a donation funds an empty pot — so a pot funded after a long idle never gates on a
  stale price. A pool that only runs an LP program never pays for it.

---

## 9. Deployment checklist

0. **The Stick first.** `GLUE_STICK` is a compile-time constant (`GlueHook.sol` and
   `GlueLiquidity.sol` — both must agree; the fixture and the fork suite mirror it). It is the
   address every Glue burn and the native-program stamp (`isRegisteredEngine`) are bound to for the
   life of the deployment, so the Glue Protocol's Stick of the SAME generation must be live at that
   address on a chain before the hook is deployed there — `deploy-all.mjs` fails a chain without it.
   Changing the constant changes the bytecode: rebuild, re-run the campaign, re-check `--sizes`.
   Current value: the Glue campaign-4 Stick `0x32b926e7D6ac6B92e50dF40dDfd3555691bc8b3b`
   (generation V4, hook `0xbB021554C5294328b04fa313669715bD201BA040`; the V3 build bound to
   `0xD16E…9b4d` is retired — that Stick was never handed over).
1. **Mine the deployer.** Run `scripts/mine-deployer.mjs` to mine a fresh key whose **nonce-1**
   CREATE address has low 14 bits equal to `REQUIRED_HOOK_FLAGS` (`beforeInitialize | afterSwap`
   = `0x2040`). The constructor asserts this, so a wrong address fails at deploy time. (Single-chain alternative: `scripts/mine-salt.mjs` for a CREATE2 salt.) Both addresses are known the
   moment the key is mined — the Glue engine pair (step 6) can be built against the hook address
   before the hook itself lands. Record the generation (deployer, library, hook, Stick, sweep
   destination, compiler profile, source commit, per-chain arguments) in a private, git-ignored
   record; the deploy tooling journals every landing into it, and a later chain is deployed from
   it alone (the key's nonce there is 0, so the same two addresses land).
2. **Deploy per chain** with `scripts/deploy-nonce0.mjs <rpcUrl> <poolManager> <nativeWrap>`: the
   `GlueLiquidity` library lands at nonce 0, the hook — its init code linked against that real
   library address in place of the `foundry.toml` sentinel — at nonce 1, with the constructor
   arguments `(poolManager, nativeWrap)`. `<nativeWrap>` is the chain's canonical wrapped native —
   the WETH9-style wrapper Uniswap's own periphery uses (WETH, WBNB, WPOL, WAVAX…); pass the zero
   address ONLY on a chain with no spendable native coin. Any chain with a V4 PoolManager; both
   addresses identical everywhere. The deployer key has no purpose after its two nonces: its
   leftover gas is swept to the operator's wallet by the script and the key is retired.
3. **Launch a pool in ONE transaction** with `launchPool(key, sqrtPriceX96, main, recipient,
   tickLower, tickUpper, liquidity, owner, config)` — initialise + roles + program + seed in a
   single call, the caller becoming the pot admin. (Or run the steps separately: **initialise** a
   pool naming the hook — the initialiser becomes the pot admin — then **`initPot(key, main,
   recipient)`** to declare which currency is defended and where its buybacks go, `address(0)` for
   buy-and-burn. The roles are irreversible except for the recipient.) The MAIN must be a glueable
   ERC20 — the network token and `NATIVEWRAP` are rejected; declaring it ensures its glue exists.
4. **Donate** the secondary to fund the pot. The pump activates the moment the pot is non-empty
   (the reference is seeded from the live tick as it fills) and stands aside whenever it is empty.
5. **(Optional) verify the venue live** by running the fork suite against the target chain:
   `FORK_RPC_URL=<rpc> FORK_POOL_MANAGER=<manager> forge test --match-contract GlueHookFork` — the
   whole machine (pump behind both directions, harvest, compound, buyback split, a native launch
   against the real Stick) against that chain's real deployed PoolManager before a single wei is
   committed.
6. **Glue engine rollout order.** Deploy the V3-bound engine pair (`GlueLP_GlueHook` with this
   hook as its `PUMP`, then `GlueLockerLPV0`), **register it on the Stick**, and only THEN let it
   launch its first pool: the native stamp is `isRegisteredEngine(msg.sender)` at creation, read
   once and never revisited. A pool launched before registration is a plain program forever.

---

## 10. Reproducing this audit

```bash
forge clean && forge test            # 191 tests (197 with FORK_RPC_URL set)
forge test --match-contract GlueHookInvariant          # PP1–PP6 + walks (bare pool)
forge test --match-contract GlueHookProgramInvariant   # PI1–PI6 + PN1–PN4 + walks (program armed, plain and native)
forge test --match-contract GlueHookNative             # N1–N16, the Glue engine integration
forge test --match-contract GlueHookFormal             # FM1–FM15, 512 runs each
forge test --match-contract GlueHookMev -vv            # M1–M11, the MEV surface (logs the tables)
forge test --match-contract GlueHookPotSplit           # SP1–SP10 + NS1–NS4, the buyback split
forge test --match-contract GlueHookLaunch             # LA1–LA10, the one-tx launch
forge test --match-contract GlueHookDynamicFee         # DR1–DR4, the dynamic-fee rejection
forge test --match-contract GlueHookGas -vv            # G1–G4, the §11 gas numbers
FORK_RPC_URL=<rpc> forge test --match-contract GlueHookFork   # FK1–FK6 on a live chain (run the full suite once first so every artifact exists)
forge build --sizes                  # GlueHook 19,439 bytes (under EIP-170) + GlueLiquidity 19,612
./scripts/run-external.sh            # §6.1: the 49 auditor-skill tests (FOUNDRY_PROFILE=external), not part of the count above
./scripts/run-external.sh --match-contract ExtPSH   # one firm (ExtTOB / ExtPSH / ExtQS / ExtPAN)
```

The invariant depth/runs live in `foundry.toml` (`[profile.default.invariant]`); raise them for a
longer soak.

---

## 11. Gas costs

Deterministic `gasleft()` measurements from `test/GlueHookGas.t.sol` (G1–G5), run with the audited
compiler profile against the real etched PoolManager. Each number is the delta around the external
call, so it includes calldata and call overhead — what a caller actually pays on top of the venue —
but NOT the 21,000-gas transaction base cost, which is added explicitly where transactions are
compared. Reproduce with `forge test --match-contract GlueHookGas -vv`.

### 11.1 Launching a pool

| Path | Execution gas | All-in (incl. 21k base per tx) |
|---|---:|---:|
| **`launchPool` — ONE transaction** (initialise + roles + program + seed) | 669,375 | **690,375** |
| `initialize` | 56,726 | |
| `initPot` (incl. the creation-time Glue classification + ensure) | 195,793 | |
| `addLiquidityAdvanced` (incl. the native-stamp registry probe) | 410,765 | |
| Three-step total (3 transactions) | 663,284 | 726,284 |

The one-transaction launch pays ~6k extra execution gas (the launch orchestration) but saves two
transaction base costs, landing **~36k cheaper all-in** — and it is atomic: a failed step rolls the
whole launch back (LA5), where the three-step path can strand a half-configured pool between
transactions. Both creation paths carry the one-time Glue classification (`wrapperOf`) and the
ensure (`ensureWrapper` on a fresh main — the bulk of `initPot`'s cost, which in the fixture
deploys a real wrapper clone); a main already glued skips the ensure.

### 11.2 Swap overhead per circumstance

Measured through the same swap-router shape in every row, so the deltas isolate the hook's own work.

| Circumstance | Buy | Sell | Hook overhead vs bare V4 |
|---|---:|---:|---|
| Bare V4 pool (no hook) | 58,749 | 60,605 | — |
| Hooked pool, pot EMPTY, no program (idle) | 68,783 | 66,628 | +10,034 buy / +6,023 sell |
| Pot funded: **pump fires** behind the buy | 155,246 | | +96,497 (observe + bucket credit + gate + the pot's own swap + Glue delivery) |
| Pot funded: **pump fires** behind the sell | | 132,437 | +71,832 (the same, into a warmer pool) |
| Program present, mins DISARMED (the plain `addLiquidity` default) | | +122 over idle | one storage read; the pending-fee scan never runs |
| Program ARMED, mins not reached (scan, no fire) | | +10,051 over disarmed | one batched `extsload` scan of the position's fee growth |
| Armed program: **auto-harvest + merged compound mint** inside the swap | 485,447 | | the two-sided harvest, the split, the Glue burn leg, and the collect netted against the compound mint in ONE `modifyLiquidity` |
| NATIVE program: the same in-swap auto-harvest, plus the report | +5,926 over the plain twin | | two ledger `SSTORE`s, the `HarvestRecorded` event and the `recordHarvest` call (the mock engine's five warm writes included) — measured on a steady-state frame (G5: 227,544 vs 221,618, no compound mint in either) |

The idle overhead — the only cost every swap on a hooked pool pays unconditionally — is one storage
read of the pot record plus the callback plumbing: ~6–10k, down from ~9–13k in V2 now that there
is no `beforeSwap`. The reference observation, the bucket and the gate add nothing to an unfunded
pool and ~6k to a funded one (the pot's slot is already warm; the observation and the bucket write
are warm `SSTORE`s, and the sizing arithmetic runs in `GlueLiquidity` through one delegatecall —
the move that took the hook from 24.8k to 19.4k bytes of runtime). The native report costs a
frame ~6–9k when the engine behaves; an engine that burns gas is charged to the carrying call
and can fail the swap on its own program's pool only (G5, N10). The heavy circumstances only
ever run on the swaps that trigger them,
the trigger's own try/catch guaranteeing a failure skips the work instead of reverting the
carrying swap.

### 11.3 Steady-state entries

| Entry | Gas |
|---|---:|
| `donate` (native) | 58,447 |
| Manual `harvest` (two-sided collect + split + burn leg + merged compound mint + payouts) | 303,124 |
| Manual `harvest`, NATIVE program: the report's marginal cost | +8,424 over the plain twin (G5: 160,246 vs 151,822 on a steady-state frame, incl. the mock engine's own bookkeeping and its forwarder frame) |
| `addProgramLiquidity` (harvest-first add) | 110,300 |
| `removeProgramLiquidity` (harvest-first remove) | 89,404 |

Numbers move with pool state (tick crossings, cold vs warm slots, whether a compound places both
legs), so treat them as representative magnitudes, not constants; the suite's assertions are
regression ceilings at roughly 2× these values.
