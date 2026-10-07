// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PanicHook} from "../src/PanicHook.sol";
import {PanicTestBase} from "./utils/PanicTestBase.sol";

/// @notice The 60 / 30 / 10 fee split and the three permissionless outlets: oracle fund claim, LP donation
/// and buyback-and-burn.
contract PanicHookBucketsTest is PanicTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpNativePool(SQRT_PRICE_1_1);
        _fundAndApprove();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
    }

    function _assertBucketsBackedByClaims() internal view {
        assertEq(
            _claimBalance(),
            hook.oracleFundBucket() + hook.donationBucket() + hook.burnBucket(),
            "claims held equal the sum of the buckets"
        );
    }

    // ---------------------------------------------------------------- split

    function test_feeSplitSumsToExactly100Percent() public view {
        assertEq(hook.ORACLE_SHARE_BPS() + hook.LP_SHARE_BPS() + hook.BURN_SHARE_BPS(), 10_000);
        assertEq(hook.ORACLE_SHARE_BPS(), 6000);
        assertEq(hook.LP_SHARE_BPS(), 3000);
        assertEq(hook.BURN_SHARE_BPS(), 1000);
    }

    function test_everyFeeIsSplitExactlyWithNoDust() public {
        uint256 before = _feesWithDonations();
        _sellToDrawdown(2000);
        uint256 fee = _feesWithDonations() - before;
        assertGt(fee, 0);
        assertEq(hook.donationBucket(), 0);
        assertEq(hook.totalDonated(), fee * 3000 / 10_000);
        assertEq(hook.burnBucket(), fee * 1000 / 10_000);
        assertEq(hook.oracleFundBucket(), fee - hook.totalDonated() - hook.burnBucket());
        assertEq(_feesWithDonations(), fee, "sums to the fee exactly");
        _assertBucketsBackedByClaims();

        // Odd amounts: the integer remainder lands in the oracle fund, nothing is lost.
        _sellPanic(333333333333333337);
        _buyPanic(777777777777777771);
        _assertBucketsBackedByClaims();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitOfAnyFeeSumsExactly(uint128 amountSeed) public {
        _sellPanic(bound(amountSeed, 1, 2000 ether));
        uint256 fee = _feesWithDonations();
        uint256 lp = hook.totalDonated() + hook.donationBucket();
        uint256 burn = hook.burnBucket();
        assertEq(lp, fee * 3 / 10);
        assertEq(burn, fee / 10);
        assertEq(hook.oracleFundBucket(), fee - lp - burn);
        assertEq(_claimBalance() + hook.totalDonated(), fee, "no unbacked allocations or lost claims");
        assertEq(address(hook).balance, 0);
    }

    // ---------------------------------------------------------------- oracle fund

    function test_claimOracleFundIsPermissionlessAndPaysOnlyTheOracleAddress() public {
        _sellToDrawdown(2000);
        uint256 amount = hook.oracleFundBucket();
        assertGt(amount, 0);
        uint256 claimsBefore = _claimBalance();

        vm.deal(trader, 0);
        vm.prank(trader);
        uint256 claimed = hook.claimOracleFund();

        assertEq(claimed, amount);
        assertEq(oracleFund.balance, amount, "oracle fund received the ETH");
        assertEq(trader.balance, 0, "the caller receives nothing");
        assertEq(hook.oracleFundBucket(), 0);
        assertEq(_claimBalance(), claimsBefore - amount);
        _assertBucketsBackedByClaims();

        vm.expectRevert(PanicHook.NothingToClaim.selector);
        hook.claimOracleFund();
    }

    function test_claimToARecipientThatRejectsEthFailsWithoutBlockingSwaps() public {
        RejectsEth rejecting = new RejectsEth();
        PanicHook other = _deployHook(IPoolManager(address(manager)), address(panic), address(rejecting));
        // Give that hook its own pool and liquidity.
        key.hooks = IHooks(address(other));
        key.fee = 3_000;
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
        hook = other;

        _sellToDrawdown(2000); // swaps work fine: fees are claims, not transfers
        _buyPanic(1 ether);
        assertGt(hook.oracleFundBucket(), 0);

        vm.expectRevert();
        hook.claimOracleFund();
        assertGt(hook.oracleFundBucket(), 0, "the bucket is kept");

        _sellPanic(1 ether); // and trading still works afterwards
    }

    // ---------------------------------------------------------------- donation

    function test_swapDonatesImmediatelyToInRangeLiquidityProviders() public {
        (uint256 growth0Before,) = IPoolManager(address(manager)).getFeeGrowthGlobals(poolId);
        uint128 liquidity = IPoolManager(address(manager)).getLiquidity(poolId);
        _sellToDrawdown(2000);
        uint256 amount = hook.totalDonated();
        assertGt(amount, 0);
        (uint256 growth0After,) = IPoolManager(address(manager)).getFeeGrowthGlobals(poolId);
        assertEq(growth0After - growth0Before, (amount << 128) / liquidity, "fee growth credited during swap");
        assertEq(hook.donationBucket(), 0);
        _assertBucketsBackedByClaims();
        vm.expectRevert(PanicHook.NothingToDonate.selector);
        hook.donateToLiquidityProviders();
    }

    function test_donationReachesTheLiquidityProviderOnWithdrawal() public {
        _sellToDrawdown(1000);
        uint256 donation = hook.totalDonated();

        // Removing a zero amount of liquidity collects fees owed to the position.
        uint256 ethBefore = address(this).balance;
        BalanceDelta d = lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 0,
                salt: 0
            }),
            ""
        );
        uint256 collected = uint256(int256(d.amount0()));
        assertEq(address(this).balance - ethBefore, collected);
        // LP fees on a sell accrue in PANIC (the input), so the ETH side is the donation alone, less the
        // one wei the fee-growth fixed point may round away.
        assertGe(collected + 1, donation, "the LP collected the donation");
        assertLe(collected, donation);
    }

    function test_donateRevertsWhileNoLiquidityIsInRangeAndKeepsTheBucket() public {
        // Move all liquidity into a finite range, then sell through its upper boundary.
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING),
                TickMath.maxUsableTick(TICK_SPACING),
                -int256(uint256(FULL_RANGE_LIQUIDITY)),
                0
            ),
            ""
        );
        _addLiquidity(-1000, 1000, FULL_RANGE_LIQUIDITY);
        _sellPanicToPrice(TickMath.getSqrtPriceAtTick(1100));
        assertEq(IPoolManager(address(manager)).getLiquidity(poolId), 0);
        uint256 amount = hook.donationBucket();
        assertGt(amount, 0, "only unreceivable donations wait");
        vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
        hook.donateToLiquidityProviders();
        assertEq(hook.donationBucket(), amount, "bucket untouched");
        _assertBucketsBackedByClaims();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
        uint256 claimsBefore = _claimBalance();
        vm.prank(trader);
        assertEq(hook.donateToLiquidityProviders(), amount);
        assertEq(hook.donationBucket(), 0);
        assertEq(_claimBalance(), claimsBefore - amount);
        _assertBucketsBackedByClaims();
    }

    // ---------------------------------------------------------------- buyback and burn

    function test_buybackAndBurnSendsEveryTokenBoughtToTheDeadAddress() public {
        _sellToDrawdown(2000);
        uint256 bucket = hook.burnBucket();
        assertGt(bucket, hook.MAX_BUYBACK_SPEND(), "a 20% crash fills the bucket past one call's cap");
        uint256 deadBefore = panic.balanceOf(DEAD);
        uint256 claimsBefore = _claimBalance();

        vm.prank(trader);
        (uint256 spent, uint256 burned) = hook.buybackAndBurn();

        assertEq(spent, hook.MAX_BUYBACK_SPEND(), "spent the cap");
        assertGt(burned, 0);
        assertEq(panic.balanceOf(DEAD) - deadBefore, burned, "all bought PANIC ends at 0x...dEaD");
        assertEq(panic.balanceOf(address(hook)), 0);
        assertEq(panic.balanceOf(trader), 0, "the caller receives nothing");
        assertEq(hook.burnBucket(), bucket - spent + (spent * 100 / 10_100) / 10);
        uint256 internalFee = spent * 100 / 10_100;
        assertEq(_claimBalance(), claimsBefore - spent + internalFee - internalFee * 3000 / 10_000);
        _assertBucketsBackedByClaims();
        // 20% down, so the buy returned far more than the reference implied.
        uint256 implied = hook.pairedToPanicAtSqrtPrice(spent, hook.referenceSqrtPriceX96(), false);
        assertGt(burned, implied * 9800 / 10_000);
        assertGt(burned, implied, "cheaper than the reference while the price is down");

        // Keep going until the bucket is empty: everything bought lands at the dead address.
        _nextBlock(3600); // no dip fee while draining the remainder at the now-flat price
        uint256 remaining = hook.burnBucket();
        uint256 totalSpent;
        uint256 totalBurned = burned;
        while (hook.burnBucket() > 0) {
            (spent, burned) = hook.buybackAndBurn();
            totalSpent += spent;
            totalBurned += burned;
        }
        assertEq(totalSpent, remaining);
        assertEq(panic.balanceOf(DEAD) - deadBefore, totalBurned);
        assertEq(panic.balanceOf(address(hook)), 0);
        _assertBucketsBackedByClaims();
    }

    function test_smallBucketIsSpentInOneCall() public {
        _sellPanic(100 ether); // base tier: a small bucket well under the cap
        uint256 bucket = hook.burnBucket();
        assertGt(bucket, 0);
        assertLt(bucket, hook.MAX_BUYBACK_SPEND());
        uint256 deadBefore = panic.balanceOf(DEAD);
        (uint256 spent, uint256 burned) = hook.buybackAndBurn();
        assertEq(spent, bucket);
        assertEq(hook.burnBucket(), 0);
        assertEq(panic.balanceOf(DEAD) - deadBefore, burned);
        _assertBucketsBackedByClaims();
    }

    function test_buybackSpendsAtMostTheCapPerCall() public {
        // Crash hard so the burn bucket exceeds 1 ETH.
        _sellToDrawdown(9000);
        uint256 bucket = hook.burnBucket();
        assertGt(bucket, hook.MAX_BUYBACK_SPEND());

        (uint256 spent,) = hook.buybackAndBurn();
        assertEq(spent, hook.MAX_BUYBACK_SPEND(), "capped");
        assertEq(hook.burnBucket(), bucket - spent + (spent * 100 / 10_100) / 10, "remainder plus fee burn share");
        uint256 remaining = hook.burnBucket();

        (spent,) = hook.buybackAndBurn(0.25 ether);
        assertEq(spent, 0.25 ether, "a caller may spend less than the cap");
        assertEq(hook.burnBucket(), remaining - spent + (spent * 100 / 10_100) / 10);

        (spent,) = hook.buybackAndBurn(type(uint256).max);
        assertEq(spent, hook.MAX_BUYBACK_SPEND(), "but never more");
        _assertBucketsBackedByClaims();
    }

    function test_buybackRevertsWhenPriceIsMoreThan2PercentAboveReference() public {
        _sellPanic(100 ether); // accrue some burn budget while barely moving the price
        assertGt(hook.burnBucket(), 0);

        _nextBlock(12);
        _buyPanic(600 ether); // pushes the live price several percent above the reference
        _nextBlock(1);
        uint160 ref = hook.referenceSqrtPriceX96();
        uint160 live = _sqrtPrice();
        // PANIC is currency1: a lower price1/0 is a higher PANIC price. Check it is > 2% above.
        uint256 ratioE4 = uint256(ref) * uint256(ref) / uint256(live) * 10_000 / uint256(live);
        assertGt(ratioE4, 10_200, "live PANIC price more than 2% above the reference");

        uint256 bucket = hook.burnBucket();
        vm.expectRevert();
        hook.buybackAndBurn();
        assertEq(hook.burnBucket(), bucket, "nothing spent");
        _assertBucketsBackedByClaims();
    }

    function test_buybackRevertsWithTheSpecificErrorWhenTooExpensive() public {
        _sellPanic(100 ether);
        _nextBlock(12);
        _buyPanic(600 ether);
        _nextBlock(1);
        (bool ok, bytes memory ret) = address(hook).call(abi.encodeWithSignature("buybackAndBurn()"));
        assertFalse(ok);
        assertEq(bytes4(ret), PanicHook.BuybackBelowReference.selector);
    }

    function test_buybackSucceedsAtAFlatPriceWithinTheLpFeeTolerance() public {
        _sellPanic(100 ether);
        _nextBlock(3600); // reference has caught up: live price equals reference
        assertEq(hook.currentDrawdownBps(), 0);
        (uint256 spent, uint256 burned) = hook.buybackAndBurn();
        uint256 implied = hook.pairedToPanicAtSqrtPrice(spent, hook.referenceSqrtPriceX96(), false);
        assertGe(burned * 10_000, implied * 9800, "within 2% of the reference-implied amount");
        assertLt(burned, implied, "but below it, because of the LP fee");
    }

    function test_buybackCannotMoveTheReferenceAndPaysTheDipFee() public {
        _sellToDrawdown(2000);
        _nextBlock(12);
        uint160 ref = hook.referenceSqrtPriceX96();
        uint256 feesBefore = hook.totalAccruedFees();
        uint256 burnBefore = hook.burnBucket();
        uint256 oracleBefore = hook.oracleFundBucket();
        uint256 donatedBefore = hook.totalDonated();
        (uint256 spent,) = hook.buybackAndBurn();
        uint256 fee = spent * 100 / 10_100;
        uint256 lpShare = fee * 3000 / 10_000;
        uint256 burnShare = fee * 1000 / 10_000;
        assertEq(hook.referenceSqrtPriceX96(), ref, "reference unchanged by the buyback");
        assertEq(hook.totalAccruedFees(), feesBefore - spent + fee - lpShare);
        assertEq(hook.oracleFundBucket(), oracleBefore + fee - lpShare - burnShare);
        assertEq(hook.totalDonated(), donatedBefore + lpShare);
        assertEq(hook.burnBucket(), burnBefore - spent + burnShare);
        assertEq(hook.observationCount(), 2, "buyback took this block's observation first");
        _assertBucketsBackedByClaims();
    }

    function test_buybackRevertsWhenThereIsNothingToSpend() public {
        vm.expectRevert(PanicHook.NothingToBuyBack.selector);
        hook.buybackAndBurn();
        _sellPanic(100 ether);
        hook.buybackAndBurn();
        assertEq(hook.burnBucket(), 0);
        vm.expectRevert(PanicHook.NothingToBuyBack.selector);
        hook.buybackAndBurn();
        vm.expectRevert(PanicHook.NothingToBuyBack.selector);
        hook.buybackAndBurn(1 ether);
    }

    function test_allThreeOutletsDrainEverythingLeavingNoDust() public {
        _sellToDrawdown(2000);
        _buyPanic(3 ether);
        _sellPanic(5 ether);
        assertGt(hook.totalAccruedFees(), 0);

        hook.claimOracleFund();
        assertEq(hook.donationBucket(), 0);
        _nextBlock(3600);
        while (hook.burnBucket() > 0) {
            hook.buybackAndBurn();
        }

        assertEq(hook.oracleFundBucket(), 0);
        assertEq(hook.donationBucket(), 0);
        assertEq(hook.burnBucket(), 0);
        assertEq(hook.totalAccruedFees(), 0);
        assertEq(_claimBalance(), 0, "no claims left behind");
        assertEq(address(hook).balance, 0);
        assertEq(panic.balanceOf(address(hook)), 0);
    }

    // ---------------------------------------------------------------- fresh manager, tokens-only pool

    /// @dev A launch pool is seeded with PANIC only and the manager holds no ETH. The first fee-bearing
    /// buy must not depend on the manager's ETH balance, which `take` would. Claims make it work.
    function test_feeBearingBuyWorksOnAFreshManagerWhosePoolHoldsTokensOnly() public {
        PoolManager fresh = new PoolManager(address(this));
        PanicHook h = _deployHook(IPoolManager(address(fresh)), address(panic), oracleFund);
        manager = fresh;
        hook = h;
        key.hooks = IHooks(address(h));
        poolId = key.toId();
        swapRouter = new PoolSwapTest(IPoolManager(address(fresh)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(fresh)));
        _fundAndApprove();

        // Price well above the seeded range, so the position is PANIC only.
        int24 startTick = 20_000;
        manager.initialize(key, TickMath.getSqrtPriceAtTick(startTick));
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: 0, tickUpper: startTick, liquidityDelta: int256(uint256(FULL_RANGE_LIQUIDITY)), salt: 0
            }),
            ""
        );
        assertEq(address(manager).balance, 0, "the manager holds no ETH");

        // Launch block: a buy at 0% (not down) works with no ETH in the manager.
        _buyPanic(1 ether);
        assertEq(address(manager).balance, 1 ether);

        // Next block: dump below the reference, draining most of the ETH; then a down-market buy whose
        // 1% fee exceeds what the manager holds. With claims it succeeds.
        _nextBlock(12);
        _sellToDrawdown(1000);
        uint256 managerEth = address(manager).balance;
        uint256 fee = uint256(50 ether) * 100 / 10_100;
        assertGt(fee, managerEth, "the fee is larger than the manager's whole ETH balance");
        assertGe(hook.currentDrawdownBps(), 500, "down, so the buy is fee-bearing");
        uint256 before = _feesWithDonations();
        _buyPanic(50 ether);
        assertEq(_feesWithDonations() - before, fee, "1% fee split between claims and immediate donation");
        assertEq(manager.balanceOf(address(hook), 0), hook.totalAccruedFees());

        // And the fund can be claimed now that the swapper's ETH has settled.
        uint256 oracleBefore = oracleFund.balance;
        hook.claimOracleFund();
        assertGt(oracleFund.balance, oracleBefore);
    }
}

contract RejectsEth {
    receive() external payable {
        revert("no ETH here");
    }
}
