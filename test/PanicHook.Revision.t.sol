// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PanicHook} from "../src/PanicHook.sol";
import {PanicTestBase} from "./utils/PanicTestBase.sol";

contract PanicHookRevisionTest is PanicTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpNativePool(SQRT_PRICE_1_1);
        _fundAndApprove();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
    }

    function test_partialDipBuyRevertsWithoutChargingOrMovingThePool() public {
        _sellToDrawdown(1000);
        uint160 price = _sqrtPrice();
        uint256 feesBefore = _feesWithDonations();
        uint256 balanceBefore = address(this).balance;
        uint256 panicBefore = panic.balanceOf(address(this));
        uint160 ref = hook.referenceSqrtPriceX96();
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.afterSwap.selector, abi.encodeWithSelector(PanicHook.PartialExactInputBuyNotSupported.selector)
            )
        );
        _swap(true, -100 ether, price - price / 10_000);
        assertEq(_feesWithDonations(), feesBefore);
        assertEq(address(this).balance, balanceBefore);
        assertEq(panic.balanceOf(address(this)), panicBefore);
        assertEq(_sqrtPrice(), price);
        assertEq(hook.referenceSqrtPriceX96(), ref);
        assertEq(_claimBalance(), hook.totalAccruedFees());
    }

    function test_exactOutputLimitedDipBuyChargesOnlyRealisedInput() public {
        _sellToDrawdown(1000);
        uint160 price = _sqrtPrice();
        uint256 before = _feesWithDonations();
        BalanceDelta d = _swap(true, 100 ether, price - price / 10_000);
        uint256 fee = _feesWithDonations() - before;
        uint256 netInput = uint256(-int256(d.amount0())) - fee;
        assertGt(d.amount1(), 0);
        assertLt(d.amount1(), 100 ether);
        assertEq(fee, netInput / 100);
        assertEq(_claimBalance(), hook.totalAccruedFees());
    }

    function test_partialBuyWithoutHookFeeStillWorks() public {
        uint160 price = _sqrtPrice();
        BalanceDelta d = _swap(true, -100 ether, price - price / 10_000);
        assertLt(uint256(-int256(d.amount0())), 100 ether);
        assertGt(d.amount1(), 0);
        assertEq(_feesWithDonations(), 0);
    }

    function testFuzz_fullDipBuyFeeIsAtMostOnePercentOfPoolInput(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 100, 100 ether);
        _sellToDrawdown(1000);
        uint256 before = _feesWithDonations();
        BalanceDelta d = _buyPanic(amount);
        uint256 fee = _feesWithDonations() - before;
        uint256 net = uint256(-int256(d.amount0())) - fee;
        assertEq(uint256(-int256(d.amount0())), amount);
        assertLe(fee * 10_000, net * 100);
        assertApproxEqAbs(fee, net / 100, 1);
        assertEq(_claimBalance(), hook.totalAccruedFees());
    }

    function test_jitPositionCannotCaptureAnEarlierSwapsDonation() public {
        _sellToDrawdown(2000);
        uint256 donation = hook.totalDonated();
        assertGt(donation, 0);
        assertEq(hook.donationBucket(), 0, "already paid to resident LPs");
        address attacker = makeAddr("jitAttacker");
        vm.deal(attacker, 1e27);
        panic.transfer(attacker, 1e26);
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
        int24 lower = tick / TICK_SPACING * TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) lower -= TICK_SPACING;
        uint256 ethBefore = attacker.balance;
        uint256 panicBefore = panic.balanceOf(attacker);
        vm.startPrank(attacker);
        panic.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: 1e26}(key, ModifyLiquidityParams(lower, lower + TICK_SPACING, 1e26, 0), "");
        vm.expectRevert(PanicHook.NothingToDonate.selector);
        hook.donateToLiquidityProviders();
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, lower + TICK_SPACING, -1e26, 0), "");
        vm.stopPrank();
        assertLe(attacker.balance, ethBefore, "no capture");
        assertLe(panic.balanceOf(attacker), panicBefore);
        BalanceDelta collected = lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 0, 0),
            ""
        );
        assertApproxEqAbs(uint256(int256(collected.amount0())), donation, 1, "resident LP receives donation");
    }

    function test_dustBuybackRevertsAndPreservesAllFunds() public {
        _sellPanic(100 ether);
        _nextBlock(3600);
        uint256 bucket = hook.burnBucket();
        uint256 claims = _claimBalance();
        uint160 price = _sqrtPrice();
        uint256 deadBefore = panic.balanceOf(DEAD);
        vm.expectRevert(abi.encodeWithSelector(PanicHook.BuybackBelowReference.selector, 0, 1));
        hook.buybackAndBurn(1);
        assertEq(hook.burnBucket(), bucket);
        assertEq(_claimBalance(), claims);
        assertEq(_sqrtPrice(), price);
        assertEq(panic.balanceOf(DEAD), deadBefore);
    }

    function testFuzz_tinyBuybacksNeverRoundAwayTheReferenceFloor(uint16 rawSpend) public {
        _sellPanic(100 ether);
        _nextBlock(3600);
        uint256 spend = bound(rawSpend, 1, 500);
        uint256 bucket = hook.burnBucket();
        uint256 deadBefore = panic.balanceOf(DEAD);
        (bool ok, bytes memory result) = address(hook).call(abi.encodeWithSignature("buybackAndBurn(uint256)", spend));
        if (ok) {
            (uint256 spent, uint256 burned) = abi.decode(result, (uint256, uint256));
            uint256 implied = hook.pairedToPanicAtSqrtPrice(spent, hook.referenceSqrtPriceX96(), false);
            assertGt(burned, 0);
            assertGe(burned * 10_000, implied * 9800);
            assertEq(panic.balanceOf(DEAD) - deadBefore, burned);
        } else {
            assertEq(bytes4(result), PanicHook.BuybackBelowReference.selector);
            assertEq(hook.burnBucket(), bucket);
            assertEq(panic.balanceOf(DEAD), deadBefore);
        }
        assertEq(_claimBalance(), hook.totalAccruedFees());
    }

    function test_partialBuybackReallocatesFeeOnlyOnRealisedInput() public {
        _sellToDrawdown(2000);
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
        _addLiquidity(2200, 2300, 1e12);
        uint256 oracleBefore = hook.oracleFundBucket();
        uint256 donatedBefore = hook.totalDonated() + hook.donationBucket();
        uint256 burnBefore = hook.burnBucket();
        (uint256 spent, uint256 burned) = hook.buybackAndBurn();
        assertLt(spent, 1 ether);
        assertGt(burned, 0);
        uint256 fee = hook.oracleFundBucket() - oracleBefore + hook.totalDonated() + hook.donationBucket()
            - donatedBefore + hook.burnBucket() + spent - burnBefore;
        assertEq(fee, (spent - fee) / 100);
        assertEq(_claimBalance(), hook.totalAccruedFees());
    }

    function test_perCallCapAllowsMultipleBuybacksInOneBlock() public {
        _sellToDrawdown(3000);
        uint256 atBlock = block.number;
        uint256 totalSpent;
        for (uint256 i; i < 3; i++) {
            (uint256 spent,) = hook.buybackAndBurn();
            assertLe(spent, hook.MAX_BUYBACK_SPEND());
            totalSpent += spent;
        }
        assertEq(block.number, atBlock);
        assertEq(totalSpent, 3 ether, "the cap is explicitly per call");
    }

    function test_flatStartSplittingCounterexampleUnderTheSpecifiedTiers() public {
        uint256 snapshot = vm.snapshotState();
        _sellPanic(1200 ether);
        uint256 singleFee = _feesWithDonations();
        uint256 drawdown = hook.currentDrawdownBps();
        assertGe(drawdown, 1500);
        assertLt(drawdown, 3000);
        assertTrue(vm.revertToState(snapshot));
        for (uint256 i; i < 10; i++) {
            uint256 before = _feesWithDonations();
            BalanceDelta d = _sellPanic(120 ether);
            uint256 fee = _feesWithDonations() - before;
            assertEq(fee, _grossOutput(d, fee) * hook.sellFeeBps(hook.currentDrawdownBps()) / 10_000);
        }
        assertApproxEqAbs(hook.currentDrawdownBps(), drawdown, 1);
        assertLt(_feesWithDonations(), singleFee, "conflicting anti-split requirement remains unresolved");
    }

    function test_referenceUsesDocumentedWholeTickRounding() public {
        _nextBlock(1800);
        _sellPanicToPrice(TickMath.getSqrtPriceAtTick(1));
        _nextBlock(1800);
        assertEq(hook.referenceTick(), 0);
        assertEq(hook.referenceSqrtPriceX96(), SQRT_PRICE_1_1);
        uint160 fractionalApprox = SQRT_PRICE_1_1 + (TickMath.getSqrtPriceAtTick(1) - SQRT_PRICE_1_1) / 2;
        uint160 boundary = _sqrtPriceAtDrawdown(SQRT_PRICE_1_1, 500);
        assertEq(hook.drawdownBps(boundary, hook.referenceSqrtPriceX96(), false), 500);
        assertEq(hook.drawdownBps(boundary, fractionalApprox, false), 499);
    }
}
