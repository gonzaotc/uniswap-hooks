# Invariant Spec: ReHypothecationHook

- **Target contract:** `src/general/ReHypothecationHook.sol` (via `src/mocks/general/ReHypothecationERC4626Mock.sol`)
- **Campaign:** `ReHypothecationHookInvariants.t.sol`
- **Status:** `M-01` and `J-03` are harnessed and **violated**. `M-01`: a fuzzer-chosen tick
  range finds a bootstrap mint that takes zero of both currencies. `J-03`: `addLiquidity`
  (some fraction of calls target one of the hook's own boundary ticks, the rest are fully
  randomized) followed by `swap` reliably reproduces the swap reverting because the hook's own
  JIT add collided with a pre-saturated boundary tick. `E-01` is harnessed as a state-transition
  check after every `addReHypothecatedLiquidity`/`removeReHypothecatedLiquidity`/`addLiquidity`
  call. `J-01` and `J-02` are harnessed as plain between-transactions invariants, checked after
  every handler call. None of `E-01`/`J-01`/`J-02` has been observed to violate so far, but
  campaigns currently stop early on the `M-01`/`J-03` violations before exploring deep enough to
  meaningfully stress them. Everything else is drafted, not yet harnessed.

> **Assumptions.** The yield source moves funds only through the hook's own deposit/withdraw
> calls: no external donation, no external drain, no rebasing. Yield source deposits and
> withdrawals are exact and non-reentrant.

> **Terminology.** The hook owns one position, keyed by `(hook, tickLower, tickUpper, 0)`. `y_c`
> is the hook's yield balance for currency `c`. Shares are the hook's own ERC20. `previewMint`
> rounds up and `previewRedeem` rounds down, both benefiting existing holders over the acting
> party.

> **Prefixes.** `I` initialization, `J` the JIT liquidity lifecycle, `M` mint/redeem accounting,
> `E` entitlement, `S` solvency.

## J: JIT liquidity lifecycle

### INV-J-01: The hook holds no pool position liquidity outside a swap

- **predicate:** the hook's position liquidity is zero at every point between transactions.
- **status:** harnessed, not yet violated. Checked as a plain invariant after every handler call,
  reading `manager.getPositionInfo` for the hook's own position key.
- A violation means a swap added liquidity it never withdrew.

### INV-J-02: The hook holds no loose currency between transactions

- **predicate:** the hook's own token balance, and ETH balance on the native leg, is zero
  between transactions.
- **status:** harnessed, not yet violated. Checked as a plain invariant after every handler
  call: `currency0`/`currency1` balance of the hook, plus its native ETH balance.
- Catches a take-without-deposit or withdraw-without-settle leak during swap settlement.
  `INV-J-01` only checks the position, not the settlement transfers.

### INV-J-03: A swap must not revert because of third-party liquidity at the hook's boundary tick

- **predicate:** a swap succeeds even if an unprivileged actor has saturated `liquidityGross` at
  the hook's position's boundary tick beforehand.
- **status:** **violated.** Confirmed by direct reproduction: an external `modifyLiquidity` add
  at the hook's boundary tick, sized to that tick's `maxLiquidityPerTick`, makes every later
  swap revert with `TickLiquidityOverflow`. Permanent: no admin, no relocate, no pause.
- Scope, not "a swap must never revert": legitimate reverts exist (bad price limit, no
  liquidity before any mint, the disclosed reserve-timing warning, yield-source illiquidity).
  What's in scope here is narrower: the hook's own JIT contribution must not be the reason a
  swap that would otherwise succeed fails.
- `beforeAddLiquidity: false` means the hook can never refuse the saturating add; cheapest when
  the boundary sits at an extreme (full-range) tick, which is the shipped default.

## M: mint/redeem accounting

### INV-M-01: Shares must be backed by assets

- **predicate:** on every mint, `shares > 0 ⟹ amount0 > 0 ∨ amount1 > 0`; at all times,
  `totalSupply() > 0 ⟹ y0 > 0 ∨ y1 > 0`.
- **status:** **violated.** A bootstrap mint (`totalSupply() == 0`) with tiny `shares` at a
  narrow tick range can deposit zero of both currencies while still minting shares.
- One property, two angles: a mint must actually take assets from the caller, and once shares
  exist, at least one currency must still back them.
- `∨`, not `∧`: a single-sided deposit is legitimate at a boundary price for a full-range
  position, so only *both* legs at zero is unambiguously a bug.

### INV-M-02: Mint/redeem amounts stay in the yield-balance ratio

- **predicate:** for a given `shares`, `amount0 * y1 ≈ amount1 * y0`, within rounding.
- **status:** not harnessed.
- Weak by construction (close to restating the underlying `mulDiv` call); kept as a regression
  guard against the two legs being priced off inconsistent snapshots.

### INV-M-03: A mint immediately redeemed never returns more than was paid

- **predicate:** for one actor, mint(shares) then redeem(shares) with nothing else in between:
  amounts out `<=` amounts in, for both currencies.
- **status:** not harnessed.
- Needs one atomic handler action so nothing else can be interleaved between the two calls.

## E: entitlement

### INV-E-01: A mint or redeem never decreases another holder's redeemable amount

- **predicate:** for any mint or redeem by `X`, every other holder's `previewRedeem(balanceOf)`
  only stays the same or grows, within rounding.
- **status:** harnessed, not yet violated. Checked after every `addReHypothecatedLiquidity` and
  `removeReHypothecatedLiquidity` call: snapshots every registered actor's
  `previewRedeem(balanceOf)` before the call, then asserts every actor other than the caller is
  at or above their snapshot after. Also checked after `addLiquidity` (the pool-level, bypasses-
  the-hook action), where nobody is exempted: that action mints no hook shares, so no actor's
  redeemable amount should move at all.
- Swaps are out of scope: price movement changes per-currency totals in ways this can't tell
  apart from a real loss.

## S: solvency

### INV-S-01: A currency that has been used doesn't get stuck at zero

- **predicate:** once a currency's `y_c` has been positive, it should not fall back to zero and
  stay there while shares are outstanding, except through an explicit external drain.
- **status:** not harnessed.
- Reachable through ordinary swaps pushing price to the range edge, not only through a drain;
  a drain is a way to isolate the cause, not the only expected trigger.

### INV-S-02: Total shares equal the sum of actor balances

- **predicate:** `totalSupply() == Σ balanceOf(actor)`.
- **status:** not harnessed.
- Completeness canary for the actor set, not a hook-correctness property on its own.
