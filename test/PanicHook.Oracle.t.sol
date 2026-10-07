// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PanicTestBase} from "./utils/PanicTestBase.sol";

/// @notice The hook's own 1-hour TWAP reference: one observation per block, taken before the block's first
/// swap, so nothing traded in the current block can move it.
contract PanicHookOracleTest is PanicTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpNativePool(SQRT_PRICE_1_1);
        _fundAndApprove();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    // ---------------------------------------------------------------- one observation per block

    function test_atMostOneObservationPerBlockTakenBeforeTheFirstSwap() public {
        assertEq(hook.observationCount(), 1, "initialization observation");
        _nextBlock(12);
        int24 preSwapTick = _tick();

        _sellToDrawdown(1000);
        _buyPanic(3 ether);
        _sellPanic(50 ether);
        assertEq(hook.observationCount(), 2, "three swaps, one observation");

        (uint32 ts, int56 cum) = hook.observations(1);
        assertEq(ts, uint32(block.timestamp));
        assertEq(cum, int56(preSwapTick) * 12, "weighted by the 12 seconds since the previous observation");
        assertEq(hook.lastObservedTick(), preSwapTick, "the price before the first swap, not after");
        assertEq(hook.lastObservedBlock(), block.number);
    }

    function test_swapsInTheInitializationBlockRecordNothingNew() public {
        _sellToDrawdown(2000);
        _buyPanic(1 ether);
        assertEq(hook.observationCount(), 1);
        assertEq(hook.referenceTick(), 0);
    }

    function test_blocksSharingATimestampDoNotDuplicateObservations() public {
        _nextBlock(5);
        _sellPanic(1 ether);
        assertEq(hook.observationCount(), 2);
        vm.roll(block.number + 1); // same timestamp, next block
        _sellPanic(1 ether);
        assertEq(hook.observationCount(), 2, "no zero-length observation");
        assertEq(hook.lastObservedBlock(), block.number, "but the block still counts as observed");
        _sellPanic(1 ether);
        assertEq(hook.observationCount(), 2);
    }

    // ---------------------------------------------------------------- reference is immune to this block

    function test_buyAndSellInTheSameBlockCannotMoveTheReference() public {
        _nextBlock(600);
        uint160 refBefore = hook.referenceSqrtPriceX96();
        int24 tickBefore = hook.referenceTick();

        _buyPanic(500 ether);
        assertEq(hook.referenceSqrtPriceX96(), refBefore, "after the buy");
        _sellToDrawdown(2500);
        assertEq(hook.referenceSqrtPriceX96(), refBefore, "after the sell");
        _buyPanic(50 ether);
        _sellPanic(20 ether);
        assertEq(hook.referenceSqrtPriceX96(), refBefore, "after more of both");
        assertEq(hook.referenceTick(), tickBefore);
        assertEq(hook.observationCount(), 2, "exactly one observation was taken for this block");
    }

    function test_aCrashInThisBlockIsJudgedAgainstTheUntouchedReference() public {
        _nextBlock(12);
        uint256 before = _feesWithDonations();
        BalanceDelta d = _sellToDrawdown(2000);
        uint256 fee = _feesWithDonations() - before;
        assertEq(fee, _grossOutput(d, fee) * 2000 / 10_000);
        // A second seller in the same block faces the same reference and is now deeper.
        before = _feesWithDonations();
        d = _sellToDrawdown(3100);
        fee = _feesWithDonations() - before;
        assertEq(fee, _grossOutput(d, fee) * 3000 / 10_000);
    }

    // ---------------------------------------------------------------- it is a 1-hour TWAP

    function test_referenceIsTheOneHourMeanTick() public {
        // Half an hour at tick 0, then the price moves to T and stays.
        _nextBlock(1800);
        _sellToDrawdown(2000); // the observation taken here still records tick 0 for the first 1800s
        int24 t = _tick();
        assertLt(t, 0 + 3000);
        assertGt(t, 0);

        _nextBlock(1800); // now 3600s after init: half the window at 0, half at T
        int24 expected = int24(int56(t) * 1800 / 3600);
        assertEq(hook.referenceTick(), expected, "mean of 0 and T over the hour");

        _nextBlock(1800); // the window now covers only time at T
        assertEq(hook.referenceTick(), t, "whole window at T");
        assertEq(hook.currentDrawdownBps(), 0);
    }

    function test_launchPriceAnchorsTheWindowBeforeTheFirstObservation() public {
        // A dump 12 seconds after launch barely dents the reference, because the launch price is
        // assumed to have held for the rest of the hour-long window.
        _nextBlock(12);
        _sellToDrawdown(2000);
        int24 crashTick = _tick();
        _nextBlock(12);
        int24 ref = hook.referenceTick();
        assertEq(ref, int24(int56(crashTick) * 12 / 3600), "12 of 3600 seconds at the crash price");
        assertGe(hook.currentDrawdownBps(), 1990, "still about 20% down");
    }

    function test_afterAnHourDownButFlatThePanicTierNoLongerApplies() public {
        _nextBlock(12);
        _sellToDrawdown(2000);
        uint256 dd = hook.currentDrawdownBps();
        assertGe(dd, 2000);

        // Nothing trades for an hour. The reference has fully caught up with the depressed price.
        _nextBlock(3600);
        assertEq(hook.referenceTick(), _tick(), "reference equals the flat price");
        assertEq(hook.currentDrawdownBps(), 0);

        uint256 before = _feesWithDonations();
        BalanceDelta d = _sellPanic(1 ether);
        uint256 fee = _feesWithDonations() - before;
        assertEq(fee, _grossOutput(d, fee) * 200 / 10_000, "base 2% sell fee again");

        before = _feesWithDonations();
        _buyPanic(1 ether);
        assertEq(_feesWithDonations(), before, "buys are free again");
    }

    function test_panicTierStillAppliesBeforeTheHourIsUp() public {
        _nextBlock(12);
        _sellToDrawdown(2000);
        _nextBlock(1800); // half an hour later the reference has only moved half way
        uint256 dd = hook.currentDrawdownBps();
        assertGe(dd, 900);
        assertLt(dd, 1200);
        uint256 before = _feesWithDonations();
        BalanceDelta d = _sellPanic(1 ether);
        uint256 fee = _feesWithDonations() - before;
        assertEq(fee, _grossOutput(d, fee) * 1000 / 10_000, "10% tier");
    }

    function test_viewMatchesAnIndependentTwapOverManyObservations() public {
        // 400 blocks of trading, 12 seconds apart (80 minutes), alternating buys and sells.
        for (uint256 i = 0; i < 400; i++) {
            _nextBlock(12);
            if (i % 3 == 0) _sellPanic(30 ether);
            else _buyPanic(7 ether);
        }
        _nextBlock(12);
        int24 expected = _independentTwap();
        assertEq(hook.referenceTick(), expected, "hook TWAP equals the independently computed one");
        // A swap in this block commits the same reference it quotes.
        uint160 quoted = hook.referenceSqrtPriceX96();
        _sellPanic(1 ether);
        assertEq(hook.referenceSqrtPriceX96(), quoted);
        assertEq(hook.referenceTick(), expected);
    }

    /// @dev Reference implementation: walk the observation array, extend the last segment with the live
    /// tick to now, and average the last 3600 seconds (launch tick before the first observation).
    function _independentTwap() internal view returns (int24) {
        uint256 n = hook.observationCount();
        uint256 nowTs = block.timestamp;
        uint256 target = nowTs - 3600;
        int256 acc = 0;
        for (uint256 i = 0; i < n; i++) {
            (uint32 ts, int56 cum) = hook.observations(i);
            uint256 segEnd;
            int256 segTick;
            if (i + 1 < n) {
                (uint32 nextTs, int56 nextCum) = hook.observations(i + 1);
                segEnd = nextTs;
                segTick = (int256(nextCum) - int256(cum)) / int256(uint256(nextTs - ts));
            } else {
                segEnd = nowTs;
                segTick = _tick();
            }
            uint256 segStart = ts;
            if (i == 0) segStart = target; // launch tick assumed before observation 0
            uint256 lo = segStart > target ? segStart : target;
            uint256 hi = segEnd;
            if (hi > lo) acc += segTick * int256(hi - lo);
            if (i == 0 && uint256(ts) > target) acc += int256(hook.initialTick()) * int256(0); // anchor handled above
        }
        int256 q = acc / 3600;
        if (acc < 0 && acc % 3600 != 0) q--;
        return int24(q);
    }
}
