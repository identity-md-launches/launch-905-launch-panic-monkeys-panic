// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {HookFlags} from "./HookFlags.sol";

/// @title PanicHook
/// @notice Uniswap v4 hook for the Panic Monkeys ($PANIC) launch pool. It punishes selling into a drawdown
/// and makes dip buying cheap, measured against the hook's own 1-hour time-weighted average price (TWAP).
///
/// Reference price: the hook records at most one observation per block, taken from the pool price before
/// the first swap of that block, so no trade in the current block can move the reference. The reference
/// is the 1-hour geometric TWAP (arithmetic mean tick) of those observations; before the pool's first
/// block the launch price is assumed, so the window is a full hour from the start. Drawdown is how far
/// the live PANIC price sits below the reference, in basis points. "Down" means drawdown >= 5%.
///
/// Hook fee (on top of the pool's LP fee), always taken in the paired currency (the non-PANIC side):
/// - Buys, judged on the price before the buy: 0% when not down, 1% when down.
/// - Sells, judged on the price after the sell: 2% (< 5%), 10% (5%..15%), 20% (15%..30%), 30% (>= 30%).
/// No address is exempt. The hook fee never exceeds 30%.
///
/// Every hook fee is split 60% to the Panic Oracle Fund (claimable only to the fixed oracle budget address),
/// 30% donated to in-range liquidity providers through `PoolManager.donate`, and 10% to a burn bucket that
/// `buybackAndBurn` swaps for PANIC and sends to the dead address. Claim, donate and buyback are permissionless.
///
/// Fees are credited to the hook as ERC-6909 claims inside the swap, so a fee-bearing swap never depends on
/// the PoolManager already holding the paired currency, and a recipient that cannot receive native ETH can
/// only block its own claim, never trading.
///
/// There is no owner, no pause and no upgrade path: every fee, threshold, share and the reference window
/// is a compile-time constant.
contract PanicHook is IHooks, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using SafeCast for int256;
    using BalanceDeltaLibrary for BalanceDelta;

    // ------------------------------------------------------------------------------------------------
    // Constants (immutable economics)
    // ------------------------------------------------------------------------------------------------

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Length of the reference TWAP window.
    uint32 public constant TWAP_WINDOW = 1 hours;

    /// @notice Drawdown at or above which the price counts as "down" (5%).
    uint256 public constant DOWN_THRESHOLD_BPS = 500;
    /// @notice Drawdown at or above which sells pay the second panic tier (15%).
    uint256 public constant PANIC_TIER_2_THRESHOLD_BPS = 1500;
    /// @notice Drawdown at or above which sells pay the third panic tier (30%).
    uint256 public constant PANIC_TIER_3_THRESHOLD_BPS = 3000;

    /// @notice Buy fee when not down.
    uint256 public constant BUY_FEE_BPS = 0;
    /// @notice Buy fee when down (dip buying).
    uint256 public constant BUY_FEE_DOWN_BPS = 100;
    /// @notice Sell fee when not down.
    uint256 public constant SELL_FEE_BPS = 200;
    /// @notice Sell fee at 5% <= drawdown < 15%.
    uint256 public constant SELL_FEE_TIER_1_BPS = 1000;
    /// @notice Sell fee at 15% <= drawdown < 30%.
    uint256 public constant SELL_FEE_TIER_2_BPS = 2000;
    /// @notice Sell fee at drawdown >= 30%.
    uint256 public constant SELL_FEE_TIER_3_BPS = 3000;
    /// @notice Hard ceiling on any hook fee.
    uint256 public constant MAX_HOOK_FEE_BPS = 3000;

    /// @notice Share of every hook fee accruing to the Panic Oracle Fund.
    uint256 public constant ORACLE_SHARE_BPS = 6000;
    /// @notice Share of every hook fee donated to in-range liquidity providers.
    uint256 public constant LP_SHARE_BPS = 3000;
    /// @notice Share of every hook fee accruing to the burn bucket.
    uint256 public constant BURN_SHARE_BPS = 1000;

    /// @notice A buyback must receive at least this fraction of the PANIC implied by the reference price.
    uint256 public constant MIN_BUYBACK_OUTPUT_BPS = 9800;
    /// @notice Most paired currency a single `buybackAndBurn` call may spend (minor units of the paired currency).
    uint256 public constant MAX_BUYBACK_SPEND = 1 ether;
    /// @notice Where bought-back PANIC goes.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Permission bits the hook address must carry.
    uint160 public constant REQUIRED_FLAGS = HookFlags.PANIC_HOOK;

    // ------------------------------------------------------------------------------------------------
    // Immutables
    // ------------------------------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    /// @notice The launch token.
    address public immutable panic;
    /// @notice The only address the Panic Oracle Fund can ever be claimed to.
    address public immutable oracleFund;

    // ------------------------------------------------------------------------------------------------
    // Pool
    // ------------------------------------------------------------------------------------------------

    /// @notice The single pool this hook serves, set in `beforeInitialize`.
    PoolKey public poolKey;
    PoolId public poolId;
    bool public poolRegistered;
    /// @notice True when PANIC is `currency0` of the pool (the paired currency is then `currency1`).
    bool public panicIsCurrency0;

    // ------------------------------------------------------------------------------------------------
    // Oracle
    // ------------------------------------------------------------------------------------------------

    struct Observation {
        /// @dev Block timestamp of the observation.
        uint32 blockTimestamp;
        /// @dev Running sum of tick * seconds, Uniswap v3 style.
        int56 tickCumulative;
    }

    /// @notice Append-only observation history. Index 0 is the pool initialization.
    Observation[] public observations;
    /// @notice Last block in which an observation was taken (or confirmed for a same-second block).
    uint256 public lastObservedBlock;
    /// @notice The pre-swap tick recorded for `lastObservedBlock`.
    int24 public lastObservedTick;
    /// @notice The pool's initialization tick; assumed to have prevailed before the pool existed.
    int24 public initialTick;
    /// @dev Search hint: index of the observation at or before the start of the last computed window.
    uint256 private windowStartHint;

    // ------------------------------------------------------------------------------------------------
    // Fee buckets (all in the paired currency, backed 1:1 by ERC-6909 claims held by this contract)
    // ------------------------------------------------------------------------------------------------

    uint256 public oracleFundBucket;
    uint256 public donationBucket;
    uint256 public burnBucket;
    /// @notice Lifetime LP share already donated; not part of the outstanding claim balance.
    uint256 public totalDonated;

    // ------------------------------------------------------------------------------------------------
    // Transient state passed from beforeSwap to afterSwap and into the unlock callback
    // ------------------------------------------------------------------------------------------------

    uint256 private constant KIND_NONE = 0;
    uint256 private constant KIND_BUY = 1;
    uint256 private constant KIND_SELL = 2;

    bytes32 private constant TS_KIND = keccak256("PanicHook.kind");
    bytes32 private constant TS_FEE_BPS = keccak256("PanicHook.feeBps");
    bytes32 private constant TS_DRAWDOWN = keccak256("PanicHook.drawdown");
    bytes32 private constant TS_BEFORE_FEE = keccak256("PanicHook.beforeFee");
    bytes32 private constant TS_REF_SQRT_PRICE = keccak256("PanicHook.refSqrtPrice");

    uint8 private constant ACTION_CLAIM = 1;
    uint8 private constant ACTION_DONATE = 2;
    uint8 private constant ACTION_BUYBACK = 3;

    // ------------------------------------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------------------------------------

    event PoolRegistered(PoolId indexed id, Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing);
    event ObservationRecorded(uint256 indexed index, uint32 blockTimestamp, int24 tick, int56 tickCumulative);
    event HookFeeCharged(address indexed sender, bool isBuy, uint256 drawdownBps, uint256 feeBps, uint256 feeAmount);
    event OracleFundClaimed(address indexed caller, uint256 amount);
    event DonatedToLiquidityProviders(address indexed caller, uint256 amount);
    event BuybackAndBurn(address indexed caller, uint256 spent, uint256 burned, uint256 impliedAtReference);

    error NotPoolManager();
    error HookNotImplemented();
    error ZeroAddress();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error UnknownPool();
    error PoolMustContainPanic();
    error DynamicFeeNotSupported();
    error ExactOutputSellNotSupported();
    error PartialExactInputBuyNotSupported();
    error NothingToClaim();
    error NothingToDonate();
    error NothingToBuyBack();
    error BuybackBelowReference(uint256 received, uint256 minimum);
    error UnexpectedAction(uint8 action);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param poolManager_ The chain's Uniswap v4 PoolManager.
    /// @param panic_ The Panic Monkeys token.
    /// @param oracleFund_ The oracle budget address (the paying wallet). Fixed forever.
    constructor(IPoolManager poolManager_, address panic_, address oracleFund_) {
        if (address(poolManager_) == address(0) || panic_ == address(0) || oracleFund_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        panic = panic_;
        oracleFund = oracleFund_;
        // Refuse to exist at an address whose permission bits disagree with the implementation.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ------------------------------------------------------------------------------------------------
    // Permissions
    // ------------------------------------------------------------------------------------------------

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------------------------------------
    // Initialization callbacks
    // ------------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (poolRegistered) revert PoolAlreadyRegistered();
        bool is0 = Currency.unwrap(key.currency0) == panic;
        bool is1 = Currency.unwrap(key.currency1) == panic;
        if (!is0 && !is1) revert PoolMustContainPanic();
        if (key.fee.isDynamicFee()) revert DynamicFeeNotSupported();

        poolRegistered = true;
        panicIsCurrency0 = is0;
        poolKey = key;
        poolId = key.toId();
        emit PoolRegistered(poolId, key.currency0, key.currency1, key.fee, key.tickSpacing);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        _requireOurPool(key);
        // The first observation anchors the cumulative at the initialization price.
        observations.push(Observation({blockTimestamp: uint32(block.timestamp), tickCumulative: 0}));
        lastObservedBlock = block.number;
        lastObservedTick = tick;
        initialTick = tick;
        emit ObservationRecorded(0, uint32(block.timestamp), tick, 0);
        return IHooks.afterInitialize.selector;
    }

    // ------------------------------------------------------------------------------------------------
    // Swap callbacks
    // ------------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requireOurPool(key);
        uint160 refSqrtPriceX96 = _observeAndReference();

        if (_isBuy(params.zeroForOne)) {
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            uint256 drawdown = drawdownBps(sqrtPriceX96, refSqrtPriceX96, panicIsCurrency0);
            uint256 feeBps = buyFeeBps(drawdown);
            _tstore(TS_KIND, KIND_BUY);
            _tstore(TS_FEE_BPS, feeBps);
            _tstore(TS_DRAWDOWN, drawdown);
            if (params.amountSpecified < 0) {
                // The input budget includes the fee. Reserve at most 1% of the pool's net input.
                // afterSwap refuses partial fills because it cannot refund the specified currency.
                uint256 fee = uint256(-params.amountSpecified) * feeBps / (BPS + feeBps);
                _tstore(TS_BEFORE_FEE, fee);
                return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
            }
            // Exact output: the paired input is the unspecified currency; charged in afterSwap.
            _tstore(TS_BEFORE_FEE, 0);
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Sell. The fee comes out of the paired output, which must be the unspecified currency.
        if (params.amountSpecified > 0) revert ExactOutputSellNotSupported();
        _tstore(TS_KIND, KIND_SELL);
        _tstore(TS_REF_SQRT_PRICE, uint256(refSqrtPriceX96));
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        _requireOurPool(key);
        uint256 kind = _tload(TS_KIND);
        _tstore(TS_KIND, KIND_NONE);

        int128 pairedDelta = panicIsCurrency0 ? delta.amount1() : delta.amount0();
        uint256 drawdown;
        uint256 feeBps;
        uint256 feeAmount;
        int128 unspecifiedDelta;
        bool isBuy;

        if (kind == KIND_BUY) {
            isBuy = true;
            feeBps = _tload(TS_FEE_BPS);
            drawdown = _tload(TS_DRAWDOWN);
            if (params.amountSpecified < 0) {
                feeAmount = _tload(TS_BEFORE_FEE);
                uint256 input = pairedDelta < 0 ? uint256(-int256(pairedDelta)) : 0;
                if (feeAmount > 0 && input + feeAmount != uint256(-params.amountSpecified)) {
                    revert PartialExactInputBuyNotSupported();
                }
            } else {
                // Exact-output buy: the paired input is the (negative) unspecified delta.
                uint256 input = pairedDelta < 0 ? uint256(uint128(-pairedDelta)) : 0;
                feeAmount = input * feeBps / BPS;
                unspecifiedDelta = feeAmount.toInt128();
            }
        } else if (kind == KIND_SELL) {
            uint160 refSqrtPriceX96 = uint160(_tload(TS_REF_SQRT_PRICE));
            (uint160 sqrtPriceAfter,,,) = poolManager.getSlot0(poolId);
            drawdown = drawdownBps(sqrtPriceAfter, refSqrtPriceX96, panicIsCurrency0);
            feeBps = sellFeeBps(drawdown);
            uint256 output = pairedDelta > 0 ? uint256(uint128(pairedDelta)) : 0;
            feeAmount = output * feeBps / BPS;
            unspecifiedDelta = feeAmount.toInt128();
        } else {
            // afterSwap without a matching beforeSwap cannot happen through the PoolManager.
            revert HookNotImplemented();
        }

        if (feeAmount > 0) {
            // Credit the fee to this contract as an ERC-6909 claim. The PoolManager credits the hook's
            // delta by the same amount right after this callback, so the swap stays balanced.
            poolManager.mint(address(this), _paired().toId(), feeAmount);
            _split(feeAmount);
        }
        emit HookFeeCharged(sender, isBuy, drawdown, feeBps, feeAmount);
        return (IHooks.afterSwap.selector, unspecifiedDelta);
    }

    // ------------------------------------------------------------------------------------------------
    // Unused callbacks (not enabled; revert if ever reached)
    // ------------------------------------------------------------------------------------------------

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------------------------------------
    // Permissionless bucket operations
    // ------------------------------------------------------------------------------------------------

    /// @notice Sends the whole Panic Oracle Fund bucket to the fixed oracle budget address. Anyone may call.
    function claimOracleFund() external returns (uint256 amount) {
        amount = oracleFundBucket;
        if (amount == 0) revert NothingToClaim();
        oracleFundBucket = 0;
        poolManager.unlock(abi.encode(ACTION_CLAIM, amount));
        emit OracleFundClaimed(msg.sender, amount);
    }

    /// @notice Donates the whole donation bucket to the pool's in-range liquidity providers. Anyone may call.
    /// @dev Reverts while the pool has no in-range liquidity (`NoLiquidityToReceiveFees`); the bucket waits.
    function donateToLiquidityProviders() external returns (uint256 amount) {
        amount = donationBucket;
        if (amount == 0) revert NothingToDonate();
        donationBucket = 0;
        poolManager.unlock(abi.encode(ACTION_DONATE, amount));
        emit DonatedToLiquidityProviders(msg.sender, amount);
    }

    /// @notice Spends up to `MAX_BUYBACK_SPEND` of the burn bucket on PANIC in this pool and sends every
    /// token bought to the dead address. Anyone may call. Reverts if the buy would return less than 98% of
    /// the PANIC the 1-hour reference price implies for the amount actually spent.
    function buybackAndBurn() external returns (uint256 spent, uint256 burned) {
        return _buybackAndBurn(MAX_BUYBACK_SPEND);
    }

    /// @notice Same as `buybackAndBurn()` but lets the caller spend less than the cap, which is useful
    /// when liquidity is thin and the full cap would miss the 98% floor.
    function buybackAndBurn(uint256 maxSpend) external returns (uint256 spent, uint256 burned) {
        return _buybackAndBurn(maxSpend);
    }

    function _buybackAndBurn(uint256 maxSpend) internal returns (uint256 spent, uint256 burned) {
        uint256 budget = burnBucket;
        if (budget > maxSpend) budget = maxSpend;
        if (budget > MAX_BUYBACK_SPEND) budget = MAX_BUYBACK_SPEND;
        if (budget == 0) revert NothingToBuyBack();

        // Take this block's observation before trading so the buy cannot touch the reference.
        uint160 refSqrtPriceX96 = _observeAndReference();

        burnBucket -= budget;
        bytes memory result = poolManager.unlock(abi.encode(ACTION_BUYBACK, budget));
        (spent, burned) = abi.decode(result, (uint256, uint256));
        if (spent < budget) burnBucket += budget - spent;

        uint256 implied = pairedToPanicAtSqrtPrice(spent, refSqrtPriceX96, panicIsCurrency0);
        uint256 minimum = FullMath.mulDivRoundingUp(implied, MIN_BUYBACK_OUTPUT_BPS, BPS);
        if (minimum == 0) minimum = 1;
        if (burned < minimum) revert BuybackBelowReference(burned, minimum);
        emit BuybackAndBurn(msg.sender, spent, burned, implied);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        (uint8 action, uint256 amount) = abi.decode(data, (uint8, uint256));
        Currency paired = _paired();

        if (action == ACTION_CLAIM) {
            poolManager.burn(address(this), paired.toId(), amount);
            poolManager.take(paired, oracleFund, amount);
            return "";
        }
        if (action == ACTION_DONATE) {
            _donate(amount);
            return "";
        }
        if (action == ACTION_BUYBACK) {
            // v4 skips callbacks on this hook's own swaps. Apply the same buy fee explicitly,
            // reallocating existing claims instead of minting a second claim for the internal fee.
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            uint256 drawdown = drawdownBps(sqrtPriceX96, referenceSqrtPriceX96(), panicIsCurrency0);
            uint256 feeBps = buyFeeBps(drawdown);
            uint256 reservedFee = amount * feeBps / (BPS + feeBps);
            bool zeroForOne = !panicIsCurrency0; // paired -> PANIC
            BalanceDelta delta = poolManager.swap(
                poolKey,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -(amount - reservedFee).toInt256(),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 pairedDelta = panicIsCurrency0 ? delta.amount1() : delta.amount0();
            int128 panicDelta = panicIsCurrency0 ? delta.amount0() : delta.amount1();
            uint256 spent = pairedDelta < 0 ? uint256(uint128(-pairedDelta)) : 0;
            uint256 bought = panicDelta > 0 ? uint256(uint128(panicDelta)) : 0;
            if (spent > 0) poolManager.burn(address(this), paired.toId(), spent);
            uint256 fee = spent * feeBps / BPS;
            if (fee > reservedFee) fee = reservedFee;
            if (fee > 0) _split(fee);
            emit HookFeeCharged(address(this), true, drawdown, feeBps, fee);
            if (bought > 0) poolManager.take(Currency.wrap(panic), DEAD, bought);
            return abi.encode(spent + fee, bought);
        }
        revert UnexpectedAction(action);
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    /// @notice Number of observations recorded so far.
    function observationCount() external view returns (uint256) {
        return observations.length;
    }

    /// @notice The 1-hour reference tick (arithmetic mean tick over the window).
    function referenceTick() external view returns (int24) {
        (int24 tick,) = _reference();
        return tick;
    }

    /// @notice The 1-hour reference price as a Q64.96 sqrt price.
    function referenceSqrtPriceX96() public view returns (uint160) {
        (int24 tick,) = _reference();
        return TickMath.getSqrtPriceAtTick(tick);
    }

    /// @notice Current drawdown of the live pool price below the reference, in basis points.
    function currentDrawdownBps() external view returns (uint256) {
        (int24 tick,) = _reference();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        return drawdownBps(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tick), panicIsCurrency0);
    }

    /// @notice Sum of all three buckets; equals the ERC-6909 claim balance this contract holds.
    function totalAccruedFees() external view returns (uint256) {
        return oracleFundBucket + donationBucket + burnBucket;
    }

    /// @notice The paired (non-PANIC) currency of the pool.
    function pairedCurrency() external view returns (Currency) {
        return _paired();
    }

    // ------------------------------------------------------------------------------------------------
    // Pure fee and price math (exposed for tests and integrators)
    // ------------------------------------------------------------------------------------------------

    /// @notice Buy fee in basis points for a given drawdown, judged on the price before the buy.
    function buyFeeBps(uint256 drawdown) public pure returns (uint256) {
        return drawdown >= DOWN_THRESHOLD_BPS ? BUY_FEE_DOWN_BPS : BUY_FEE_BPS;
    }

    /// @notice Sell fee in basis points for a given drawdown, judged on the price after the sell.
    function sellFeeBps(uint256 drawdown) public pure returns (uint256) {
        if (drawdown >= PANIC_TIER_3_THRESHOLD_BPS) return SELL_FEE_TIER_3_BPS;
        if (drawdown >= PANIC_TIER_2_THRESHOLD_BPS) return SELL_FEE_TIER_2_BPS;
        if (drawdown >= DOWN_THRESHOLD_BPS) return SELL_FEE_TIER_1_BPS;
        return SELL_FEE_BPS;
    }

    /// @notice Drawdown of the PANIC price at `sqrtPriceX96` below the PANIC price at `refSqrtPriceX96`,
    /// in basis points. Zero when the price is at or above the reference. The price ratio is rounded up
    /// exactly, so a price exactly 5% below the reference reports 500 and anything shallower at most 499.
    function drawdownBps(uint160 sqrtPriceX96, uint160 refSqrtPriceX96, bool panicIs0) public pure returns (uint256) {
        // PANIC price in paired units is price1/0 when PANIC is currency1 and price0/1 when it is currency0,
        // so the ratio of PANIC prices is (num / den)^2 with:
        (uint256 num, uint256 den) = panicIs0
            ? (uint256(sqrtPriceX96), uint256(refSqrtPriceX96))
            : (uint256(refSqrtPriceX96), uint256(sqrtPriceX96));
        if (num >= den) return 0;
        // ceil(num^2 * 1e18 / den^2), exactly. floor(floor(x / den) / den) == floor(x / den^2), and the
        // result is only bumped when some remainder was dropped along the way.
        uint256 scaled = num * 1e18; // < 2^160 * 2^60
        uint256 t = FullMath.mulDiv(scaled, num, den);
        uint256 dropped = mulmod(scaled, num, den) | (t % den);
        uint256 ratioE18 = t / den + (dropped == 0 ? 0 : 1);
        return (1e18 - ratioE18) / 1e14;
    }

    /// @notice PANIC amount worth `pairedAmount` of the paired currency at the given sqrt price, rounded down once.
    function pairedToPanicAtSqrtPrice(uint256 pairedAmount, uint160 sqrtPriceX96, bool panicIs0)
        public
        pure
        returns (uint256)
    {
        (uint256 num, uint256 den) =
            panicIs0 ? (FixedPoint96.Q96, uint256(sqrtPriceX96)) : (uint256(sqrtPriceX96), FixedPoint96.Q96);
        // Compute floor(pairedAmount * num^2 / den^2) without squaring a uint160 or losing the
        // first division's remainder. With pairedAmount*num = q*den + r, the missing correction
        // is floor(((q*num % den) + floor(r*num/den)) / den). Its numerator is < den + num,
        // so it fits in 161 bits. Only the final fractional PANIC unit is discarded.
        uint256 q = FullMath.mulDiv(pairedAmount, num, den);
        uint256 r = mulmod(pairedAmount, num, den);
        return FullMath.mulDiv(q, num, den) + (mulmod(q, num, den) + FullMath.mulDiv(r, num, den)) / den;
    }

    // ------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------

    function _requireOurPool(PoolKey calldata key) internal view {
        if (!poolRegistered) revert PoolNotRegistered();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert UnknownPool();
    }

    function _paired() internal view returns (Currency) {
        return panicIsCurrency0 ? poolKey.currency1 : poolKey.currency0;
    }

    /// @dev A buy moves paired currency into the pool and PANIC out.
    function _isBuy(bool zeroForOne) internal view returns (bool) {
        return zeroForOne != panicIsCurrency0;
    }

    function _split(uint256 fee) internal {
        uint256 toDonate = fee * LP_SHARE_BPS / BPS;
        uint256 toBurn = fee * BURN_SHARE_BPS / BPS;
        // The oracle fund takes the integer remainder so the three buckets always sum to the fee exactly.
        uint256 toOracle = fee - toDonate - toBurn;
        oracleFundBucket += toOracle;
        donationBucket += toDonate;
        burnBucket += toBurn;
        // Pay the liquidity present at the taxed swap's end, before a later caller can insert a
        // position solely to collect this fee. Keep claims only if no liquidity can receive them.
        uint256 pending = donationBucket;
        if (pending > 0 && poolManager.getLiquidity(poolId) > 0) {
            donationBucket = 0;
            _donate(pending);
            emit DonatedToLiquidityProviders(address(this), pending);
        }
    }

    function _donate(uint256 amount) internal {
        (uint256 amount0, uint256 amount1) = panicIsCurrency0 ? (uint256(0), amount) : (amount, uint256(0));
        poolManager.donate(poolKey, amount0, amount1, "");
        poolManager.burn(address(this), _paired().toId(), amount);
        totalDonated += amount;
    }

    /// @dev Takes this block's observation if it has not been taken yet, refreshes the window-start hint,
    /// and returns the reference price as a Q64.96 sqrt price.
    function _observeAndReference() internal returns (uint160 refSqrtPriceX96) {
        _observe();
        (int24 refTick, uint256 windowStart) = _reference();
        if (windowStart != windowStartHint) windowStartHint = windowStart;
        refSqrtPriceX96 = TickMath.getSqrtPriceAtTick(refTick);
    }

    /// @dev Records this block's observation from the pool price before any swap in it. At most once per block.
    function _observe() internal {
        if (lastObservedBlock == block.number) return;
        if (observations.length == 0) revert PoolNotRegistered();

        (, int24 tick,,) = poolManager.getSlot0(poolId);
        uint32 nowTs = uint32(block.timestamp);
        lastObservedBlock = block.number;
        lastObservedTick = tick;

        Observation memory last = observations[observations.length - 1];
        // Several blocks can share a timestamp on some chains. The accumulator cannot advance with zero
        // elapsed time, so such a block keeps the earlier observation for its second.
        if (nowTs == last.blockTimestamp) return;

        int56 cumulative = last.tickCumulative + int56(tick) * int56(uint56(nowTs - last.blockTimestamp));
        observations.push(Observation({blockTimestamp: nowTs, tickCumulative: cumulative}));
        emit ObservationRecorded(observations.length - 1, nowTs, tick, cumulative);
    }

    /// @dev The 1-hour mean tick and the index of the observation at or before the window start.
    /// Extrapolates from the last observation with the pre-swap tick of the current block (the live tick
    /// if no swap has happened in this block yet, which is the same thing).
    function _reference() internal view returns (int24 tick, uint256 windowStart) {
        uint256 n = observations.length;
        if (n == 0) revert PoolNotRegistered();

        Observation memory first = observations[0];
        Observation memory last = observations[n - 1];
        uint32 nowTs = uint32(block.timestamp);
        int24 prevailing = _prevailingTick();
        int56 cumNow = last.tickCumulative + int56(prevailing) * int56(uint56(nowTs - last.blockTimestamp));

        int56 cumTarget;
        if (block.timestamp <= uint256(first.blockTimestamp) + TWAP_WINDOW) {
            // The window starts before the pool existed. The launch price is taken to have prevailed
            // until the first observation, so the reference is a full hour long from the first block.
            uint256 before = uint256(first.blockTimestamp) + TWAP_WINDOW - block.timestamp;
            cumTarget = first.tickCumulative - int56(initialTick) * int56(uint56(before));
            windowStart = 0;
        } else {
            uint32 targetTs = nowTs - TWAP_WINDOW;
            windowStart = _findWindowStart(targetTs, n);
            Observation memory a = observations[windowStart];
            if (windowStart == n - 1) {
                // No observation for over an hour: the prevailing tick covered the whole window.
                cumTarget = a.tickCumulative + int56(prevailing) * int56(uint56(targetTs - a.blockTimestamp));
            } else {
                Observation memory b = observations[windowStart + 1];
                // b.cum - a.cum is exactly segmentTick * (b.ts - a.ts), so this division is exact.
                int56 segmentTick =
                    (b.tickCumulative - a.tickCumulative) / int56(uint56(b.blockTimestamp - a.blockTimestamp));
                cumTarget = a.tickCumulative + segmentTick * int56(uint56(targetTs - a.blockTimestamp));
            }
        }
        tick = _meanTick(cumNow - cumTarget, TWAP_WINDOW);
    }

    /// @dev The tick that has prevailed since the last observation: the live tick when no swap has run
    /// in this block, otherwise the pre-swap tick recorded for this block (identical by construction).
    function _prevailingTick() internal view returns (int24 tick) {
        if (lastObservedBlock == block.number) return lastObservedTick;
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    /// @dev Largest observation index whose timestamp is at or before `targetTs`. Starts at the stored hint
    /// (the window start only moves forward) and gallops before a bounded binary search.
    function _findWindowStart(uint32 targetTs, uint256 n) internal view returns (uint256) {
        uint256 lo = windowStartHint;
        if (lo >= n || observations[lo].blockTimestamp > targetTs) lo = 0;
        uint256 hi = n - 1;

        uint256 step = 1;
        while (lo + step <= hi && observations[lo + step].blockTimestamp <= targetTs) {
            lo += step;
            step <<= 1;
        }
        if (lo + step < hi) hi = lo + step;

        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (observations[mid].blockTimestamp <= targetTs) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    /// @dev Floor division of a tick-seconds delta by a duration (rounds toward negative infinity).
    function _meanTick(int56 cumulativeDelta, uint32 duration) internal pure returns (int24) {
        int56 q = cumulativeDelta / int56(uint56(duration));
        if (cumulativeDelta < 0 && cumulativeDelta % int56(uint56(duration)) != 0) q--;
        return int24(q);
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
