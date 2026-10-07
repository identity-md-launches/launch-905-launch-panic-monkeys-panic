// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PanicMonkeys} from "../src/PanicMonkeys.sol";
import {PanicHook} from "../src/PanicHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @title DeployPanic
/// @notice Reference deployment: token, hook at a mined CREATE2 address, and the PANIC/ETH pool.
/// @dev The IdentityMD launch factory performs these steps itself from the manifest; this script documents
/// the exact sequence and lets the tests exercise it. `run()` is the only place that reads the environment.
contract DeployPanic is Script {
    /// @dev The deterministic CREATE2 proxy forge uses for `new X{salt: s}()` under a broadcast.
    address public constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Config {
        /// The chain's Uniswap v4 PoolManager. Never hardcoded.
        IPoolManager poolManager;
        /// The oracle budget address (the paying wallet). Fixed in the hook forever.
        address oracleFund;
        /// Who receives the whole PANIC supply the token constructor mints to this contract.
        address tokenRecipient;
        /// The address that will execute CREATE2 for the hook (proxy under broadcast, this contract in tests).
        address create2Deployer;
        /// LP fee tier of the pool. The launch policy's tier is 12500 (1.25%).
        uint24 lpFee;
        /// Tick spacing of the pool.
        int24 tickSpacing;
        /// Initial sqrt price (Q64.96) of the pool, price = PANIC per ETH when ETH is currency0.
        uint160 sqrtPriceX96;
    }

    function run() external {
        Config memory cfg = Config({
            poolManager: IPoolManager(vm.envAddress("POOL_MANAGER")),
            oracleFund: vm.envAddress("ORACLE_FUND"),
            tokenRecipient: vm.envAddress("TOKEN_RECIPIENT"),
            create2Deployer: CREATE2_PROXY,
            lpFee: uint24(vm.envOr("LP_FEE", uint256(12_500))),
            tickSpacing: int24(int256(vm.envOr("TICK_SPACING", uint256(250)))),
            sqrtPriceX96: uint160(vm.envUint("SQRT_PRICE_X96"))
        });
        vm.startBroadcast();
        deploy(cfg);
        vm.stopBroadcast();
    }

    /// @notice Deploys the token and hook, then initializes the PANIC/native-ETH pool.
    function deploy(Config memory cfg) public returns (PanicMonkeys token, PanicHook hook, PoolKey memory key) {
        token = new PanicMonkeys();
        if (cfg.tokenRecipient != address(this)) token.transfer(cfg.tokenRecipient, token.totalSupply());

        bytes memory creationCode =
            abi.encodePacked(type(PanicHook).creationCode, abi.encode(cfg.poolManager, address(token), cfg.oracleFund));
        (address predicted, bytes32 salt) =
            HookMiner.find(cfg.create2Deployer, HookFlags.PANIC_HOOK, creationCode, 0, 1_000_000);

        hook = new PanicHook{salt: salt}(cfg.poolManager, address(token), cfg.oracleFund);
        require(address(hook) == predicted, "hook landed on an unexpected address");

        // Native ETH is address(0), so it always sorts first.
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: cfg.lpFee,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(address(hook))
        });
        cfg.poolManager.initialize(key, cfg.sqrtPriceX96);
    }
}
