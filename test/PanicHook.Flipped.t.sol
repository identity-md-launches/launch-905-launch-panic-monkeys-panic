// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PanicTestBase} from "./utils/PanicTestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The same rules on an ERC-20 pair, in both pool orientations (PANIC as currency0 and as currency1).
abstract contract PanicHookErc20Base is PanicTestBase {
    function _pairedToken() internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(paired));
    }

    function test_orientationIsDetected() public view {
        assertEq(hook.panicIsCurrency0(), panicIs0);
        assertEq(Currency.unwrap(hook.pairedCurrency()), Currency.unwrap(paired));
    }

    function test_sellTo20PercentDownPays20PercentInThePairedToken() public {
        uint256 before = _feesWithDonations();
        uint256 pairedBefore = _pairedToken().balanceOf(address(this));
        BalanceDelta d = _sellToDrawdown(2000);
        uint256 fee = _feesWithDonations() - before;
        uint256 dd = hook.currentDrawdownBps();
        assertGe(dd, 2000);
        assertLt(dd, 2010);
        uint256 gross = _grossOutput(d, fee);
        assertEq(fee, gross * 2000 / 10_000);
        assertEq(
            _pairedToken().balanceOf(address(this)) - pairedBefore, gross - fee, "received 80% in the paired token"
        );
        assertEq(_claimBalance(), hook.totalAccruedFees(), "claims in the paired token");
    }

    function test_buyWhileDownPays1PercentOfPairedInput() public {
        _sellToDrawdown(800);
        uint256 before = _feesWithDonations();
        uint256 pairedBefore = _pairedToken().balanceOf(address(this));
        _buyPanic(10 ether);
        assertEq(_feesWithDonations() - before, uint256(10 ether) * 100 / 10_100);
        assertEq(pairedBefore - _pairedToken().balanceOf(address(this)), 10 ether);
    }

    function test_buyWhileNotDownIsFree() public {
        uint256 before = _feesWithDonations();
        _buyPanic(10 ether);
        assertEq(_feesWithDonations(), before);
    }

    function test_outletsWorkWithAnErc20PairedToken() public {
        _sellToDrawdown(2000);
        uint256 oracleAmount = hook.oracleFundBucket();
        uint256 burnAmount = hook.burnBucket();
        uint256 deadBefore = panic.balanceOf(DEAD);

        hook.claimOracleFund();
        assertEq(_pairedToken().balanceOf(oracleFund), oracleAmount);

        assertEq(hook.donationBucket(), 0);
        assertGt(hook.totalDonated(), 0);
        _nextBlock(3600); // drain at a flat price; the dip buy fee is tested separately

        uint256 totalSpent;
        uint256 totalBurned;
        while (hook.burnBucket() > 0) {
            (uint256 spent, uint256 burned) = hook.buybackAndBurn();
            assertLe(spent, hook.MAX_BUYBACK_SPEND());
            totalSpent += spent;
            totalBurned += burned;
        }
        assertEq(totalSpent, burnAmount);
        assertEq(panic.balanceOf(DEAD) - deadBefore, totalBurned);
        assertGt(totalBurned, 0);
        assertEq(hook.totalAccruedFees(), 0);
        assertEq(_claimBalance(), 0);
    }

    function test_referenceUnmovedByTradesInTheBlock() public {
        _nextBlock(30);
        uint160 ref = hook.referenceSqrtPriceX96();
        _buyPanic(100 ether);
        _sellToDrawdown(2500);
        assertEq(hook.referenceSqrtPriceX96(), ref);
    }
}

contract PanicHookPanicAsCurrency0Test is PanicHookErc20Base {
    function setUp() public {
        _setUpErc20Pool(true, SQRT_PRICE_1_1);
        _fundAndApprove();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
        assertTrue(panicIs0);
    }
}

contract PanicHookPanicAsCurrency1Erc20Test is PanicHookErc20Base {
    function setUp() public {
        _setUpErc20Pool(false, SQRT_PRICE_1_1);
        _fundAndApprove();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
        assertFalse(panicIs0);
    }
}
