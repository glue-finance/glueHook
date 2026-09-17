<p align="center">
  <a href="https://gluehook.trade">
    <img src="web/public/gluehook-logo.png" alt="GlueHook" width="320" />
  </a>
</p>

**A Uniswap V4 buyback-and-burn hook.** One hook singleton hosts a permissionless donation **pot** for
every pool that adopts it: the pot **pumps** behind every swap — buying main behind buys and buying
the dip behind sells — and everything it buys is delivered to the pot's recipient — `address(0)`
means **burn**, so the default configuration is buy-and-burn. Each pool may additionally run an **LP program**: one hook-held liquidity position whose
trading fees are auto-harvested and split — a share fuels the pot, a share burns, the rest pays a
recipient per side.

Built by [Glue](https://github.com/glue-finance) and released as an open preview of the Glue stack.
The hook is fully standalone: it runs on any chain with a V4 `PoolManager`, over any pair, with no
external protocol wiring at all.

## Deployed everywhere — one address, 19 networks

The hook lives at the **same canonical address on every network**, source-verified
on each chain's explorer. Launch pools, add liquidity and manage programs from
[**gluehook.trade**](https://gluehook.trade) ([app](https://gluehook.trade/app) ·
[simulator](https://gluehook.trade/app?tab=simulate) · [docs](https://gluehook.trade/docs)).

```
GlueHook       0x03D482cB3Ff339C2d29736818D0F72c66dD6A040   (V3 generation, permission bits 0x2040)
GlueLiquidity  0x01f739de084e7Cd3554dd4fABA970D346d3DD8Bb   (linked library)
GlueStick      0xBe99cB426fDf30F95784337d4e8CC460AC8e8608   (compile-time constant — the Glue Protocol's Stick)
```

> The address above is the **V3** deployment — landed 2026-09-16 on 14 mainnets and 5 testnets, same
> address everywhere, bound at compile time to the Glue Protocol's `GlueStick`
> `0xBe99cB426fDf30F95784337d4e8CC460AC8e8608`. It was deployed from the Glue repository's
> release orchestrator, which lands the Stick first, then this hook, then the Glue engine pair
> that binds to it (`GlueLP_GlueHook` `0x7d45a4DEa073ED9b55058EaCbc82ea9520784165` →
> `GlueLockerLPV0` `0xDf2f0f4e64D5FFC18CE01F73dbbf50823Eb3BebE`). The earlier generations — V2 at
> `0x0F41…20c8` (bits `0x20C8`) and V1 at `0xb216…60C8` — are not the hook the Glue engines point
> at, but they are still deployed and still work: their exact source, addresses and what changed
> between generations live in [`legacy/`](legacy).

| Mainnets (14) | Testnets (5) |
|---|---|
| [Ethereum](https://etherscan.io/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Base](https://basescan.org/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Unichain](https://uniscan.xyz/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Arbitrum](https://arbiscan.io/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Optimism](https://optimistic.etherscan.io/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [BNB Chain](https://bscscan.com/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Polygon](https://polygonscan.com/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Avalanche](https://snowscan.xyz/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [X Layer](https://www.oklink.com/x-layer/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [World Chain](https://worldscan.org/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Soneium](https://soneium.blockscout.com/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [MegaETH](https://megaeth.blockscout.com/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Robinhood](https://robinscan.io/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Arc](https://explorer.arc.io/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) | [Sepolia](https://sepolia.etherscan.io/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Base Sepolia](https://sepolia.basescan.org/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Unichain Sepolia](https://sepolia.uniscan.xyz/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Arbitrum Sepolia](https://sepolia.arbiscan.io/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) · [Robinhood Testnet](https://explorer.testnet.chain.robinhood.com/address/0x03D482cB3Ff339C2d29736818D0F72c66dD6A040) |

**Arc** (chain id 5042, Circle's USDC-gas L1, public mainnet 2026-09-16) is the one chain with no
WETH9: Uniswap's `weth9` slot there is an `UnsupportedProtocol` stub, so the hook's `NATIVEWRAP`
on Arc is the gas coin's own 6-decimal ERC-20 face, `0x3600000000000000000000000000000000000000`.
`NATIVEWRAP` is only the never-glue-the-gas-coin guard (a pot's main may never be it), so that is
the honest value — nothing else in the hook reads it. Arc's PoolManager is
`0x8366a39CC670B4001A1121B8F6A443A643e40951` (Uniswap's official deployment).

### What's new in V3

V1 and V2 are fully permissionless and work forever — V3 exists because the pot could buy
**better**. The launch write-up with the full numbers:
[*We froze the contracts. GlueHook V3 is live (67× better than V2)*](https://x.com/glue_fi/status/2100237021264450020).

- **The pot can no longer empty itself in one transaction.** V1/V2 ran two modes — buying on buys
  and defending on sells — and the defence could spend 100% of the pot at whatever price was on
  the screen. V3 turns the defence into a buy and puts a TWAP underneath it: the most it spends
  behind any one swap is `0.8·f·R` (0.8% of pool depth at a 1% pool), measured against its own
  ten-minute time-weighted reference. It buys in slices, paced against the market — hard into
  dips, pulling back as a rally runs ahead of the reference. Same money, more supply bought.
- **One mechanism, behind every swap, in both directions.** It buys when you buy and it buys when
  they sell: behind a buyer it adds to the buy, behind a seller it buys the dip that seller just
  made. Traffic is the trigger; the pump runs inside the swapper's own transaction, so there is
  nothing in the mempool to front-run.
- **Best price and MEV are the same problem.** Every rule that stops the pot buying into a pushed
  price is also the rule that stops someone manufacturing that price to farm it. The sandwich was
  already closed in V2 (−40% of fees); V3 closes the other two doors by one to two orders of
  magnitude — unlocking the pot costs 50% of it in fees instead of 2.5%, round-trip farming needs
  a bag of 16% of depth instead of ~1.25%, a pushed premium shrinks the pump as `f/d`, and the
  reference rises at most 3% a minute. Between **20× and 67×** depending on the fee tier; the
  derivations are in [*The pump math*](#the-pump-math--every-play-priced-at-a-loss).
- **The before-swap path is gone.** V3 runs on `0x2040` — `beforeInitialize` + `afterSwap` only —
  and never touches a swapper's amounts. Your trade is the pool's plain execution and the buyback
  happens after it: **quotes are exact** (every router prices a GlueHook pool with vanilla V4
  math; integrating is reading one address), **swaps cannot be blocked** (every hook action is a
  try/catch self-call — a failing buyback is skipped, never the swap), and **the surface shrank**
  (less hook code in the hot path of other people's money).
- **Better Glue integration.** Still general-purpose — any app, any pair — but the burn now goes
  through Glue directly (cheaper, wrapper-aware), and native programs stream live harvest data to
  the Glue engines used for staking and locking, so anything built on the Glue ecosystem gets
  auto-harvesting compatibility and a cheaper integration.

## Why this hook exists

Buyback programs today are either **manual** (a multisig watches the price and clicks) or **oracle-fed**
(a keeper bot reads a price feed and fires a transaction — trusting the oracle, the keeper, and the gap
between them). GlueHook removes both dependencies: it is an **automatic, contract-to-contract
buyback** that executes inside other people's swaps, priced by the pool's own arithmetic at the moment
of execution. No external price oracle, no keeper, no off-chain trigger — the only reference it keeps
is a time-weighted tick of the pool itself, stored in the pot's own slot and fed only by prices that
stood between blocks.

The trade-off is stated plainly: the mechanism narrows *who decides when* (nobody decides — the market
does), which limits discretionary control, and in exchange it **automates the buyback on the users' own
financial incentives**. Every swap is a real market participant paying their own gas; the pot buys
behind each of them — behind a buyer because buying is what they came to do, behind a seller because
the dip is where a buyback buys best — and the system needs no privileged actor, only traffic.

The hook closes a second gap the venue leaves open: **concentrated-liquidity pools do not compound**.
In V2, fees accrued inside the reserves and every LP's position grew automatically; V3 and V4 park fees
*outside* the position, so they sit idle until someone pays gas to collect and re-mint them — which in
practice means keeper services, position managers, or fees that never compound at all. GlueHook's LP
program gives a pool **native auto-compounding**: a configurable share of every harvest is re-minted
into the position *inside the swaps that generated the fees*, with the same no-keeper, no-oracle,
traffic-powered trigger as the buyback itself.

---

## How it works

A hooked pool declares two roles for its two currencies at `initPot`:

| Role | Meaning |
|---|---|
| **MAIN** | The asset being defended. It is what the pot buys and what the recipient receives. |
| **SECONDARY** | The buyback currency. The ONLY asset the pot holds and the ONLY asset `donate` accepts. |

Either side may be native ETH and either may be `currency0`, so the hook is pair-agnostic — a token
quoted in ETH is one configuration, not a rule. The hook serves **static-fee pools only**: a key
carrying the dynamic-fee sentinel (`0x800000`) is refused at creation, on both doors
(`beforeInitialize` and `launchPool`). The fee is part of a pool's identity here — a million
distinguishable static values per pair that creators and integrators can use as a namespace for
otherwise-identical pools — and every price the hook quotes reads the one immutable fee the key
declares.

### PUMP — `afterSwap`, behind EVERY swap

The pot spends secondary on main **inside the swapper's own transaction**, in either direction, and
delivers what it bought. Behind a buy it adds to the buy; behind a sell it buys the dip the sell just
made. The swapper's own trade is the pool's plain execution, untouched — the pump is the hook's own
swap, run through a `try/catch` self-call, so a pool state that would revert the buyback skips the
pump instead of reverting the swap.

The spend is the **smallest of four ceilings, then an 80% haircut**:

| Ceiling | Size | What it closes |
|---|---|---|
| **Fee ceiling** | `fee · depth` (the pool's live fee × its tangent reserve) | the sandwich: for any attacker size the sandwich pays only if the pump exceeds `fee·depth` |
| **Spend bucket** | at most one fee ceiling, credited **`4 ×` the fee every swap pays** plus one ceiling per **30 minutes** of time | the rush: the pot's pace is tied to what the pool *earns* — a hot market is bought hard, a dead one barely, and manufactured volume unlocks only `4×` what it cost in fees |
| **Demand ceiling** | a **share** of the secondary the swap moved (paid on a buy, received on a sell) | gradualism: a dust trade unlocks a dust pump |
| **Reference gate** | the share itself: **60%** at or below the pool's reference tick, **`fee / premium`** above it | farming a pushed price: pushing main up `d` costs `2·fee` per unit, the pump hands back at most `d` of its own size, and BOTH legs of the round trip (push and dump) summon pumps — so `f/d` is the exact break-even |

**The reference** is a time-weighted tick each funded pool's pot keeps (a ten-minute time constant:
an observation `dt` after the last moves it `min(1, dt/τ)` of the way to the tick that STOOD in
between). It is fed only by ticks that stood across a block boundary — a swap in the same block as the
last one adds nothing, and the pot's own pumps never enter it. It may **fall freely** (a dip reopens
the gate at once) but **rise at most ~3% a minute** (296 ticks): believing a `+d` push takes `d / 3%`
minutes of a price held against the whole market, however the time constant is set. It is seeded from
the live tick when the pot is declared and whenever a donation funds an empty pot, it lives in the
pot's own storage slot (a swap reads it for free), and its arithmetic is bounded integer math that
cannot revert.

### Why it cannot be played

- **Sandwiching the pump loses.** For a sandwich the attacker's own legs cancel out of the algebra
  and the profit condition reduces to *pump spend > fee·depth*. The pump never spends more than
  `fee·depth` (then takes 80% of it), for every attacker size, pot depth and price at once.
- **Pushing the price to farm the pump loses.** Moving spot inside your own transaction or your own
  block never moves the reference, so the push reads as a premium and the gate shrinks every pump
  you summon to `f/d` of the leg that summoned it — break-even at best before the haircut, a loss
  after it. Moving the reference means holding a price against the whole market for minutes, and
  the bigger the push the more minutes: 3% of it per minute at most.
- **Manufacturing volume buys nothing.** Every swap unlocks at most `4×` its own fee for the pot;
  a bag-holder farming round trips at the reference pays `2f` per unit of volume and their bag is
  lifted by `2·bag/depth` of what the pot spends, so the farm pays only for a bag above ~16% of the
  pool's depth — held the whole time, exposed, and lifted no more than every other holder. A
  bag-less manufacturer recovers under a tenth of their fees.
- **Dips are bought at full size.** At or below the reference there is no premium to sell into, so
  a genuine dip, and ordinary choppy trading, get the full share; a genuine rally is bought at a size
  that shrinks with its premium and grows back as the reference catches up.
- **The swapper pays the pump's gas.** Executing inline in `afterSwap` means there is no separate
  transaction to front-run.

### The pump math — every play priced at a loss

The constants, all fixed in the bytecode (`GlueLiquidity`):

| Symbol | Value | Meaning |
|---|---|---|
| `R` | live | the pool's **tangent depth** at spot — the constant-product reserve a V4 pool behaves like at its current tick (`GluedV4Core.tangentReserve`) |
| `f` | live | the pool's static fee as a fraction (`3000` → `0.003`) |
| `B` | per swap | the **demand**: secondary the carrying swap moved — paid on a buy, received on a sell |
| `d` | live | main's **premium** over the reference: `1.0001^Δ − 1` for the tick gap `Δ`, oriented so `d > 0` is a dearer main |
| `s(d)` | `min(60%, f/d)` | the reference gate's share (`PUMP_SHARE_MAX_WAD = 0.6e18`) |
| `k` | `4` | fee leverage of the spend bucket (`PUMP_FEE_LEVERAGE`) |
| `T` | `30 min` | one full bucket refill by time alone (`PUMP_REFILL`) |
| `τ` | `10 min` | time constant of the reference (`REFERENCE_TAU`) |
| `ρ` | `296 ticks/min` | the reference's maximum rise, `1.0001^296 ≈ +3%` per minute (`REFERENCE_MAX_RISE_PER_MINUTE`) |
| `h` | `0.8` | the haircut (`PUMP_HAIRCUT_BPS = 8000`) |

Behind every swap of a funded pool the pot spends

```
spend = h · min( f·R ,  f·R · L/T ,  s(d) · B ,  pot balance )
```

where `L ∈ [0, T]` is the spend bucket's level, kept as *seconds of refill* in one packed timestamp.
Each term below is one attack, the ceiling that closes it, and the algebra that shows the attacker
strictly losing once the haircut lands.

**1. The sandwich → the fee ceiling `f·R`.** A pump is a market buy that someone else's transaction
triggers — the exact shape of a sandwich victim. Let the attacker buy `X` in front of a pump of size
`V` and sell behind it, on a pool of depth `R`. Writing `u = X/R`, `v = V/R`, the constant-product
algebra gives the attacker's gross profit exactly as

```
profit = R · u·v · (2 + u + v) / ((1 + u)² + u·v)      ≈  2·X·V / R   at leading order
```

and their cost is the fee on both legs, `2·f·X`. The attack pays iff `2·X·V/R > 2·f·X`, i.e.
**iff `V > f·R`** — the attacker's own size `X` cancels out entirely. So a single bound on the
pump, `V ≤ f·R`, closes the sandwich for every attacker size, pot depth and price at once. With the
haircut the pump spends at most `0.8·f·R`, so the best a sandwich can do is
`2·X·(0.8·f·R)/R − 2·f·X = −0.4·f·X`: a guaranteed loss of 40% of the fees paid, before the
attacker's own price impact. Nothing here is a hardcoded size — a deeper pool or a fatter fee tier
earns a proportionally larger pump.

**2. The rush → the spend bucket `f·R · L/T`.** The fee ceiling bounds *one* pump and says nothing
about a thousand of them in a block. A holder of a large bag could manufacture cheap round trips at
or below the reference, each summoning a pump, and compress the pot's whole future spend into a
moment they alone are positioned for. The bucket paces the pot to what the pool **earns**:

```
level after a swap:   L ← min(T,  L + k · B/R · T)          (a swap paying fee f·B credits k·f·B of budget)
level over time:      L ← min(T,  L + Δt)                    (one full ceiling per T as a slow floor)
level after a pump:   L ← L − spend/(f·R) · T
```

so over any window `W` with traded secondary volume `Vol`, the pot spends at most
`k·f·Vol + f·R · W/T`: a hot market is bought hard, a dead one barely. A single sell of `R/k`
(a quarter of the depth) fills the bucket by itself. For the farmer: a round trip of `Vol` each
way costs `2·f·Vol` in fees and unlocks at most `h · 2·k·f·Vol` of pump; a constant-product buy of
`S` lifts spot by `≈ 2·S/R`, so a bag `b` gains `b · 2 · (h·2·k·f·Vol)/R`. That beats the fees iff

```
b > R / (2·k·h) = R / 6.4  ≈ 16% of the pool's depth
```

— a bag that large, held the whole time at the market's mercy, lifted by exactly the same amount as
every other holder, and only realisable by dumping into the pool that was just pumped. A bag-less
manufacturer recovers `h·2·k·f·Vol` of buy pressure they do not own against `2·f·Vol` of fees they
do: under a tenth back.

**3. Gradualism → the demand ceiling `s·B`.** The pump never spends more than a share of the
secondary the carrying swap itself moved. A dust trade summons a dust pump; the pot is spent in
step with real flow, never all at once.

**4. Farming a pushed price → the reference gate `s(d) = min(60%, f/d)`.** The demand ceiling lets
a trader *summon* a pump by trading, so a trader who first pushes spot a premium `d` above the
reference and then trades is summoning a pump at an inflated price they can sell into. Pushing spot
by `d` on a constant-product pool takes a leg of `P ≈ d·R/2`, costing `f·P` in and `f·P` out; both
legs — the push and the dump — present demand at the premium, so each summons a pump of `s·P`, and a
pump hands the attacker at most `d` per unit (they sell at the premium the pump is buying at). The
round trip nets

```
gain − cost  =  2·s·P·d − 2·f·P  >  0   iff   s > f/d
```

so the gate sets `s(d) = f/d` exactly at break-even, and the haircut makes it `0.8·f/d`: the round
trip returns `1.6·f·P` against `2·f·P` of fees, a loss of 20% of the fees before the attacker's own
impact on the unwind. At or below the reference there is no premium to sell into, so `s = 60%` and
dips, ordinary trading and choppy markets are bought at full size. A genuine rally is bought at a
size that shrinks as `f/d` while the reference catches up — for a 0.3% pool and a +3% premium the
gate is `0.1`, at +30% it is `0.01`.

**5. Moving the reference → the time-weighted tick with an asymmetric cap.** The gate is only as
good as the reference, so the reference is built to be cheap to lower and expensive to raise:

```
observation dt seconds after the last:   ref ← ref + (lastTick − ref) · min(1, dt/τ)
rise (a dearer main) clamped to:         |Δref| ≤ ρ · dt/60  =  296 ticks per minute  (≈ 3%/min)
fall:                                    never clamped
```

`lastTick` is the tick the **previous** swap left, weighted by the time it stood — so a swap in the
same block as the last one contributes nothing, and the pot's own pumps never enter it. Nothing a
transaction does to spot inside its own block can move the reference; the only way in is a price
held across a block boundary against the whole market, exposed to arbitrage the entire time. To
make the pot believe a `+d` push the attacker must hold it for at least `d / 3%` minutes: `+3%`
takes a minute, `+30%` about nine, `+100%` well over twenty — and every one of those blocks is a
block in which anyone may sell into the held price. A dip, by contrast, reopens the full 60% share
at once.

**Putting the four together.** Take a pool of tangent depth `R = 100 ETH` and a 1% fee, with a
full bucket and spot at the reference. A 5 ETH buy arrives: its credit (`4·5/100 = 0.2` of a
ceiling) is clamped — the bucket was already full — so fee ceiling `1 ETH`, bucket `1 ETH`, demand
ceiling `0.6 × 5 = 3 ETH` → the pump spends `0.8 × 1 = 0.8 ETH` and the bucket is left at `0.2`.
A second 5 ETH buy a few seconds later: credit `0.2` lifts the bucket to `0.4` of a ceiling, which
is now the binding term → `0.8 × 0.4 = 0.32 ETH`. A 0.1 ETH buy: demand ceiling `0.06 ETH` binds
→ `0.048 ETH`.
Then someone pushes spot +5% and sells 5 ETH into it: `s = 0.01/0.05 = 0.2`, demand ceiling
`1 ETH`, but the bucket holds whatever refilled → the pump is small, priced below their break-even,
and the reference has not moved because the push never stood across a block. Every number above is
read from the pool's own state in the same transaction; there is no oracle to feed and no
parameter for anyone to tune.

### Delivery — can never revert a swap

A pot's `recipient` is stored verbatim; `address(0)` means **BURN**. Two rules frame everything below:

- **MAIN must be glueable.** Every burn is the Glue Protocol's own, so `initPot` and `launchPool`
  reject the network token and `NATIVEWRAP` (the chain's canonical wrapped native, a per-chain
  constructor immutable) as main outright: neither can run a Glue burn. Declaring a pot
  **classifies the main once** through the canonical **GlueStick** singleton's registry
  (`GLUE_STICK.wrapperOf`, the same address on every chain): a main that IS a GlueWrapper resolves
  to itself, a glued main to its wrapper, and a fresh main has its glue **ensured** on the spot
  (`ensureWrapper`, best effort under `try/catch` — a refusal never blocks the pool, the glue is
  retried lazily at the first burn). The result is recorded per asset and drives every later burn.
- **A refused delivery is never lost.** A live recipient that bounces the transfer (a blocklist, a
  reverting `receive()`) parks the main on the hook, booked **per pool** in `parkedDirectOf`, and anyone
  may retry it any time through `flushDirect(poolId)` — it pays the pot's *current* recipient.

A burn takes the shape the main's classification dictates, with one terminal fallback — the hook
never destroys supply itself:

1. **The Glue burn** (a glued main) — an exact-amount approval to the main's **own GlueWrapper**,
   then the wrapper's `unglue` with an **empty collateral list**: a PURE BURN, no GlueStick hop.
   The supply is pulled from the hook and destroyed inside the protocol (which runs its own
   burn / dead-route fallbacks), redeeming nothing and concentrating the glue's backing for every
   remaining holder. Accepted only on the hook's **verified balance drop** — a codeless wrapper or
   a lying token never counts as burned.
2. **The park** (a main that IS a GlueWrapper — the ERC20 face of a wrapped ERC20 or ERC721
   collection) — no unglue can burn wrapper shares (an NFT wrapper takes whole units only and
   rejects the empty-collateral shape outright), so the shares are **transferred to the wrapper's
   own address**. That is the one custody Glue's supply oracle subtracts from circulation
   (`parkedShares`): the shares can never move again, the NFTs behind them stay in the collection,
   and every remaining holder's unglue payout concentrates — the exact effect of a burn. Works for
   any wei amount, on ERC20-mode and NFT-mode wrappers alike, delivery mode `BURNED`.
3. **Held forever** — for a main whose burn refuses (Glue won't admit it, or it blocks the pull):
   the amount is held on the hook itself, booked in `heldOf`, with **no withdrawal path of any
   kind** — custody IS the burn. The asset is flagged unburnable on the first refusal, so every
   later burn of it settles straight to the held ledger without re-running the probe.

Donations are irreversible and there is no withdrawal path for a pot, for parked main, or for held
main. `obligationOf(asset)` sums every pot, everything parked, everything held, the owed backlog,
and every program's compound carry in that asset — and the hook's balance always covers it.

**The buyback split.** When the pool carries an LP program, its operator can carve the pot's output —
whichever direction summoned the pump — *before* the recipient logic above runs: `potCompoundShareWad` of every
purchase is credited to the program's compound **carry** (it becomes pool liquidity on the next
harvest, delivery mode `COMPOUNDED`), `potBurnShareWad` walks the burn cascade, and the exact
remainder follows the pot's recipient as always. Shares are floored individually and the rest is
computed by subtraction, so the three legs sum to the output to the wei. Both shares at zero (the
default, including everything created by plain `addLiquidity`) is the classic behaviour bit-for-bit.
The same laws apply as everywhere else: `potCompound + potBurn ≤ 100%`, and when the pot's
recipient is itself `address(0)` the burn share and the rest merge into ONE burn walk. The carry
credit is pure accounting and cannot fail; the split adds zero new swap-revert paths.

### LP PROGRAM — one position per pool, fees that feed the machine

The pot admin may create the pool's single hook-held liquidity position:

- **`addLiquidity`** — a normal position: zero shares, both fee recipients default to the owner,
  auto-harvest disarmed. Everything can be turned on later.
- **`addLiquidityAdvanced`** — full rules at creation: the compound share, the buyback share, the
  burn share, the buyback split (`potCompoundShareWad` / `potBurnShareWad`), one recipient per side,
  and the auto-harvest minimums.

Each program carries **two independent roles**, both explicit parameters rather than `msg.sender`,
and each surrenders on its own terms — nobody is ever forced to give up the pool just to lock the
rules, or vice versa:

- The **OWNER** holds the property — add/remove liquidity and harvest. Transferable through
  `transferProgramOwnership`; `address(0)` (at creation or by transfer) is the explicit full
  surrender: the liquidity locks forever and the manual harvest is forced public. Richer custody
  policy (timelocks, vesting, DAO control) is built ON TOP by making such a contract the owner —
  a locker simply becomes the owner.
- The **OPERATOR** edits the split rules (`setProgramConfig`). The role starts on the owner and
  moves through `setProgramOperator`; setting it to `address(0)` **freezes the rules forever**
  without the owner losing the position — the immutable-fees promise with no LP lock attached.

Fees are harvested automatically inside `afterSwap` once the accrued fees reach the configured
minimums (a `try/catch` self-call, so a heavy harvest can never revert the carrying swap), or
manually through `harvest(key)` — **owner-only by default**, opened to anyone by the config's
`publicHarvest` flag (the auto-harvest is inherently public: any swap triggers it). A program with
both minimums disarmed (the plain `addLiquidity` default) costs a swap **one storage read** — the
pending-fee scan never runs. When a harvest fires, the collect and the compound mint are **one
`modifyLiquidity`**: the fees pay the mint inside the PoolManager's own netting, checked against
its `feesAccrued` and capped by the compound budget, with the plain collect as the fallback. Every
share is a fraction of the **GROSS fees of its side**, so the numbers mean exactly what they say:

| Side | Shares (must sum to ≤ 100%) | Remainder |
|---|---|---|
| **SECONDARY** fees | `compoundShareWad` → the LP budget · `buybackShareWad` → credited to the pool's own pot (buyback fuel) | → `secondaryRecipient` |
| **MAIN** fees | `compoundShareWad` → the LP budget · `burnShareWad` → the burn cascade above | → `mainRecipient` |
| **POT OUTPUT** (the buyback split) | `potCompoundShareWad` → the compound carry · `potBurnShareWad` → the burn cascade | → the pot's recipient |

The **compound** is the auto-compounding the venue never gave concentrated-liquidity LPs,
selectable as a simple percentage: the budget of both sides is re-minted into the program's own
position at the live price, across any tick range — whichever side binds caps the mint. Whatever
the mint cannot place this time is saved in the program's **CARRY** and added to the NEXT harvest's
compound budget: it retries LP-ing forever and never leaks to the pot or a recipient. A failed
mint abandons the compound alone (the budget stays in the carry) and the harvest never blocks. A
config edit only changes how future harvests split — nothing already harvested or carried is
re-touched.

A burn share is always legal (the main is glueable by construction), and a side whose shares
sum below 100% must name a live recipient. Recipient pushes run at the carrying call's gas and
never revert: a refusal books the exact amount in a per-`(recipient, asset)` **owed ledger** that folds into the next successful push
automatically and is always claimable with full gas via `claim(asset)`. Adds and removes harvest
first, so principal and fees never mix.

#### NATIVE programs — the Glue staking integration

A program created by an address the GlueStick's registry reports as a **registered Glue LP engine**
(`isRegisteredEngine(msg.sender)` at creation, through `launchPool`, `addLiquidity` or
`addLiquidityAdvanced`) is stamped **`native`** once and forever. The hook hardcodes no engine —
that registry read is its only knowledge of Glue beyond the burn — and a program created by anyone
else takes **zero new code paths**. What the stamp does:

- **Pinning.** The engine is the owner, the first operator and BOTH remainder recipients, whatever
  was passed. `transferProgramOwnership` refuses (a new owner and a surrender alike); a config that
  moves either recipient off the engine is `BadConfig`. Shares, `publicHarvest`, the auto-harvest
  minimums and the operator seat stay editable, so the engine's own config sync keeps working.
- **The delivered ledger.** On EVERY harvest of a native program — the in-swap auto-harvest, the
  manual `harvest`, and the harvest-first inside the program's own add / remove — after all the
  frame's deliveries, burns and compounds, the hook advances `deliveredCumOf(poolId, asset)` by
  exactly what **landed** on the engine: the push plus any `owed` backlog it folded in, ZERO for a
  leg that had to be booked `owed` (it counts in the frame that later pays it). Monotonic, per
  `(pool, asset)`, and the engine's exactly-once source of truth.
- **The report.** Then `IGlueHookedEngine.recordHarvest(poolId, deliveredMain, deliveredSec)` is
  fired at the engine as a raw call at the **carrying call's gas** (no stipend: the callee is a
  Glue-registered engine, and a fixed number in an immutable hook would drift with every engine
  upgrade and every chain gas repricing), return data ignored, revert
  swallowed — `HarvestRecorded(poolId, engine, dMain, dSec, recorded)` tells which. The callback
  runs inside the hook's reentrancy guard (a re-entering engine is thrown out with `Reentrancy`
  and the report still completes), AFTER every send of the frame, so nothing the engine does can
  touch a delivery, the pot, the compound or the carrying swap. The engine attributes from the
  callback and reconciles any callback that failed by diffing the ledger against its own cursor —
  so every unit reaches its stakers **exactly once**, whether the callback landed or not. A frame
  that landed nothing on the engine is not reported.

The hook never trusts the engine: the callback is fire-and-forget with its revert swallowed, the
ledger is the source of truth, and the engine sees nothing the hook did not already deliver. **Deployment
note:** the engine pair (`GlueLP_GlueHook`, `GlueLockerLPV0`) must be registered on the Stick
BEFORE its first launch — a program created by a not-yet-registered engine is stamped non-native
and stays so forever (the stamp is read once, at creation).

---

## API

| Entry | Who | What |
|---|---|---|
| `beforeInitialize` | the PoolManager | refuses dynamic-fee keys (static-fee pools only), then records whoever called `initialize` as the pot's admin |
| `initPot(key, main, recipient)` | that admin, once | declares the roles; the other currency becomes secondary |
| `setRecipient(poolId, recipient)` | that admin | moves the delivery target (`address(0)` = burn) |
| `donate(key, amount)` | anyone | credits the pot by measured delta (fee-on-transfer safe); native pots take `msg.value`, ERC20 pots take an allowance |
| `flushDirect(poolId)` | anyone | retries a delivery the pot's live recipient refused, paying the pot's current recipient |
| `launchPool(key, sqrtP, main, recipient, tl, tu, liquidity, owner, config)` | anyone, on a pool that does not exist yet | the whole launch in ONE transaction: initializes the pool (the caller becomes the pot admin), declares the roles and creates the seeded program — same validation, events and funding rules as the standalone entries |
| `addLiquidity(key, tl, tu, liquidity, owner)` | the pot admin, once | creates the pool's program with everything off; `(0,0)` ticks = full range; the owner is also the first operator |
| `addLiquidityAdvanced(key, tl, tu, liquidity, owner, config)` | the pot admin, once | creates the program with full rules; `owner == 0` = surrendered at birth |
| `setProgramConfig(poolId, config)` | the program operator | edits shares (fee split AND buyback split), recipients, `publicHarvest`, and auto-harvest minimums (a native program's recipients are pinned to its engine) |
| `setProgramOperator(poolId, newOperator)` | the program operator | moves the settings role; `address(0)` = rules frozen forever, owner untouched |
| `transferProgramOwnership(poolId, newOwner)` | the program owner | moves the property; `address(0)` = liquidity locked forever, harvest forced public; refused on a native program |
| `addProgramLiquidity` / `removeProgramLiquidity` | the program owner | grows / shrinks the position (harvests first) |
| `harvest(key)` | the program owner, or anyone when `publicHarvest` | collects the program's fees and runs the split with full caller gas |
| `claim(asset)` | any owed recipient | pulls its refused-push backlog with full gas |
| `quotePump(key, demand)` / `pumpShareOf(poolId)` | anyone | preview the pump a swap moving `demand` secondary would trigger (all four ceilings, live state) / the gate's current share with the live and reference ticks |
| `potOf` / `programOf` / `parkedOf` / `heldOf` / `parkedDirectOf` / `owedOf` / `obligationOf` | anyone | pot/program state and full asset attribution |
| `deliveredCumOf(poolId, asset)` | anyone | a native program's cumulative harvest legs DELIVERED to its engine in `asset` — monotonic, the engine's exactly-once reconcile cursor; zero for every non-native program |

---

## Deployment

Uniswap V4 encodes a hook's permissions in the **low 14 bits of its address**. GlueHook must live
at a mined address carrying exactly

```
beforeInitialize | afterSwap  =  0x2040
```

The constructor asserts its own address, so a mis-mined deployment fails at deploy time.

### Same address on every chain (recommended)

CREATE2 cannot do this: its address commits to the init code, and the PoolManager constructor arg
differs on every chain. Plain **CREATE** can — `keccak256(rlp(deployer, nonce))` ignores the init
code entirely — so the tooling mines a **fresh throwaway deployer key** and deploys TWO contracts
from it, in order: the `GlueLiquidity` library at **nonce 0**, then the hook (delegatecall-linked
against that library) at **nonce 1**, whose address is mined to carry the hook bits. Both land at
the same addresses on every EVM chain, including chains where V4 ships later (deploy there whenever
their PoolManager exists; the addresses still match).

Two things are fixed before the first transaction. The **GlueStick** is a compile-time constant
(`GLUE_STICK` in `GlueHook.sol` and `GlueLiquidity.sol`, currently
`0xBe99cB426fDf30F95784337d4e8CC460AC8e8608`): every Glue burn and the native-program
stamp are bound to it for the life of the deployment, so the Glue Protocol's Stick of the same
generation must already be live on a chain before the hook is deployed there. Repointing the
constant is a new generation: rebuild, mine a new deployer, new addresses everywhere. And the deployer
key's **two addresses are known the moment it is mined** — so the Glue engine pair that binds to
the hook can be built against the hook address in parallel with the deploy.

```bash
npm install && forge build

# 0. the GlueStick of this generation must carry code on every target chain (the deploy
#    orchestrator refuses a chain without it). Keep a private, git-ignored record of the
#    generation — deployer, library, hook, Stick, sweep destination, compiler profile, source
#    commit, per-chain PoolManager + nativeWrap — so a later chain deploys from the record alone.

# 1. mine a fresh deployer (~16k keccaks, <1s). Writes the key to .deployer.key
#    (git-ignored, chmod 600, never printed). Prints the deployer + the library + hook addresses.
node scripts/mine-deployer.mjs

# 2. fund the printed deployer with a little gas on each target chain

# 3. deploy per chain — MUST be the key's first two transactions there (library, then hook; the
#    script links the hook's init code against the real nonce-0 library address). It refuses to
#    run unless: nonce == 0 (or 1 with the library already landed), the hook target is empty, the
#    PoolManager and the nativeWrap are live contracts (both are immutable args — a typo burns
#    that chain's shot), and the nonce-1 address carries 0x2040.
#    <nativeWrap> is the chain's canonical wrapped native — the WETH9-style wrapper Uniswap's own
#    periphery uses (WETH, WBNB, WPOL, WAVAX…); on a chain with no WETH9 (Arc) the gas coin's own
#    ERC-20 face; the zero address ONLY on a chain with no spendable native coin. It becomes the hook's NATIVEWRAP: a pot's main may never be it (nor the network
#    token), because every burn is the Glue Protocol's own (a wrapper unglue or a wrapper park).
node scripts/deploy-nonce0.mjs <rpcUrl> <poolManager> <nativeWrap>
```

Nonce discipline is the whole game: the deployer key must never send anything before the deploy on
any chain, and has no purpose after — the script sweeps its leftover gas to the operator's wallet;
discard the key once every chain is live. A chain added later is deployed the same way from the
record: the key's nonce there is still 0, so the same library and hook addresses land.

### Single chain via CREATE2 (alternative)

```bash
# deploy the GlueLiquidity library first (any address), then mine a salt for your CREATE2
# deployer + the LINKED init code, then deploy through it
node scripts/mine-salt.mjs <create2Deployer> <poolManager> <glueLiquidityAddress>
# verify: address & 0x3FFF == 0x2040
```

## Build

Solidity `^0.8.35`, EVM target `prague`, viaIR. The only external dependency is
OpenZeppelin Contracts (interfaces + SafeERC20):

```bash
forge install OpenZeppelin/openzeppelin-contracts
forge build
```

Repository layout:

```
contracts/
  GlueHook.sol            the hook (pot factory + reference-gated pump + Glue burn + LP program + native-program report)
  interfaces/
    IGlueHook.sol         the hook's public API
    IGlueStickMin.sol     the minimal GlueStick surface the hook talks to (wrapperOf + ensureWrapper + isRegisteredEngine)
    IGlueWrapperMin.sol   the minimal GlueWrapper surface the hook talks to (the pure-burn unglue)
    IGlueHookedEngine.sol the ONE callback a native program's engine receives (recordHarvest)
  libs/
    GlueLiquidity.sol        DELEGATECALL-linked engine: pump sizing (ceilings, bucket, gate) + harvest (merged collect + compound / split / burn / config)
    GluedV4Core.sol           V4 math + callback base + hook flag constants (MIT)
    GluedMath.sol             512-bit mul-div (MIT)
scripts/
  mine-deployer.mjs           vanity deployer key miner (library at nonce 0, hook at nonce 1 — same addresses on every chain)
  deploy-nonce0.mjs           per-chain two-transaction deployment (link + deploy) with strict pre-flight checks
  mine-salt.mjs               CREATE2 hook-address salt miner (single-chain alternative)
  run-external.sh             runs the auditor-skill suites (test/external, `external` profile)
erc7730/                      ERC-7730 clear-signing descriptors for every user-facing call
test/
  *.t.sol                     the main campaign (191 tests, 197 with FORK_RPC_URL; `forge test`)
  external/                   4 firm-skill suites, 49 tests — skipped by `forge test`, run via scripts/run-external.sh
audit/
  AUDIT.md                    the self-audit
  external/                   firm-skill check tables (ALREADY SAFE / NEW COVERAGE per row)
```

The hook stays under EIP-170 (`GlueHook` 19,439 bytes, `GlueLiquidity` 19,612) by delegating the
LP program's heavy bodies — fee collects, the flat harvest split, the compound mint, config
validation, the native stamp and report — to `GlueLiquidity`, a linked library
running in the hook's own storage and address. The artifact is statically linked against a sentinel
address (`foundry.toml`); the deploy script substitutes the real library address at deploy time, and
the test fixture etches the library runtime at the sentinel.

## Security

A full self-audit — scope, threat model, the pump math with proofs, the invariant catalogue,
findings, trust assumptions, and a deployment checklist — lives in [`audit/AUDIT.md`](audit/AUDIT.md).

The whole campaign is in `test/` and reproducible with `forge clean && forge test` (**191 tests, 0
failures**; **197** with `FORK_RPC_URL` set), all against a real Uniswap V4 `PoolManager` — etched
from its runtime bytecode for the deterministic suites, and the LIVE deployed singleton for the
fork suite:

| Suite | Count | What it proves |
|---|---:|---|
| `GlueHookInvariant` | 9 | PP1–PP6 stateful invariants (384 runs × 64 depth, with time skips in the walk) + 3 anti-vacuity walks: pot solvency, donation conservation, a sell-side pump never lifting main past where the sell started, pump boundedness (≤ 48% of the carrying swap's secondary), main attribution, delivery identity |
| `GlueHookProgramInvariant` | 7 | PI1–PI6 + 1 anti-vacuity walk: the SAME random walk with the LP program live and every split leg armed — harvests, compounds and pumps behind both directions interleaved in the same frames — proving solvency, exact main attribution (parked + held + carry + owed), pot conservation with harvest fuel as a real inflow, delivery identity, and monotone program liquidity |
| `GlueHookNativeProgramInvariant` | 5 | PN1–PN4 + 1 anti-vacuity walk: the same armed walk over a NATIVE program owned by a registered recording engine — the delivered ledger equals the engine's cumulative balance delta on both assets to the wei (what LANDED, never gross), the engine's `recordHarvest` sums equal the ledger (a reconcile would credit zero: callback and reconcile never overlap), the ledger never decreases, solvency under native load |
| `GlueHookNative` | 16 | N1–N16, the Glue engine integration: the stamp through `launchPool` / `addLiquidityAdvanced` / `addLiquidity` (passed owner and recipients ignored), a stranger's and an un-registered engine's program plain, a codeless / reverting / short-answering / garbage-answering Stick never blocking creation, ownership pinned (no transfer, no surrender) while shares / gate / mins / operator stay editable and a moved recipient is `BadConfig`, the manual harvest's exact report (`msg.sender == hook`, exact legs, ledger == landed, `HarvestRecorded(..., true)`, an empty frame silent), the owed leg reporting zero then `push + backlog` when it lands, a reverting engine flagged false with the ledger advancing and the swap untouched, a gas-burning engine charged to the carrying call (never bounded: a generous budget finishes the frame, a tight one fails the harvest on the engine's own program only), a re-entering engine thrown out by the guard from a manual harvest and from inside a swap, the in-swap report behind a buy and a sell (never when disarmed), the harvest-first report inside add and remove, `native` packed in slot 0 with `owner` opening slot 1 (`vm.load`), exactly-once across six frames of mixed succeeding / failing callbacks (ledger − recorded == the failed frames' legs), and the report carrying the remainder only alongside a pump, a fuel leg and a burn leg in one frame |
| `GlueHookUnit` | 14 | deploy gate, callback auth, admin capture, role validation, native/ERC20/fee-on-transfer donations, the pump behind a buy and behind a sell, a thin pot, recipient delivery, views and quotes, dust |
| `GlueHookAdversarial` | 14 | differential twin-pool parity for the seller (wei-exact), self-sandwich unprofitability, manipulate-dump-unwind losing, hostile recipients/tokens, reentrant donate + reentrant harvest recipient, zero-fee refusal, the pump firing behind both directions, pot isolation, sandwiching a stranger's credited full pump losing at every size, bag-less volume manufacturing recovering under a tenth of its fees, a block-controller holding a pushed price for a full τ still gated |
| `GlueHookMev` | 25 | M1–M11: the pump's MEV surface attacked — manipulate–dump–unwind losing at five push sizes, a pre-positioned bag farmed inside a block losing, the reference's mechanics (seeded at init, deaf inside a block, linear in standing time on a fall, re-seeded on funding, asleep while empty), the gate's `min(60%, f/d)` share table to the tick, dips at full share whatever the history, the pace bound on a PATIENT bag holder (pot spend ≤ `k·f·volume` + floor; a 4% bag loses, a 25% bag gains strictly less than the pot spent and at most `2·bag/depth` of it), the bucket (bounded inside a block by ceiling + credits, linear time refill, `k·f·volume` pace over ten minutes of continuous trading, a `depth/k` sell refills it alone, dust immunity, quote parity credit included, quiet-market manufacturing losing), revert-freeness under fuzzed trades and time skips and at the edge of the tick range, per-pool isolation, gate and rise-cap orientation with main as `currency0`, the rise cap (a held +69% opens at 296 ticks a minute not at τ, a held ×4 needs 47 minutes, a fall is never capped) |
| `GlueHookBurn` | 15 | the Glue burn path (a pure `unglue` called on the main's own GlueWrapper with an exact allowance consumed whole, verified by the hook's balance drop, the GlueStick's `unglue` provably out of the path), the held-forever terminal for a refused unglue, the unburnable flag's permanent short-circuit, per-asset flag isolation, `flushDirect` retries, the glueable-main gate (network token and NATIVEWRAP rejected on `initPot` AND `launchPool`), the creation-time classification (fresh main glued, glued main skipped, wrapper main never ensured) — plus the wrapper-main cases: an NFT-mode and an ERC20-mode GlueWrapper main PARK on themselves (`parkedShares` grows by exactly the burn, supply untouched, nothing held, no unglue), the harvest's and the pot's burn legs parking in ONE walk from a `launchPool`-created program, lazy glue (a main the Stick refused at declaration is glued at its first burn; one it keeps refusing is flagged and never probed again), and wrapper/plain mains isolated across pools |
| `GlueHookLiquidity` | 17 | both LP entries, creation gates, config validation (per-side share sums, recipient rules), the exact gross-referenced harvest split, auto-harvest minimums, harvest-first adds/removes, the owed backlog + `claim`, the operator-zero config freeze, surrendered-at-birth, lifecycle solvency, the harvest gate, owner/operator separation, ownership transfer + surrender, a timelock locker owning a program, frozen rules travelling across a transfer |
| `GlueHookCompound` | 10 | the compound leg end to end: exact split + conservation, in-swap mints, the 100% budget corner, share-sum validation, the solvency dance, multi-round growth, carry accumulation + retry drawn down wei-for-wei, one-sided-fee skew, a zero-fee harvest retrying a standing carry, and the carry surviving a config edit |
| `GlueHookDecimals` | 10 | mixed-decimals ERC20/ERC20 pools (6/18 and 8/18, roles both ways) launched at a human 1:1 price — magnitude proofs that a 100-unit buy delivers ~100 units in the other side's own raw scale, pump deliveries behind both directions in correct raw units, the exact WAD harvest split over 6-dec raw fees, real compound mints from mixed-scale fees, pot solvency after a trading burst; the gate decimals-blind on both orientations (the same human push reads the same share on a 6/18 and an 18/8 pool) and under fuzzed (6\|8\|18)² decimals pairs, the bucket's ceiling and credit in 8-dec raw, the pace bound in 6-dec raw |
| `GlueHookFormal` | 15 | fuzzed theorems (512 runs each): pump spend bounds (pot, fee ceiling, gated share), monotonicity in demand, seller parity against the hookless twin, the gate's share sane at every premium (`≤ f/d`), live-pump-within-quote, quote purity, exact split conservation over arbitrary share pairs, compound-within-budget over every legal triple with carry-inclusive conservation, owed-ledger exactness, self-sandwich accounting (the attacker loses, every spend burns), auto-compound monotone growth, global carry conservation across whole harvest sequences, the pace bound over fuzzed trade-and-wait sequences (`spend ≤ k·f·Σdemand + f·R·(1 + elapsed/PUMP_REFILL)`), the rise bound between any two observations, the volume credit exact from a drained bucket |
| `GlueHookPotSplit` | 14 | the buyback split end to end: zero-default parity with the unsplit delivery, the wei-exact three-way carve on the pump's output behind a buy and behind a sell, the burn-intent single-cascade merge, no-program neutrality, set-time validation + operator gating, plain-`addLiquidity` defaults (owner == operator, split off), the remove-all-liquidity carry cycle with the exact carry identity, the 100%-compound corner — plus the NS never-stop matrix: a refusing recipient parks, a main that blocks its own glue's pull holds, a main Glue refuses to admit holds (and never blocks creation), and a re-entering harvest recipient bounces off the guard |
| `GlueHookLaunch` | 10 | LA1–LA10: the one-transaction `launchPool` — admin capture, funding + refunds, rejections (existing pool, foreign hook, bad main, native main), atomic rollback, and a launched pool fully operational |
| `GlueHookDynamicFee` | 4 | DR1–DR4: dynamic-fee keys are refused on BOTH creation doors (`beforeInitialize` for a direct initialize, `launchPool` itself — the PoolManager skips the callback when the hook is the caller), nothing half-made survives a rejection, static twins are untouched, and same-pair pools at adjacent static fees coexist independently |
| `GlueHookGas` | 6 | G1–G5 + G2b: deterministic `gasleft()` measurements behind regression ceilings — launch vs three-step, per-circumstance swap overhead (idle, pump behind a buy, pump behind a sell), the armed bit (a disarmed program costs a swap one slot read; the pending-fee scan is the armed cost), in-swap harvest + merged compound mint (anti-vacuity: the measured swap really minted), steady-state entries, the native report's marginal cost on a manual and on an in-swap harvest against a plain twin |
| `GlueHookFork` | 6 | the pump behind a buy, the pump behind a sell, the manual harvest + compound, the in-swap auto-harvest, the buyback split (compound + burn + rest on a live pump) against the LIVE deployed PoolManager on a forked real chain, and a NATIVE launch against the REAL GlueStick at `0xdac0…` — the hook asking `isRegisteredEngine` for real about a registered engine's address, the swap-carried harvest reporting to it (verified on Ethereum mainnet); gated on `FORK_RPC_URL`, PoolManager address overridable with `FORK_POOL_MANAGER`, the registered engine with `FORK_ENGINE` |

A second, separate layer restates the campaign in the shape of four public audit firms' skill
checklists — Trail of Bits, Pashov, QuillShield, Panther (**49 tests, 0 failures**, not an official
audit of any of them): every external door attacked from the wrong caller, weird-ERC20 secondaries,
the transient PAYER window attacked by a MAIN that rides the manager's unlock, the full reentrancy
matrix from a native engine's full-gas report, read-only reentrancy mid-frame, force-feeding,
under-gassed swaps, the pump's spend and floor pinned to the exact formula, the uint32 clock across
its wrap. It runs on its own profile (`./scripts/run-external.sh`); each row's verdict and its
main-suite twin live in [`audit/external/`](audit/external/README.md).

One informational finding (GH-1) walks every posture around a swap-triggered buyback with its full
two-sided accounting: the sandwich of a pump is closed by the fee ceiling (proven), pushing the price
to farm the pump is closed by the reference gate (`M1`, `M2`, `A3`, `FM10`) with the rise cap making
a held price slow to believe (`M11`, `A14`), and the one residual — a large holder selling into the
pot's own buying — is paced by the spend bucket to `4×` the fees the pool earns, so that the farm pays
only for a bag above ~16% of the pool's depth and even then captures at most `2·bag/depth` of what the
pot spends, held the whole time, at the market's mercy and shared with every other holder (`M6a–c`,
`M7g`, `A13`, `FM13`, with the bound stated and measured).

## Clear signing (ERC-7730)

Human-readable signing screens for every user-facing GlueHook call live in
[`erc7730/`](erc7730/) and ship to the [ERC-7730 clear-signing registry](https://github.com/ethereum/clear-signing-erc7730-registry)
under the `glue` entity (`calldata-GlueHook.json`). Wallets that consume the registry render
"Launch TOKEN/ETH pool" instead of a selector + hex blob. PoolManager callbacks and the hook's
self-calls are intentionally undescribed — those screens stay generic.

## Licence

Business Source License 1.1 — see [`LICENCE.txt`](LICENCE.txt). Licensed Work: **GlueHook**,
(c) 2026 gluefinance.eth, owned by Glue Labs Inc. (Delaware). Change Date: the earlier of **2030-08-05**
or a date specified at `gluehook-license-date.gluefinance.eth`; Change License: **GPL-2.0-or-later**.
The `GluedMath` and `GluedV4Core` libraries are MIT.

Building on the officially deployed hook — pools, donations, integrations, interfaces, tokens adopting
it — is authorized and encouraged (see the Authorized Uses in the licence). Deploying your own copy is
not.
