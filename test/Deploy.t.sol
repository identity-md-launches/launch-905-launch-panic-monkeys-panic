// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {DeployPanic} from "../script/DeployPanic.s.sol";
import {PanicMonkeys} from "../src/PanicMonkeys.sol";
import {PanicHook} from "../src/PanicHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice The deploy script's `deploy` function, driven directly with an explicit configuration.
contract DeployTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolManager manager;
    DeployPanic script;
    address oracleFund = makeAddr("oracleFund");
    address recipient = makeAddr("recipient");

    function setUp() public {
        manager = new PoolManager(address(this));
        script = new DeployPanic();
    }

    function _config() internal view returns (DeployPanic.Config memory) {
        return DeployPanic.Config({
            poolManager: IPoolManager(address(manager)),
            oracleFund: oracleFund,
            tokenRecipient: recipient,
            create2Deployer: address(script),
            lpFee: 12_500,
            tickSpacing: 250,
            sqrtPriceX96: SQRT_PRICE_1_1
        });
    }

    function test_deployProducesTokenHookAndPool() public {
        (PanicMonkeys token, PanicHook hook, PoolKey memory key) = script.deploy(_config());

        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(recipient), 10 ** 27, "whole supply handed to the recipient");

        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.PANIC_HOOK, "mined address carries the flags");
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.panic(), address(token));
        assertEq(hook.oracleFund(), oracleFund);

        assertEq(Currency.unwrap(key.currency0), address(0), "native ETH pair");
        assertEq(Currency.unwrap(key.currency1), address(token));
        assertEq(key.fee, 12_500);
        assertEq(key.tickSpacing, 250);
        assertEq(address(key.hooks), address(hook));

        (uint160 sqrtPriceX96,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "pool initialized at the configured price");
        assertEq(lpFee, 12_500);
        assertTrue(hook.poolRegistered());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(hook.observationCount(), 1);
    }

    function test_deployIsRepeatableWithFreshState() public {
        (, PanicHook a,) = script.deploy(_config());
        DeployPanic again = new DeployPanic();
        DeployPanic.Config memory cfg = _config();
        cfg.create2Deployer = address(again);
        (, PanicHook b,) = again.deploy(cfg);
        assertTrue(address(a) != address(b));
        assertEq(HookFlags.flagsOf(address(b)), HookFlags.PANIC_HOOK);
    }
}
