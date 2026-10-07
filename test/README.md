# PANIC test coverage

Run `forge build` and `forge test`. Dependencies are already vendored; these tests require
no RPC, environment variables, FFI, or additional installations. Local verification can keep
generated artifacts inside scratch with `--out test/scratch/out --cache-path test/scratch/cache`.

The existing integration suites cover exact 5%, 15%, and 30% boundaries, the sell that crosses
from flat to 20% down, buy fees based on pre-swap prices, same-block reference isolation,
one-hour recovery, the 30% fee cap, claims, donations, and buyback routing and failure paths.
They deploy the actual vendored Uniswap v4 PoolManager and mine the production hook address.
This is offline integration coverage, not a rehearsal against a live chain deployment.

`PanicHook.Invariant.t.sol` adds three campaigns: native pairing, PANIC as currency0, and PANIC
as currency1. Each runs 256 sequences of 64 randomly ordered actions, with unexpected reverts
treated as failures. Three funded traders buy, sell, transfer PANIC, advance blocks/time, and
call the permissionless fee outlets. Inputs include zero outlet budgets and one-wei trades.
The deterministic handler test exercises both funded operations and rejection paths.

The handler derives taxes from actual wallet movements and the PoolManager's swap event,
then maintains an independent allocation ledger. The invariant checks claims against all
three buckets, lifetime fee conservation including buyback fees, the fixed claim recipient,
delivery of every bought token to the dead address, fixed token supply, and settled manager
deltas. A separate spot-price timeline is integrated over one hour to check the reference;
it never reads the hook's observation array. Full-range liquidity is kept in these campaigns;
deferred donations and zero-liquidity failure/recovery are exercised by the existing bucket suite.

`PanicMonkeys.Properties.t.sol` adds a separate token campaign over transfers, approval
replacement/revocation, and delegated transfers. An independent balance/allowance ledger checks
successful calls and rollback after expected failures, including self-transfers, full balances,
zero amounts, and unlimited approvals. Its finite-allowance rollback property runs 1,000 cases.
The bucket split fuzz test now performs real swaps rather than asserting an arithmetic identity.

Two required properties fail on the supplied implementation and are reported in
`.imd-findings.json`, with complete standalone Foundry proofs:

- Ten slices of a cross-tier sell pay substantially less tax than the unsplit sell. The old
  test asserting that lower tax was correct has been removed. The within-tier rounding tests
  are narrower checks and do not establish the general anti-splitting requirement.
- Small buybacks can accept less than the 98% reference floor because the reference conversion
  truncates twice. The independent output-floor property found this during invariant testing.
  The failing property is preserved in the report; the passing accounting invariant makes no
  claim that this price-floor defect is fixed and still exercises small buyback amounts.

Proofs were run under `test/scratch/` with `forge test --match-path`, observed to fail on the
stated assertions, and embedded in the report. Their failing test sources are not part of the
default passing suite. Production contracts and build/dependency configuration are unchanged.
