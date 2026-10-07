// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PanicHook} from "../src/PanicHook.sol";
import {PanicTestBase} from "./utils/PanicTestBase.sol";

/// @notice Hook fee tiers, direction, caps and the anti-split behaviour, on the PANIC / native ETH pool.
contract PanicHookFeesTest is PanicTestBase {
    uint256 constant Q192 = 2 ** 192;

    function setUp() public {
        _setUpNativePool(SQRT_PRICE_1_1);
        _fundAndApprove();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
    }

    // ---------------------------------------------------------------- exact tier boundaries (pure)

    function test_sellTiersSwitchExactlyAt5_15_30Percent() public view {
        assertEq(hook.sellFeeBps(0), 200);
        assertEq(hook.sellFeeBps(499), 200);
        assertEq(hook.sellFeeBps(500), 1000);
        assertEq(hook.sellFeeBps(1499), 1000);
        assertEq(hook.sellFeeBps(1500), 2000);
        assertEq(hook.sellFeeBps(2999), 2000);
        assertEq(hook.sellFeeBps(3000), 3000);
        assertEq(hook.sellFeeBps(10_000), 3000);
    }

    function test_buyTierSwitchesExactlyAt5Percent() public view {
        assertEq(hook.buyFeeBps(0), 0);
        assertEq(hook.buyFeeBps(499), 0);
        assertEq(hook.buyFeeBps(500), 100);
        assertEq(hook.buyFeeBps(10_000), 100);
    }

    /// @dev A price exactly (1 - d) times the reference reports drawdown d; one sqrt-price unit above
    /// it reports d - 1. Checked at the three thresholds for both pool orientations.
    function test_drawdownIsExactAtThresholds() public view {
        uint256[3] memory thresholds = [uint256(500), 1500, 3000];
        for (uint256 i = 0; i < thresholds.length; i++) {
            uint256 d = thresholds[i];
            // PANIC is currency0: its price is price1/0 = sqrt^2 / 2^192, so scale the sqrt price down.
            uint160 exact0 = uint160(_sqrt(Q192 * (10_000 - d) / 10_000));
            assertEq(hook.drawdownBps(exact0, SQRT_PRICE_1_1, true), d, "exact, panic is currency0");
            assertEq(hook.drawdownBps(exact0 + 1, SQRT_PRICE_1_1, true), d - 1, "one above, panic is currency0");
            // PANIC is currency1: its price is 1 / price1/0, so scale the sqrt price up.
            uint160 exact1 = uint160(_sqrt(Q192 * 10_000 / (10_000 - d)));
            // Integer sqrt floors, so exact1 is at or just below the boundary; exact1 + 1 is past it.
            uint256 at = hook.drawdownBps(exact1, SQRT_PRICE_1_1, false);
            uint256 past = hook.drawdownBps(exact1 + 1, SQRT_PRICE_1_1, false);
            assertEq(at, d - 1, "just shy, panic is currency1");
            assertEq(past, d, "at boundary, panic is currency1");
            assertEq(hook.sellFeeBps(at) < hook.sellFeeBps(past), true, "tier flips at the boundary");
        }
    }

    function testFuzz_drawdownIsZeroAtOrAboveReferenceAndNeverAbove100Percent(uint160 price, uint160 ref) public view {
        price = uint160(bound(price, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        ref = uint160(bound(ref, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        uint256 d1 = hook.drawdownBps(price, ref, false);
        uint256 d0 = hook.drawdownBps(price, ref, true);
        assertLe(d1, 10_000);
        assertLe(d0, 10_000);
        if (price <= ref) assertEq(d1, 0, "PANIC as currency1 is at or above reference");
        if (price >= ref) assertEq(d0, 0, "PANIC as currency0 is at or above reference");
    }

    function testFuzz_hookFeeNeverExceeds30Percent(uint256 drawdown) public view {
        drawdown = bound(drawdown, 0, 20_000);
        assertLe(hook.sellFeeBps(drawdown), hook.MAX_HOOK_FEE_BPS());
        assertLe(hook.buyFeeBps(drawdown), hook.MAX_HOOK_FEE_BPS());
        assertEq(hook.MAX_HOOK_FEE_BPS(), 3000);
    }

    // ---------------------------------------------------------------- sells, judged after the sell

    function test_sellWhileNotDownPays2PercentOfOutput() public {
        uint256 before = _feesWithDonations();
        BalanceDelta d = _sellPanic(1 ether);
        uint256 fee = _feesWithDonations() - before;
        assertLt(hook.currentDrawdownBps(), 500, "a 1 PANIC sell barely moves this pool");
        uint256 gross = _grossOutput(d, fee);
        assertEq(fee, gross * 200 / 10_000, "2% of gross output");
        assertGt(fee, 0);
    }

    function test_sellEndingBetween5And15PercentDownPays10Percent() public {
        uint256 before = _feesWithDonations();
        BalanceDelta d = _sellToDrawdown(800);
        uint256 fee = _feesWithDonations() - before;
        uint256 dd = hook.currentDrawdownBps();
        assertGe(dd, 500);
        assertLt(dd, 1500);
        assertEq(fee, _grossOutput(d, fee) * 1000 / 10_000, "10% of gross output");
    }

    function test_sellMovingPriceFromNotDownTo20PercentDownPays20Percent() public {
        assertEq(hook.currentDrawdownBps(), 0, "starts not down");
        uint256 before = _feesWithDonations();
        BalanceDelta d = _sellToDrawdown(2000);
        uint256 fee = _feesWithDonations() - before;
        uint256 dd = hook.currentDrawdownBps();
        assertGe(dd, 2000);
        assertLt(dd, 2010, "landed right at 20% down");
        uint256 gross = _grossOutput(d, fee);
        assertEq(fee, gross * 2000 / 10_000, "20% of gross output");
        // The swapper kept exactly the other 80%.
        assertEq(uint256(int256(_pairedAmount(d))), gross - fee);
    }

    function test_sellEnding30PercentOrMoreDownPays30PercentAndNoMore() public {
        uint256 before = _feesWithDonations();
        BalanceDelta d = _sellToDrawdown(4500);
        uint256 fee = _feesWithDonations() - before;
        assertGe(hook.currentDrawdownBps(), 3000);
        uint256 gross = _grossOutput(d, fee);
        assertEq(fee, gross * 3000 / 10_000, "30% of gross output");
        assertLe(fee * 10_000, gross * 3000, "never above the 30% cap");
    }

    function test_hookFeeCappedAt30PercentEvenInACrash() public {
        uint256 before = _feesWithDonations();
        BalanceDelta d = _sellToDrawdown(9000);
        uint256 fee = _feesWithDonations() - before;
        assertGe(hook.currentDrawdownBps(), 9000);
        assertLe(fee * 10_000, _grossOutput(d, fee) * 3000, "capped at 30%");
    }

    /// @dev Drives the pool to the sqrt price that sits exactly on a tier boundary and checks the fee the
    /// hook charged against the tier the hook's own drawdown math reports for that price.
    function test_sellTiersSwitchAtExactBoundaryPrices() public {
        uint256[3] memory thresholds = [uint256(500), 1500, 3000];
        uint256[3] memory tierAtOrPast = [uint256(1000), 2000, 3000];
        uint256[3] memory tierBelow = [uint256(200), 1000, 2000];
        for (uint256 i = 0; i < thresholds.length; i++) {
            uint256 snap = vm.snapshotState();
            uint160 ref = hook.referenceSqrtPriceX96();
            uint160 limit = uint160(_sqrt(uint256(ref) * uint256(ref) * 10_000 / (10_000 - thresholds[i])));
            // Pick the sqrt price just shy of the boundary, then the first one at or past it.
            while (hook.drawdownBps(limit, ref, false) >= thresholds[i]) limit--;
            uint160 shy = limit;
            uint160 past = limit + 1;
            assertEq(hook.drawdownBps(shy, ref, false), thresholds[i] - 1);
            assertEq(hook.drawdownBps(past, ref, false), thresholds[i]);

            uint256 before = _feesWithDonations();
            BalanceDelta d = _sellPanicToPrice(shy);
            uint256 fee = _feesWithDonations() - before;
            assertEq(_sqrtPrice(), shy, "pool stopped exactly at the limit");
            assertEq(fee, _grossOutput(d, fee) * tierBelow[i] / 10_000, "tier just below the threshold");

            before = _feesWithDonations();
            d = _sellPanicToPrice(past);
            fee = _feesWithDonations() - before;
            assertEq(_sqrtPrice(), past, "pool stopped exactly at the boundary");
            assertEq(fee, _grossOutput(d, fee) * tierAtOrPast[i] / 10_000, "tier at the threshold");
            vm.revertToState(snap);
        }
    }

    /// @dev This example stays inside one tier. It makes no claim about crossing tiers.
    /// Pool rounding may differ by a few wei between one swap and ten, so a 10 wei allowance is kept.
    function test_partitionWithinTwentyPercentTierHasOnlyRoundingDifference() public {
        // Already 16% down: the panic tiers apply to everything that follows.
        _sellToDrawdown(1600);
        uint256 amount = 200 ether;

        uint256 snap = vm.snapshotState();
        uint256 before = _feesWithDonations();
        _sellPanic(amount);
        uint256 singleFee = _feesWithDonations() - before;
        uint256 singleDrawdown = hook.currentDrawdownBps();
        vm.revertToState(snap);

        before = _feesWithDonations();
        for (uint256 i = 0; i < 10; i++) {
            _sellPanic(amount / 10);
        }
        uint256 splitFee = _feesWithDonations() - before;

        assertGe(splitFee + 10, singleFee, "ten small sells pay at least the single sell's tax");
        assertEq(hook.currentDrawdownBps(), singleDrawdown, "same end price either way");
        assertGt(singleFee, 0);
    }

    /// @dev Same comparison deeper in: a single sell that ends past 30% versus ten slices that each end
    /// past 30%. Each slice is judged where it lands, so none can dodge the top tier.
    function test_partitionRemainingInTopTierHasOnlyRoundingDifference() public {
        _sellToDrawdown(3100);
        uint256 amount = 500 ether;

        uint256 snap = vm.snapshotState();
        uint256 before = _feesWithDonations();
        BalanceDelta d = _sellPanic(amount);
        uint256 singleFee = _feesWithDonations() - before;
        assertEq(singleFee, _grossOutput(d, singleFee) * 3000 / 10_000);
        vm.revertToState(snap);

        before = _feesWithDonations();
        for (uint256 i = 0; i < 10; i++) {
            uint256 pieceBefore = _feesWithDonations();
            BalanceDelta piece = _sellPanic(amount / 10);
            uint256 pieceFee = _feesWithDonations() - pieceBefore;
            assertEq(pieceFee, _grossOutput(piece, pieceFee) * 3000 / 10_000, "each slice pays 30%");
        }
        uint256 splitFee = _feesWithDonations() - before;
        assertGe(splitFee + 10, singleFee);
    }

    function test_exactOutputSellIsRejected() public {
        bool zeroForOne = panicIs0; // sell direction
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.beforeSwap.selector, abi.encodeWithSelector(PanicHook.ExactOutputSellNotSupported.selector)
            )
        );
        _swap(zeroForOne, int256(1 ether), _noLimit(zeroForOne));
    }

    // ---------------------------------------------------------------- buys, judged before the buy

    function test_buyWhileNotDownPaysNoHookFee() public {
        uint256 before = _feesWithDonations();
        uint256 ethBefore = address(this).balance;
        BalanceDelta d = _buyPanic(1 ether);
        assertEq(_feesWithDonations(), before, "no fee");
        assertEq(ethBefore - address(this).balance, 1 ether, "paid exactly the input");
        assertEq(_pairedAmount(d), -1 ether);
        assertGt(d.amount1(), 0, "received PANIC");
    }

    function test_buyWhileDownPays1PercentOfInput() public {
        _sellToDrawdown(1000);
        uint256 before = _feesWithDonations();
        uint256 ethBefore = address(this).balance;
        BalanceDelta d = _buyPanic(1 ether);
        uint256 fee = _feesWithDonations() - before;
        assertEq(fee, uint256(1 ether) * 100 / 10_100, "1% of pool input, within the total budget");
        assertEq(ethBefore - address(this).balance, 1 ether, "the swapper pays the full input");
        assertEq(_pairedAmount(d), -1 ether, "input includes the hook fee");
    }

    function test_buyIsJudgedOnThePriceBeforeTheBuy() public {
        // 6% down before the buy: the buy pays 1% even though it lifts the price above the reference.
        _sellToDrawdown(600);
        uint256 before = _feesWithDonations();
        _buyPanic(2_000 ether);
        assertEq(hook.currentDrawdownBps(), 0, "the buy lifted the price above the reference");
        assertEq(
            _feesWithDonations() - before,
            uint256(2_000 ether) * 100 / 10_100,
            "1% of pool input, judged before the buy"
        );

        // 4% down before the buy: no fee, whatever the buy does to the price.
        uint256 snap = vm.snapshotState();
        vm.revertToState(snap);
        _sellToDrawdown(400);
        before = _feesWithDonations();
        _buyPanic(10 ether);
        assertEq(_feesWithDonations(), before, "not down before the buy: 0%");
    }

    function test_exactOutputBuyPaysFeeOnThePairedInput() public {
        _sellToDrawdown(1000);
        uint256 before = _feesWithDonations();
        uint256 ethBefore = address(this).balance;
        BalanceDelta d = _buyPanicExactOut(1 ether);
        uint256 fee = _feesWithDonations() - before;
        assertEq(d.amount1(), 1 ether, "got exactly the PANIC asked for");
        uint256 paid = uint256(-int256(d.amount0()));
        assertEq(ethBefore - address(this).balance, paid);
        // fee = 1% of what the pool needed; the swapper paid pool input plus fee.
        uint256 poolInput = paid - fee;
        assertEq(fee, poolInput * 100 / 10_000);
        assertGt(fee, 0);
    }

    function test_exactOutputBuyWhileNotDownPaysNothing() public {
        uint256 before = _feesWithDonations();
        _buyPanicExactOut(1 ether);
        assertEq(_feesWithDonations(), before);
    }

    // ---------------------------------------------------------------- what the fee is taken in

    function test_feesAreTakenOnlyInThePairedCurrency() public {
        _sellToDrawdown(2000);
        _buyPanic(5 ether);
        _sellPanic(1 ether);
        assertGt(_feesWithDonations(), 0);
        assertEq(_claimBalance(), hook.totalAccruedFees(), "claims in the paired currency back every bucket");
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(panic)).toId()), 0, "no PANIC claims");
        assertEq(panic.balanceOf(address(hook)), 0, "no PANIC held");
        assertEq(address(hook).balance, 0, "no loose ETH held");
    }

    function test_noAddressIsExempt() public {
        _sellToDrawdown(1000);
        // The oracle fund, the dead address, and the hook's own test deployer all pay the same.
        address[3] memory who = [oracleFund, DEAD, address(this)];
        for (uint256 i = 0; i < who.length; i++) {
            panic.transfer(who[i], 1 ether);
            vm.startPrank(who[i]);
            panic.approve(address(swapRouter), type(uint256).max);
            uint256 before = _feesWithDonations();
            BalanceDelta d = _sellPanic(1 ether);
            uint256 fee = _feesWithDonations() - before;
            vm.stopPrank();
            assertEq(fee, _grossOutput(d, fee) * 1000 / 10_000, "10% for everyone");
        }
    }

    function test_feeEventReportsDrawdownTierAndAmount() public {
        _sellToDrawdown(2000);
        vm.recordLogs();
        uint256 before = _feesWithDonations();
        _sellPanic(1 ether);
        uint256 fee = _feesWithDonations() - before;

        bytes32 sig = keccak256("HookFeeCharged(address,bool,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != sig) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(swapRouter), "sender is the router");
            (bool isBuy, uint256 dd, uint256 feeBps, uint256 amount) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            assertFalse(isBuy);
            assertGe(dd, 2000);
            assertEq(feeBps, 2000);
            assertEq(amount, fee);
            found = true;
        }
        assertTrue(found, "HookFeeCharged emitted");
    }
}
