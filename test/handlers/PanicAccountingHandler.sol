// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PanicHook} from "src/PanicHook.sol";
import {PanicMonkeys} from "src/PanicMonkeys.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Ghost amounts come from pool Swap events and actual wallet transfers, not hook buckets.
/// The TWAP model integrates the independently recorded spot-price timeline, without reading
/// the hook's observations or cumulative ticks. All actions use real swaps and settlement.
contract PanicAccountingHandler is Test {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    address constant DEAD = address(0xdEaD);
    PanicHook public immutable hook;
    PanicMonkeys public immutable panic;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable router;
    Currency public paired;
    PoolKey private key;
    bool private immutable panicIs0;
    address[3] public actors;

    uint256 public fees;
    uint256 public expectedOracle;
    uint256 public expectedLp;
    uint256 public expectedBurn;
    uint256 public claimed;
    uint256 public spent;
    uint256 public burned;
    uint256 public successfulSwaps;
    uint256 public successfulBuybacks;
    uint256 public rejectedBuybacks;

    struct Spot {
        uint256 time;
        int24 tick;
    }
    Spot[] private spots;
    uint256 private referenceBlock;
    int24 private frozenReference;
    int24 private immutable launchTick;

    constructor(PanicHook h, PanicMonkeys p, IPoolManager m, PoolSwapTest r, PoolKey memory k) {
        hook = h;
        panic = p;
        manager = m;
        router = r;
        key = k;
        panicIs0 = Currency.unwrap(k.currency0) == address(p);
        paired = panicIs0 ? k.currency1 : k.currency0;
        actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
        (, int24 tick,,) = manager.getSlot0(k.toId());
        spots.push(Spot(block.timestamp, tick));
        referenceBlock = block.number;
        frozenReference = tick;
        launchTick = tick;
    }

    function advance(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 7200));
        vm.roll(block.number + 1);
    }

    function sell(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 maximum = panic.balanceOf(actor);
        if (maximum == 0) return;
        if (maximum > 1200 ether) maximum = 1200 ether;
        uint256 amount = bound(amountSeed, 1, maximum);
        _trade(actor, false, amount);
    }

    function buy(uint256 actorSeed, uint256 amountSeed) external {
        _trade(actors[actorSeed % 3], true, bound(amountSeed, 1, 200 ether));
    }

    function _trade(address actor, bool isBuy, uint256 amount) private {
        uint160 referencePrice = _freezeReference();
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        uint256 pairedBefore = paired.balanceOf(actor);
        uint256 panicBefore = panic.balanceOf(actor);
        uint256 observationsBefore = hook.observationCount();
        bool alreadyObserved = hook.lastObservedBlock() == block.number;
        bool zeroForOne = isBuy != panicIs0;

        vm.recordLogs();
        vm.prank(actor);
        BalanceDelta d = router.swap{value: isBuy && paired.isAddressZero() ? amount : 0}(
            key,
            SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        (uint256 poolAmount, uint160 afterPrice) = _poolSwap(vm.getRecordedLogs(), isBuy);
        uint256 actualFee;
        if (isBuy) {
            uint256 paid = pairedBefore - paired.balanceOf(actor);
            assertEq(paid, amount, "exact input buy budget");
            actualFee = paid - poolAmount;
            uint256 expected = _drawdown(beforePrice, referencePrice) >= 500 ? poolAmount / 100 : 0;
            // Reserving a fee from an inclusive input budget can round down one extra wei.
            assertLe(actualFee, expected);
            assertLe(expected - actualFee, 1);
            assertEq(panic.balanceOf(actor) - panicBefore, uint256(uint128(panicIs0 ? d.amount0() : d.amount1())));
        } else {
            actualFee = poolAmount - (paired.balanceOf(actor) - pairedBefore);
            uint256 dd = _drawdown(afterPrice, referencePrice);
            uint256 rate = dd < 500 ? 200 : dd < 1500 ? 1000 : dd < 3000 ? 2000 : 3000;
            assertEq(actualFee, poolAmount * rate / 10_000, "sell judged after execution");
            assertEq(panicBefore - panic.balanceOf(actor), amount);
        }
        assertLe(actualFee * 10_000, poolAmount * 3000, "fee ceiling");
        _accrue(actualFee);
        successfulSwaps++;
        assertEq(hook.referenceSqrtPriceX96(), referencePrice, "current block cannot change reference");
        assertLe(hook.observationCount() - observationsBefore, alreadyObserved ? 0 : 1);
        _recordSpot();
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 due = expectedOracle - claimed;
        uint256 beforeBalance = paired.balanceOf(hook.oracleFund());
        vm.prank(actor);
        if (due == 0) {
            vm.expectRevert(PanicHook.NothingToClaim.selector);
            hook.claimOracleFund();
        } else {
            assertEq(hook.claimOracleFund(), due);
            claimed += due;
        }
        assertEq(paired.balanceOf(hook.oracleFund()) - beforeBalance, due, "fixed recipient receives all claims");
    }

    function donate(uint256 actorSeed) external {
        uint256 pending = hook.donationBucket();
        vm.prank(actors[actorSeed % 3]);
        if (pending == 0) {
            vm.expectRevert(PanicHook.NothingToDonate.selector);
            hook.donateToLiquidityProviders();
        } else {
            assertEq(hook.donateToLiquidityProviders(), pending);
        }
    }

    function buyback(uint256 actorSeed, uint256 maxSpendSeed) external {
        uint256 limit = bound(maxSpendSeed, 0, 2 ether);
        uint256 previousReferenceBlock = referenceBlock;
        int24 previousFrozen = frozenReference;
        uint160 referencePrice = _freezeReference();
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        uint256 bucket = hook.burnBucket();
        uint256 deadBefore = panic.balanceOf(DEAD);
        bytes32 beforeState = _stateHash();
        vm.recordLogs();
        vm.prank(actors[actorSeed % 3]);
        try hook.buybackAndBurn(limit) returns (uint256 used, uint256 bought) {
            (uint256 poolInput,) = _poolSwap(vm.getRecordedLogs(), true);
            uint256 fee = used - poolInput;
            uint256 expectedFee = _drawdown(priceBefore, referencePrice) >= 500 ? poolInput / 100 : 0;
            assertLe(fee, expectedFee, "buyback fee ceiling");
            assertLe(expectedFee - fee, 1, "buybacks receive no fee exemption");
            assertLe(used, limit);
            assertLe(used, 1 ether);
            assertLe(used, bucket);
            assertGt(bought, 0);
            assertEq(panic.balanceOf(DEAD) - deadBefore, bought);
            // The independent 98% output-floor property failed for tiny budgets. Its full
            // failing reproduction is reported in .imd-findings.json, not weakened here.
            _accrue(fee);
            spent += used;
            burned += bought;
            successfulBuybacks++;
            assertEq(hook.referenceSqrtPriceX96(), referencePrice);
            _recordSpot();
        } catch (bytes memory reason) {
            vm.getRecordedLogs();
            if (bucket == 0 || limit == 0) {
                assertEq(bytes4(reason), PanicHook.NothingToBuyBack.selector);
            } else {
                assertEq(bytes4(reason), PanicHook.BuybackBelowReference.selector, "no unexpected buyback failure");
            }
            assertEq(_stateHash(), beforeState, "failed buyback rolls back every effect");
            referenceBlock = previousReferenceBlock;
            frozenReference = previousFrozen;
            rejectedBuybacks++;
        }
    }

    function transferPanic(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256 amount = bound(amountSeed, 0, panic.balanceOf(from) / 2);
        uint256 fromBefore = panic.balanceOf(from);
        uint256 toBefore = panic.balanceOf(to);
        vm.prank(from);
        assertTrue(panic.transfer(to, amount));
        assertEq(panic.balanceOf(from), from == to ? fromBefore : fromBefore - amount);
        assertEq(panic.balanceOf(to), from == to ? toBefore : toBefore + amount);
    }

    function modelReferenceTick() public view returns (int24) {
        if (referenceBlock == block.number) return frozenReference;
        uint256 start = block.timestamp - 3600;
        int256 sum;
        if (start < spots[0].time) sum = int256(launchTick) * int256(spots[0].time - start);
        for (uint256 i; i < spots.length; i++) {
            uint256 lo = spots[i].time > start ? spots[i].time : start;
            uint256 hi = i + 1 < spots.length ? spots[i + 1].time : block.timestamp;
            if (hi > lo) sum += int256(spots[i].tick) * int256(hi - lo);
        }
        int256 mean = sum / 3600;
        if (sum < 0 && sum % 3600 != 0) mean--;
        return int24(mean);
    }

    function _freezeReference() private returns (uint160) {
        int24 expected = modelReferenceTick();
        assertEq(hook.referenceTick(), expected, "independent one-hour spot integral");
        referenceBlock = block.number;
        frozenReference = expected;
        return TickMath.getSqrtPriceAtTick(expected);
    }

    function _recordSpot() private {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        if (spots[spots.length - 1].time == block.timestamp) spots[spots.length - 1].tick = tick;
        else spots.push(Spot(block.timestamp, tick));
    }

    function _drawdown(uint160 live, uint160 ref) private view returns (uint256) {
        (uint256 num, uint256 den) = panicIs0 ? (uint256(live), uint256(ref)) : (uint256(ref), uint256(live));
        if (num >= den) return 0;
        return (den * den - num * num) * 10_000 / (den * den);
    }

    function _accrue(uint256 fee) private {
        fees += fee;
        expectedLp += fee * 3 / 10;
        expectedBurn += fee / 10;
        expectedOracle += fee - fee * 3 / 10 - fee / 10;
    }

    function _poolSwap(Vm.Log[] memory logs, bool isBuy) private view returns (uint256 amount, uint160 sqrt) {
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_EVENT) continue;
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
            (int128 d0, int128 d1, uint160 price,,,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            int256 delta = panicIs0 ? int256(d1) : int256(d0);
            amount = uint256(isBuy ? -delta : delta);
            sqrt = price;
            count++;
        }
        assertEq(count, 1, "exactly one real pool swap");
    }

    function _stateHash() private view returns (bytes32) {
        (uint160 sqrt, int24 tick,,) = manager.getSlot0(key.toId());
        return keccak256(
            abi.encode(
                hook.oracleFundBucket(),
                hook.donationBucket(),
                hook.burnBucket(),
                hook.totalDonated(),
                manager.balanceOf(address(hook), paired.toId()),
                paired.balanceOf(address(manager)),
                panic.balanceOf(address(manager)),
                panic.balanceOf(DEAD),
                sqrt,
                tick,
                hook.observationCount(),
                hook.lastObservedBlock(),
                hook.lastObservedTick()
            )
        );
    }
}
