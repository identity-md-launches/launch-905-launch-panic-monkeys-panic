// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PanicHook} from "../src/PanicHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PanicTestBase} from "./utils/PanicTestBase.sol";

/// @notice Deployment, pool registration and access control of the hook.
contract PanicHookInitTest is PanicTestBase {
    function setUp() public {
        _setUpNativePool(SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------- permissions and address

    function test_permissionsMatchDeclaredFlagsAndAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.afterInitialize, "init callbacks");
        assertTrue(p.beforeSwap && p.afterSwap, "swap callbacks");
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta, "swap return deltas");
        assertFalse(
            p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity
                || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta,
            "no other permissions"
        );
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.PANIC_HOOK, "address bits");
        assertEq(hook.REQUIRED_FLAGS(), HookFlags.PANIC_HOOK);
        assertTrue(HookFlags.matches(address(hook), HookFlags.PANIC_HOOK));
    }

    function test_constructorStoresImmutables() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.panic(), address(panic));
        assertEq(hook.oracleFund(), oracleFund);
    }

    function test_constructorRejectsZeroAddresses() public {
        // Deploying through plain CREATE would also fail the flag check, so probe with a mined salt each time.
        bytes memory code =
            abi.encodePacked(type(PanicHook).creationCode, abi.encode(address(0), address(panic), oracleFund));
        _expectCreate2Revert(code);
        code = abi.encodePacked(type(PanicHook).creationCode, abi.encode(address(manager), address(0), oracleFund));
        _expectCreate2Revert(code);
        code = abi.encodePacked(type(PanicHook).creationCode, abi.encode(address(manager), address(panic), address(0)));
        _expectCreate2Revert(code);
    }

    function _expectCreate2Revert(bytes memory code) internal {
        (, bytes32 salt) = _mine(code);
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(code, 0x20), mload(code), salt)
        }
        assertEq(at, address(0), "deployment should have reverted");
    }

    function _mine(bytes memory code) internal view returns (address, bytes32) {
        bytes32 h = keccak256(code);
        for (uint256 i = 0; i < 1_000_000; i++) {
            address a =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), h)))));
            if (HookFlags.matches(a, HookFlags.PANIC_HOOK)) return (a, bytes32(i));
        }
        revert("no salt");
    }

    function test_constructorRejectsAddressWithoutFlags() public {
        // Plain CREATE lands on an address whose low bits almost surely disagree with the permissions.
        vm.expectRevert();
        new PanicHook(IPoolManager(address(manager)), address(panic), oracleFund);
    }

    // ---------------------------------------------------------------- initialization

    function test_initializationRegistersPoolAndFirstObservation() public view {
        assertTrue(hook.poolRegistered());
        assertFalse(hook.panicIsCurrency0(), "ETH is address(0) so PANIC is currency1");
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(poolId));
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks hooks) = hook.poolKey();
        assertEq(Currency.unwrap(c0), address(0));
        assertEq(Currency.unwrap(c1), address(panic));
        assertEq(fee, LP_FEE);
        assertEq(spacing, TICK_SPACING);
        assertEq(address(hooks), address(hook));
        assertEq(Currency.unwrap(hook.pairedCurrency()), address(0));

        assertEq(hook.observationCount(), 1);
        (uint32 ts, int56 cum) = hook.observations(0);
        assertEq(ts, uint32(block.timestamp));
        assertEq(cum, 0);
        assertEq(hook.lastObservedBlock(), block.number);
        assertEq(hook.initialTick(), 0);
        assertEq(hook.referenceTick(), 0);
        assertEq(hook.referenceSqrtPriceX96(), SQRT_PRICE_1_1);
        assertEq(hook.currentDrawdownBps(), 0);
    }

    function test_secondPoolCannotBeRegistered() public {
        PoolKey memory other = key;
        other.fee = 3_000;
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.beforeInitialize.selector, abi.encodeWithSelector(PanicHook.PoolAlreadyRegistered.selector)
            )
        );
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_poolWithoutPanicIsRefused() public {
        PanicHook fresh = _deployHook(IPoolManager(address(manager)), address(panic), oracleFund);
        MockERC20 a = new MockERC20("A", "A", 1e24);
        MockERC20 b = new MockERC20("B", "B", 1e24);
        (address lo, address hi) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        PoolKey memory bad = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(fresh))
        });
        vm.expectRevert(
            _wrappedHookRevert(
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(PanicHook.PoolMustContainPanic.selector)
            )
        );
        manager.initialize(bad, SQRT_PRICE_1_1);
        assertFalse(fresh.poolRegistered());
    }

    function test_dynamicFeePoolIsRefused() public {
        PanicHook fresh = _deployHook(IPoolManager(address(manager)), address(panic), oracleFund);
        PoolKey memory dyn = key;
        dyn.hooks = IHooks(address(fresh));
        dyn.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.expectRevert(
            _wrappedHookRevert(
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(PanicHook.DynamicFeeNotSupported.selector)
            )
        );
        manager.initialize(dyn, SQRT_PRICE_1_1);
    }

    function test_anyStaticLpFeeTierIsAccepted() public {
        uint24[3] memory fees = [uint24(500), uint24(3_000), uint24(12_500)];
        for (uint256 i = 0; i < fees.length; i++) {
            PanicHook fresh = _deployHook(IPoolManager(address(manager)), address(panic), oracleFund);
            PoolKey memory k = key;
            k.hooks = IHooks(address(fresh));
            k.fee = fees[i];
            manager.initialize(k, SQRT_PRICE_1_1);
            assertTrue(fresh.poolRegistered());
        }
    }

    // ---------------------------------------------------------------- access control

    function test_enabledCallbacksRefuseCallersOtherThanThePoolManager() public {
        SwapParams memory sp = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        vm.expectRevert(PanicHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(PanicHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(PanicHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, sp, "");
        vm.expectRevert(PanicHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, sp, BalanceDelta.wrap(0), "");
        vm.expectRevert(PanicHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(1), uint256(1)));
    }

    function test_unlockCallbackCannotBeDrivenByAnyoneElse() public {
        // Even with a well-formed payload, only the PoolManager may call back, and the manager only
        // calls back the account that unlocked it, which is the hook itself.
        vm.prank(trader);
        vm.expectRevert(PanicHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(3), uint256(1 ether)));
    }

    function test_disabledCallbacksRevert() public {
        ModifyLiquidityParams memory mp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        vm.expectRevert(PanicHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, mp, "");
        vm.expectRevert(PanicHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(PanicHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, mp, "");
        vm.expectRevert(PanicHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(PanicHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(PanicHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
    }

    function test_poolManagerIsTheOnlyPathIntoSwapCallbacks() public {
        // A forged afterSwap from the manager's address without a beforeSwap in the same transaction
        // has no swap kind to act on and reverts rather than minting anything.
        vm.prank(address(manager));
        vm.expectRevert(PanicHook.HookNotImplemented.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, 0), BalanceDelta.wrap(0), "");
        assertEq(hook.totalAccruedFees(), 0);
    }

    function test_noAdminSurface() public {
        string[8] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "setFee(uint256)",
            "setOracleFund(address)",
            "upgradeTo(address)",
            "withdraw(address,uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], address(this), uint256(1)));
            assertFalse(ok, signatures[i]);
        }
    }

    function test_runtimeCodeHasNoEscapeHatchAndFitsEip170() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff, "SELFDESTRUCT");
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
        }
    }
}
