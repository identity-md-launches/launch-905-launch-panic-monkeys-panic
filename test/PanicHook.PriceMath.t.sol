// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PanicHook} from "../src/PanicHook.sol";
import {PanicTestBase} from "./utils/PanicTestBase.sol";

contract PanicHookPriceMathTest is PanicTestBase {
    function setUp() public {
        _setUpNativePool(SQRT_PRICE_1_1);
        _fundAndApprove();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
    }

    function test_dustBuybackUsesExactReferenceQuoteAndRevertsAtomically() public {
        vm.roll(START_BLOCK + 1);
        vm.warp(START_TIME + 1);
        _sellPanic(6945);
        _buyPanic(200 ether);
        vm.roll(START_BLOCK + 2);
        vm.warp(START_TIME + 4882);

        uint160 ref = hook.referenceSqrtPriceX96();
        uint256 exactImplied = 13 * uint256(ref) * uint256(ref) / (1 << 192);
        assertEq(hook.burnBucket(), 13);
        assertEq(exactImplied, 12);
        assertEq(hook.pairedToPanicAtSqrtPrice(13, ref, false), exactImplied);
        uint256 claimsBefore = _claimBalance();
        uint256 feesBefore = hook.totalAccruedFees();
        uint256 donatedBefore = hook.totalDonated();
        uint256 deadBefore = panic.balanceOf(DEAD);
        uint256 observationsBefore = hook.observationCount();
        uint160 priceBefore = _sqrtPrice();

        vm.expectRevert(abi.encodeWithSelector(PanicHook.BuybackBelowReference.selector, 11, 12));
        hook.buybackAndBurn(13);

        assertEq(hook.burnBucket(), 13);
        assertEq(_claimBalance(), claimsBefore);
        assertEq(hook.totalAccruedFees(), feesBefore);
        assertEq(hook.totalDonated(), donatedBefore);
        assertEq(panic.balanceOf(DEAD), deadBefore);
        assertEq(hook.observationCount(), observationsBefore);
        assertEq(_sqrtPrice(), priceBefore);
    }

    function test_referenceQuoteRetainsRemainderInBothOrientations() public view {
        // floor(13 * (3/4)^2) = 7; flooring between multiplications used to return 6.
        assertEq(hook.pairedToPanicAtSqrtPrice(13, SQRT_PRICE_1_1 * 3 / 4, false), 7);
        // floor(7 / (3/2)^2) = 3; flooring between divisions used to return 2.
        assertEq(hook.pairedToPanicAtSqrtPrice(7, SQRT_PRICE_1_1 * 3 / 2, true), 3);
    }

    function testFuzz_referenceQuoteMatchesSingleDivision(uint64 amount, uint128 rawSqrt) public view {
        uint256 sqrt = bound(rawSqrt, TickMath.MIN_SQRT_PRICE, type(uint128).max);
        uint256 square = sqrt * sqrt;
        // Squaring fits in this domain, so the independent expected value needs only one division.
        assertEq(hook.pairedToPanicAtSqrtPrice(amount, uint160(sqrt), false), FullMath.mulDiv(amount, square, 1 << 192));
        assertEq(hook.pairedToPanicAtSqrtPrice(amount, uint160(sqrt), true), FullMath.mulDiv(amount, 1 << 192, square));
    }

    function test_referenceQuoteAtExtremeSqrtPrices() public view {
        // Expected values from arbitrary-precision integer division, including a 320-bit square.
        assertEq(
            hook.pairedToPanicAtSqrtPrice(1 ether, TickMath.MAX_SQRT_PRICE - 1, false),
            340256786836388094070642339899681172762184831912254825631
        );
        assertEq(hook.pairedToPanicAtSqrtPrice(1 ether, TickMath.MAX_SQRT_PRICE - 1, true), 0);
        assertEq(
            hook.pairedToPanicAtSqrtPrice(1 ether, TickMath.MIN_SQRT_PRICE, true),
            340256786698763678858396856460488307819979090561464864775
        );
        assertEq(hook.pairedToPanicAtSqrtPrice(1 ether, TickMath.MIN_SQRT_PRICE, false), 0);
    }

    function test_referenceQuoteHandlesZeroAndMaximumAtParity() public view {
        for (uint256 i; i < 2; i++) {
            bool is0 = i == 0;
            assertEq(hook.pairedToPanicAtSqrtPrice(0, SQRT_PRICE_1_1, is0), 0);
            assertEq(hook.pairedToPanicAtSqrtPrice(type(uint256).max, SQRT_PRICE_1_1, is0), type(uint256).max);
        }
    }

    function test_referenceQuoteRevertsIfResultOverflows() public {
        vm.expectRevert();
        hook.pairedToPanicAtSqrtPrice(type(uint256).max, SQRT_PRICE_1_1 * 2, false);
        vm.expectRevert();
        hook.pairedToPanicAtSqrtPrice(type(uint256).max, SQRT_PRICE_1_1 / 2, true);
    }
}
