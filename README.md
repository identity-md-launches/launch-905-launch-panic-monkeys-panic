# Panic Monkeys ($PANIC) — Uniswap v4 launch hook

Panic Monkeys is a fixed-supply ERC-20 launched behind a Uniswap v4 hook that punishes selling while
the price is down and makes dip buying cheap. "Down" is measured against the hook's own 1-hour
time-weighted average price (TWAP) of the launch pool, which no trade in the current block can move.

| Contract | File | Role |
| --- | --- | --- |
| `PanicMonkeys` | `src/PanicMonkeys.sol` | The token. 1,000,000,000 PANIC (10^27 minor units, 18 decimals) minted once to the deployer. No owner, mint, pause, blocklist, fee or upgrade. |
| `PanicHook` | `src/PanicHook.sol` | The hook: reference TWAP, tiered hook fees, 60/30/10 fee split, permissionless claim / donate / buyback-and-burn. No owner, pause or upgrade. |
| `HookFlags` | `src/HookFlags.sol` | Permission-bit constants and address checks. |
| `HookMiner` | `src/HookMiner.sol` | CREATE2 salt mining for the permission bits. |
| `DeployPanic` | `script/DeployPanic.s.sol` | Reference deployment sequence (token, hook, pool) with an explicit config struct the tests drive directly. |

Build with Foundry (`forge build`, `forge test`, `forge fmt --check`). `foundry.toml` pins
`solc = "0.8.26"`, `evm_version = "cancun"` (transient storage), `via_ir = true`, and
`bytecode_hash = "none"`. All dependencies are vendored as plain files under `lib/` (forge-std,
v4-core `src/` + `test/utils/CurrencySettler.sol`, solmate `Owned.sol`); there are no git submodules
and the build needs no network.

## Behaviour

### Reference price

* The hook keeps an append-only list of observations `(blockTimestamp, tickCumulative)`, Uniswap v3
  style. It records at most one observation per block, taken from the pool's slot0 tick **before the
  first swap of that block** (`_observe()` runs at the top of `beforeSwap` and of `buybackAndBurn`).
  Trades in the current block therefore cannot move the reference.
* The reference tick is the arithmetic mean tick over the last 3,600 seconds (a geometric mean
  price), rounded toward negative infinity to a whole tick. The reference price is
  `TickMath.getSqrtPriceAtTick(referenceTick)`. This quantizes the mean by less than one tick
  (about 1 bp of price). With PANIC as currency1 it biases the reference upward; with PANIC
  as currency0 it biases it downward. Tier exactness below is relative to this computed
  reference, not an unquantized geometric mean. Fractional-tick interpolation is not implemented.
* Before the pool's first block the launch (initialization) price is assumed to have prevailed, so
  the window is a full hour from the very first swap. Without this, a dump seconds after launch would
  drag the reference down almost immediately.
* If no swap happens for an hour, the reference equals the price that has been flat since; the panic
  tiers then no longer apply (tested).
* Blocks that share a timestamp (some L2s) do not create a second observation; the block still counts
  as observed. Observation timestamps are `uint32` (wraps in 2106, same as Uniswap v3).
* Window lookups binary-search from a stored hint that only moves forward, so the per-swap cost does
  not grow with history.

### Drawdown

`drawdownBps = floor((1e18 - ceil(ratio * 1e18)) / 1e14)` where `ratio = PANIC price / reference
PANIC price`, computed exactly from the two Q64.96 sqrt prices with full-precision ceiling. A price
exactly 5% below the reference reports 500 and anything shallower reports at most 499, so the tiers
switch exactly at 5%, 15% and 30% (`test_drawdownIsExactAtThresholds`,
`test_sellTiersSwitchAtExactBoundaryPrices`). The pool orientation (PANIC as currency0 or currency1)
is detected at initialization and the math handles both.

### Hook fee (on top of the pool's LP fee), always in the paired currency

| Trade | Judged on | drawdown < 5% | 5% ≤ dd < 15% | 15% ≤ dd < 30% | dd ≥ 30% |
| --- | --- | --- | --- | --- | --- |
| Buy  | price **before** the buy  | 0% | 1% | 1% | 1% |
| Sell | price **after** the sell  | 2% | 10% | 20% | 30% |

* Exact-input buys: the fee is taken from the paired input through the `beforeSwap` return delta.
  The specified input is an all-in budget: `fee = floor(budget * rate / (10000 + rate))`, so
  the fee is at most 1% of the pool input, with at most one minor unit of conservative rounding.
  A fee-bearing partial fill reverts atomically with `PartialExactInputBuyNotSupported` in
  `afterSwap`: v4 cannot refund the specified currency there. Price-limited buyers that need
  partial fills must use exact-output buys; zero-fee partial buys remain supported.
* Exact-output buys: the paired input is the unspecified currency, so the fee (1% of what the pool
  needed) is taken through the `afterSwap` return delta instead.
* Exact-input sells: the fee is taken from the paired output through the `afterSwap` return delta.
* Exact-output sells are **rejected** (`ExactOutputSellNotSupported`): the paired output is the
  specified amount, and a v4 hook cannot adjust the specified currency after the swap, which is the
  only moment the post-sell price is known. Routers must quote sells as exact input.
* Nobody is exempt. The PoolManager skips callbacks on the hook's own swap, so the buyback
  explicitly charges the pre-buy tier on the input actually consumed, splits the fee, and emits
  `HookFeeCharged`. Existing claims are reallocated; the internal fee is not minted twice.
* Fee amounts round down, so a fee is never more than 30% of the amount it is taken from.
* The fee is credited to the hook as an ERC-6909 claim inside the swap (`poolManager.mint`). The
  swap never depends on the PoolManager already holding the paired currency, so a fee-bearing buy
  works on a fresh manager whose pool was seeded with PANIC only (tested).

### Fee split and outlets (all permissionless)

Every hook fee is split, in integer arithmetic with the remainder going to the oracle fund so the
three parts always sum to the fee exactly:

| Bucket | Share | Outlet |
| --- | --- | --- |
| Panic Oracle Fund | 60% | `claimOracleFund()` burns the claims and `take`s the paired currency to the immutable `oracleFund` address (the paying wallet). Only that address can ever receive it. |
| Liquidity providers | 30% | Donated inside the taxed swap to liquidity in range at its end using `PoolManager.donate`, funded by burning claims. Only when no liquidity is in range does `donationBucket` retain the share. Anyone can flush that fallback with `donateToLiquidityProviders()` once liquidity returns; otherwise it reverts (`NoLiquidityToReceiveFees`). The next taxed swap also flushes a pending donation when liquidity is available. |
| Burn | 10% | `buybackAndBurn()` / `buybackAndBurn(maxSpend)` spends `min(bucket, maxSpend, 1 ether)` on PANIC in this pool and `take`s every token bought straight to `0x000000000000000000000000000000000000dEaD`. Reverts with `BuybackBelowReference` if it would receive less than 98% of the PANIC the reference price implies for the amount spent. The cap and reference floor include the internal buy fee. Anything above the cap waits for the next call. |

The hook's claim balance always equals `oracleFundBucket + donationBucket + burnBucket`; the
split allocates every minor unit, with no unassigned dust. `totalDonated` records the LP share
already paid and is excluded from the claim balance and `totalAccruedFees()`. The reference-implied
PANIC quote carries division remainders and rounds down only once, in either pool orientation.
A buyback requires positive PANIC output and rounds its 98% minimum upward. Untradeably small burn balances stay
accounted for until more fees accrue; wasting them on a zero-output swap is forbidden. Claim and
donate impose no minimum amount.

Because the buyback is checked against the reference and not the spot price, it only passes near a
flat price when the LP fee plus impact stays under 2% (1.25% LP fee leaves 0.75% for impact), and
it passes easily when the price is down. In a thin pool, call `buybackAndBurn(maxSpend)` with a
smaller amount.

### Unresolved anti-splitting requirement

The required flat-start anti-splitting property is **not satisfied**. The supplied proof reproduces:
one 1,200 PANIC sell pays 211.890925346446133214 ETH, while ten 120 PANIC sells pay
116.773540169813521004 ETH, including the donated share in both measurements. Early slices
end in lower tiers. The reference stays frozen, but that cannot make their mandated rates equal.

For gross outputs `q_i` and prescribed post-sell rates `r_i`, the split fee is `sum(q_i * r_i)`;
a single sell ending at rate `r_final` pays approximately `sum(q_i) * r_final`. If any earlier
slice has `r_i < r_final`, the first sum is smaller. Charging the final tier retroactively would
violate the stated per-sell schedule. Capping a catch-up fee at 30% does not solve this generally:
a tiny sell crossing a threshold may owe more catch-up than 30% of its own output. A block's
running deepest drawdown also cannot change fees already settled on earlier slices.

This revision preserves the explicit per-sell tiers. Resolving the competing required test needs
an economic specification change before launch (for example, a marginal schedule changes the
required single-sell 20% result, while cumulative settlement changes the per-sell charges).
`test_flatStartSplittingCounterexampleUnderTheSpecifiedTiers` records the unresolved conflict.
`test_partitionWithinTwentyPercentTierHasOnlyRoundingDifference` and
`test_partitionRemainingInTopTierHasOnlyRoundingDifference` test only partitions staying within
one tier, with a 10 wei rounding tolerance. They do not prove general anti-splitting.

## Hook configuration (Wizard's canonical record)

```json
{
  "hook": "BaseHook",
  "name": "PanicHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": true,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": true,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": { "license": "MIT" }
}
```

Notes on the record: the hook implements `IHooks` directly rather than inheriting a library base
(v4-periphery is not vendored); `access` is deliberately none of the Wizard's options because the
brief forbids any admin. The constructor validates that the deployed address carries exactly the
declared bits (`Hooks.validateHookPermissions`), so a mis-mined address cannot deploy. Required
address bits: `beforeInitialize | afterInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta |
afterSwapReturnDelta` = `0x30CC` (12492).

`beforeSwapReturnDelta` is enabled only to take the buy fee from the specified input; the hook never
returns a delta that replaces the swap (no NoOp path). `afterSwapReturnDelta` only ever adds a
positive fee on the unspecified currency, at most 30% of the amount it is taken from.

## Deployment parameters

`PanicHook` constructor: `(IPoolManager poolManager, address panic, address oracleFund)`

| Argument | Manifest value | Meaning |
| --- | --- | --- |
| `poolManager` | `$poolManager` | The chain's Uniswap v4 PoolManager. Never hardcoded. |
| `panic` | `$token` | The launch token the factory deploys just before the hook. |
| `oracleFund` | the paying wallet | Fixed oracle budget address. The only recipient `claimOracleFund` can ever pay. |

Pool: PANIC paired with native ETH (`currency0 = address(0)`, `currency1 = PANIC`), LP fee 12500
(1.25%, the launch policy's tier), any tick spacing. `beforeInitialize` accepts any static LP fee
(so the listed tier is never refused), rejects the dynamic-fee flag, rejects a pool without PANIC,
and rejects a second pool for the same hook. The hook address must be mined with
`HookMiner.find(deployer, HookFlags.PANIC_HOOK, creationCode, 0, attempts)` where `deployer` is the
account that executes CREATE2 (the factory).

Token: no constructor arguments, name "Panic Monkeys", symbol "PANIC", 18 decimals, exactly 10^27
minor units to `msg.sender`.

`script/DeployPanic.s.sol` shows the sequence (token, mined hook, `initialize`). Its `run()` reads
`POOL_MANAGER`, `ORACLE_FUND`, `TOKEN_RECIPIENT`, `SQRT_PRICE_X96` and optional `LP_FEE`,
`TICK_SPACING` from the environment and hands a `Config` to `deploy(Config)`, which the tests call
directly. This repository does not broadcast anything and holds no keys.

### Immutable economics (compile-time constants)

| Constant | Value |
| --- | --- |
| `TWAP_WINDOW` | 3600 s |
| `DOWN_THRESHOLD_BPS` / `PANIC_TIER_2_THRESHOLD_BPS` / `PANIC_TIER_3_THRESHOLD_BPS` | 500 / 1500 / 3000 |
| `BUY_FEE_BPS` / `BUY_FEE_DOWN_BPS` | 0 / 100 |
| `SELL_FEE_BPS` / `_TIER_1` / `_TIER_2` / `_TIER_3` | 200 / 1000 / 2000 / 3000 |
| `MAX_HOOK_FEE_BPS` | 3000 |
| `ORACLE_SHARE_BPS` / `LP_SHARE_BPS` / `BURN_SHARE_BPS` | 6000 / 3000 / 1000 |
| `MIN_BUYBACK_OUTPUT_BPS` | 9800 |
| `MAX_BUYBACK_SPEND` | 1e18 minor units of the paired currency (1 ETH) |

## Assumptions

* The paired currency is native ETH (or another 18-decimal currency). `MAX_BUYBACK_SPEND` is
  denominated in the paired currency's minor units; with a 6-decimal pair it would be meaningless.
  The code otherwise supports any ERC-20 pair in either pool orientation (tested).
* The paired currency is a plain token: no fee-on-transfer, no rebasing. PANIC itself is plain.
* The pool is initialized by the launch factory in the same transaction as the hook deployment; the
  initialization callbacks exist so nobody can front-run that pool.
* The verifier compiles with the pinned `solc = "0.8.26"`, Cancun, `via_ir = true`. The PoolManager
  needs via-IR to fit under EIP-170 (the tests deploy a real `PoolManager`). A clean `forge build`
  takes about 1.5 minutes.

## Operational responsibilities

Nothing in the hook runs by itself. Someone (the project, a keeper, or any volunteer: all three are
permissionless and pay nothing to the caller) should periodically:

1. call `claimOracleFund()` to move the Panic Oracle Fund to the paying wallet;
2. call `donateToLiquidityProviders()` only if the no-liquidity fallback bucket is nonzero.
   Ordinary fees have already been donated during the swap. A position opened afterwards cannot
   capture them. The fallback still pays whoever is in range when it is flushed and retains JIT
   exposure; there was no in-range liquidity to receive it at the taxed swap's end. Immediate
   donation also does not prevent liquidity added before a victim swap from earning its fees;
3. call `buybackAndBurn()` repeatedly (1 ETH per call, 98%-of-reference floor) to burn the burn
   bucket. It reverts while the live price is more than about 2% above the reference, and may need
   `buybackAndBurn(maxSpend)` with a smaller amount in thin liquidity. The cap is per call, not per
   block or transaction: callers can loop and spend the available bucket. It does not bound a
   sandwich to 1 ETH. The reference floor does not guarantee a quote close to spot during a crash.
   A holder can provide PANIC-only liquidity for buybacks to consume and withdraw paired proceeds;
   liquidity operations carry no hook sell tax. No aggregate rate limit or spot floor is promised.

If the oracle budget address is a contract that rejects ETH, `claimOracleFund()` reverts and the
bucket keeps accruing; swaps are never affected because fees are claims, not transfers. The address
cannot be changed, so choose it carefully.

Immediate donation adds PoolManager accounting work to taxed swaps. Gas should be remeasured for
the target chain; old pre-revision gas estimates do not cover this path.

## Tests

`forge test` runs unit, integration on a real `PoolManager`, and fuzz tests. Behaviours and their
evidence (including the explicitly unresolved requirement):

| Requirement | Test |
| --- | --- |
| tiers switch exactly at 5%, 15%, 30% | `test_sellTiersSwitchExactlyAt5_15_30Percent`, `test_buyTierSwitchesExactlyAt5Percent`, `test_drawdownIsExactAtThresholds`, `test_sellTiersSwitchAtExactBoundaryPrices` |
| a sell from not-down to 20% down pays 20% | `test_sellMovingPriceFromNotDownTo20PercentDownPays20Percent` (+ ERC-20 pair variants) |
| general anti-splitting | **Unresolved specification conflict**; `test_flatStartSplittingCounterexampleUnderTheSpecifiedTiers` reproduces lower split tax. Within-tier tests do not prove this property. |
| a buy and a sell in the same block cannot move the reference | `test_buyAndSellInTheSameBlockCannotMoveTheReference`, `test_atMostOneObservationPerBlockTakenBeforeTheFirstSwap` |
| down but flat for 1 hour: panic tier no longer applies | `test_afterAnHourDownButFlatThePanicTierNoLongerApplies`, `test_referenceIsTheOneHourMeanTick` |
| fee split sums to exactly 100% | `test_feeSplitSumsToExactly100Percent`, `test_everyFeeIsSplitExactlyWithNoDust`, `testFuzz_splitOfAnyFeeSumsExactly` |
| hook fee capped at 30% | `testFuzz_hookFeeNeverExceeds30Percent`, `test_hookFeeCappedAt30PercentEvenInACrash` |
| buyback reverts > 2% above reference; all PANIC to dEaD | `test_buybackRevertsWhenPriceIsMoreThan2PercentAboveReference`, `test_buybackRevertsWithTheSpecificErrorWhenTooExpensive`, `test_buybackAndBurnSendsEveryTokenBoughtToTheDeadAddress` |
| initialization and unauthorized callbacks | `PanicHook.Init.t.sol` |
| token supply and transfer | `PanicMonkeys.t.sol` |
| fee-bearing buy on a fresh manager, tokens-only pool | `test_feeBearingBuyWorksOnAFreshManagerWhosePoolHoldsTokensOnly` |
| limited buys never pay fees on unfilled input | `test_partialDipBuyRevertsWithoutChargingOrMovingThePool`, `test_exactOutputLimitedDipBuyChargesOnlyRealisedInput`, `testFuzz_fullDipBuyFeeIsAtMostOnePercentOfPoolInput` |
| historical LP fees cannot be captured by later JIT liquidity | `test_jitPositionCannotCaptureAnEarlierSwapsDonation`, `test_donationReachesTheLiquidityProviderOnWithdrawal` |
| buyback dip fee and dust floor | `test_buybackCannotMoveTheReferenceAndPaysTheDipFee`, `test_partialBuybackReallocatesFeeOnlyOnRealisedInput`, `test_dustBuybackRevertsAndPreservesAllFunds`, `testFuzz_tinyBuybacksNeverRoundAwayTheReferenceFloor` |
| reference quote preserves precision at dust amounts | `PanicHook.PriceMath.t.sol`: exact quote in both orientations, fuzz comparison to a single division, extreme prices, overflow refusal, and atomic rollback of the 13 wei buyback returning only 11 PANIC wei against a 12 wei minimum |
| recipient that rejects ETH | `test_claimToARecipientThatRejectsEthFailsWithoutBlockingSwaps` |

Tests read no environment variables and do not depend on the caller. They pass in any order and in
parallel.

## Security notes

Checked against the `uniswap-v4-security` and `eth-security` references:

* Every enabled callback and `unlockCallback` require `msg.sender == poolManager`; the disabled
  callbacks revert. Direct calls are tested.
* No owner, pause, upgrade, `delegatecall` or `selfdestruct` (opcode scan in the tests). No
  hardcoded chain addresses other than the dead address.
* Delta accounting: fee claims are minted inside `afterSwap` for exactly the delta the PoolManager
  credits the hook, then the donated portion is burned against `donate`'s debit. Outlets burn
  what they spend; the buyback refunds unused budget and splits its internal fee from existing
  claims. Its returned `spent` includes that fee, whose 10% burn share re-enters the burn bucket.
  The `CurrencyNotSettled` check in `unlock` guards every outlet path.
* Reentrancy: the outlets run inside `poolManager.unlock`, which refuses nested unlocks, so a
  recipient cannot re-enter a swap or another outlet mid-flight. Buckets are zeroed before the
  external call.
* Oracle safety: the reference is a TWAP, never spot; observations are pre-swap; the window is a
  full hour from launch. The attack that remains is the one every TWAP has: holding the price down
  for an hour makes "down" the new normal, which is the brief's intended decay.
* Integration limitations: exact-output sells and fee-bearing partial exact-input buys are refused.
  The donation fallback retains JIT exposure; buybacks have a reference floor and a per-call cap,
  with no block cap or spot floor. General anti-splitting remains unresolved, as explained above.
* Revision checks: `forge build`, `forge test` with 256 runs per fuzz test, and `forge fmt --check`.
  The supplied split proof was copied unchanged to scratch and reproduces the figures above.
  It remains disputed because its general anti-splitting assertion conflicts with the exact
  per-sell schedule. No sell economics were changed. The advisory dust reproduction initially
  accepted 11 PANIC wei where the exact reference quote required 12; it now reverts with
  `BuybackBelowReference(11, 12)`. Exact-output sell rejection was reproduced and retained as
  the documented integration limitation. Every finding is answered in `.imd-responses.json`.
  Scratch proof copies are removed before the deliverable's full test run; pinned inputs are unchanged.
  Slither/Mythril, chain forks, and deployment transactions were not run in this revision.
  Independent review must resolve the disputed criteria before release.

## What the brief asked that the token does not do

The brief puts every trading rule in the hook, and the token is the standard launch token: fixed
supply, 18 decimals, no fees, no admin. Nothing in the brief required token-side behaviour beyond
name and symbol.
