// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PanicMonkeys} from "../../src/PanicMonkeys.sol";
import {PanicHook} from "../../src/PanicHook.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

/// @notice Shared fixture: a fresh PoolManager, the token, the hook at a mined address, test routers,
/// and helpers that drive the pool to precise drawdowns through swap price limits.
abstract contract PanicTestBase is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant LP_FEE = 12_500;
    int24 internal constant TICK_SPACING = 100;
    uint128 internal constant FULL_RANGE_LIQUIDITY = 1e22;
    uint256 internal constant START_TIME = 1_800_000_000;
    uint256 internal constant START_BLOCK = 1_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address internal oracleFund = makeAddr("oracleFund");
    address internal trader = makeAddr("trader");

    PoolManager internal manager;
    PanicMonkeys internal panic;
    PanicHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal key;
    PoolId internal poolId;

    /// @dev The non-PANIC side of the pool. address(0) means native ETH.
    Currency internal paired;
    bool internal panicIs0;
    /// @dev Next CREATE2 salt to try when mining a hook address in this test.
    uint256 internal nextSalt;

    receive() external payable {}

    // ------------------------------------------------------------------------------------------------
    // Fixture
    // ------------------------------------------------------------------------------------------------

    function _deployCore() internal {
        vm.warp(START_TIME);
        vm.roll(START_BLOCK);
        manager = new PoolManager(address(this));
        panic = new PanicMonkeys();
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        hook = _deployHook(IPoolManager(address(manager)), address(panic), oracleFund);
    }

    function _deployHook(IPoolManager pm, address token, address fund) internal returns (PanicHook deployed) {
        bytes memory creationCode = abi.encodePacked(type(PanicHook).creationCode, abi.encode(pm, token, fund));
        // Continue from the last salt used so repeated deployments in one test neither collide under
        // CREATE2 nor re-mine the same range.
        address predicted;
        bytes32 salt;
        while (true) {
            (predicted, salt) = HookMiner.find(address(this), HookFlags.PANIC_HOOK, creationCode, nextSalt, 1_000_000);
            nextSalt = uint256(salt) + 1;
            if (predicted.code.length == 0) break;
        }
        deployed = new PanicHook{salt: salt}(pm, token, fund);
        assertEq(address(deployed), predicted, "hook address mismatch");
    }

    /// @dev Sets up a PANIC / native ETH pool. ETH is address(0), so PANIC is currency1.
    function _setUpNativePool(uint160 sqrtPriceX96) internal {
        _deployCore();
        paired = CurrencyLibrary.ADDRESS_ZERO;
        panicIs0 = false;
        key = PoolKey({
            currency0: paired,
            currency1: Currency.wrap(address(panic)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        manager.initialize(key, sqrtPriceX96);
    }

    /// @dev Sets up a PANIC / ERC-20 pool, choosing the mock token's address so PANIC lands on the
    /// requested side of the pair.
    function _setUpErc20Pool(bool wantPanicAsCurrency0, uint160 sqrtPriceX96) internal {
        _deployCore();
        MockERC20 token;
        for (uint256 i = 0; i < 64; i++) {
            token = new MockERC20("Paired", "PAIR", 1e30);
            bool panicWouldBe0 = address(panic) < address(token);
            if (panicWouldBe0 == wantPanicAsCurrency0) break;
        }
        require((address(panic) < address(token)) == wantPanicAsCurrency0, "could not place PANIC on the wanted side");
        paired = Currency.wrap(address(token));
        panicIs0 = wantPanicAsCurrency0;
        (Currency c0, Currency c1) =
            panicIs0 ? (Currency.wrap(address(panic)), paired) : (paired, Currency.wrap(address(panic)));
        key = PoolKey({
            currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        manager.initialize(key, sqrtPriceX96);
    }

    function _fundAndApprove() internal {
        vm.deal(address(this), 1e27);
        panic.approve(address(swapRouter), type(uint256).max);
        panic.approve(address(lpRouter), type(uint256).max);
        if (!paired.isAddressZero()) {
            MockERC20(Currency.unwrap(paired)).approve(address(swapRouter), type(uint256).max);
            MockERC20(Currency.unwrap(paired)).approve(address(lpRouter), type(uint256).max);
        }
    }

    function _addFullRangeLiquidity(uint128 liquidity) internal {
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        _addLiquidity(lower, upper, liquidity);
    }

    function _addLiquidity(int24 lower, int24 upper, uint128 liquidity) internal {
        uint256 value = paired.isAddressZero() ? 1e26 : 0;
        lpRouter.modifyLiquidity{value: value}(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );
    }

    // ------------------------------------------------------------------------------------------------
    // Swaps
    // ------------------------------------------------------------------------------------------------

    function _swap(bool zeroForOne, int256 amountSpecified, uint160 limit) internal returns (BalanceDelta delta) {
        uint256 value = 0;
        bool payingNative = paired.isAddressZero() && zeroForOne; // native is always currency0
        if (payingNative) value = amountSpecified < 0 ? uint256(-amountSpecified) : 1e26;
        delta = swapRouter.swap{value: value}(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Exact-input sell of `amount` PANIC with no price limit.
    function _sellPanic(uint256 amount) internal returns (BalanceDelta) {
        bool zeroForOne = panicIs0;
        return _swap(zeroForOne, -int256(amount), _noLimit(zeroForOne));
    }

    /// @dev Exact-input sell with a price limit: sells as much as needed (up to a huge amount) to reach it.
    function _sellPanicToPrice(uint160 sqrtLimit) internal returns (BalanceDelta) {
        bool zeroForOne = panicIs0;
        return _swap(zeroForOne, -int256(1e26), sqrtLimit);
    }

    /// @dev Exact-input buy spending `amount` of the paired currency with no price limit.
    function _buyPanic(uint256 amount) internal returns (BalanceDelta) {
        bool zeroForOne = !panicIs0;
        return _swap(zeroForOne, -int256(amount), _noLimit(zeroForOne));
    }

    /// @dev Exact-output buy of `amount` PANIC.
    function _buyPanicExactOut(uint256 amount) internal returns (BalanceDelta) {
        bool zeroForOne = !panicIs0;
        return _swap(zeroForOne, int256(amount), _noLimit(zeroForOne));
    }

    function _noLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    // ------------------------------------------------------------------------------------------------
    // Price helpers
    // ------------------------------------------------------------------------------------------------

    function _sqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    /// @dev The sqrt price at which PANIC sits `drawdownBps` below the price at `refSqrt`.
    function _sqrtPriceAtDrawdown(uint160 refSqrt, uint256 drawdownBps) internal pure returns (uint160) {
        uint256 ref2 = uint256(refSqrt) * uint256(refSqrt);
        uint256 target2;
        if (drawdownBps == 0) return refSqrt;
        // PANIC price = 1/price1/0 when PANIC is currency1, so a drawdown raises price1/0 by 1/(1-d).
        target2 = ref2 * 10_000 / (10_000 - drawdownBps);
        return uint160(_sqrt(target2) + 1);
    }

    /// @dev Pushes the pool to (about) `drawdownBps` below the current reference with one exact-input sell.
    function _sellToDrawdown(uint256 drawdownBps) internal returns (BalanceDelta) {
        uint160 ref = hook.referenceSqrtPriceX96();
        uint160 limit = panicIs0 ? _flipForCurrency0(ref, drawdownBps) : _sqrtPriceAtDrawdown(ref, drawdownBps);
        return _sellPanicToPrice(limit);
    }

    /// @dev When PANIC is currency0, a drawdown lowers price1/0 by (1-d).
    function _flipForCurrency0(uint160 refSqrt, uint256 drawdownBps) internal pure returns (uint160) {
        uint256 ref2 = uint256(refSqrt) * uint256(refSqrt);
        return uint160(_sqrt(ref2 * (10_000 - drawdownBps) / 10_000));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _pairedBalance(address who) internal view returns (uint256) {
        return paired.balanceOf(who);
    }

    function _pairedAmount(BalanceDelta delta) internal view returns (int128) {
        return panicIs0 ? delta.amount1() : delta.amount0();
    }

    /// @dev The ERC-7751 wrapped revert the PoolManager produces when a hook callback reverts with `inner`.
    function _wrappedHookRevert(bytes4 callback, bytes memory inner) internal view returns (bytes memory) {
        return _wrappedHookRevert(address(hook), callback, inner);
    }

    function _wrappedHookRevert(address target, bytes4 callback, bytes memory inner)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            target,
            callback,
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev Gross paired output of a sell: what the swapper received plus the hook fee charged on it.
    function _grossOutput(BalanceDelta delta, uint256 fee) internal view returns (uint256) {
        return uint256(int256(_pairedAmount(delta))) + fee;
    }

    /// @dev Fees still held plus the LP share already paid (compare between swaps, before outlets).
    function _feesWithDonations() internal view returns (uint256) {
        return hook.totalAccruedFees() + hook.totalDonated();
    }

    function _claimBalance() internal view returns (uint256) {
        return manager.balanceOf(address(hook), paired.toId());
    }

    function _nextBlock(uint256 secondsLater) internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + secondsLater);
    }
}
