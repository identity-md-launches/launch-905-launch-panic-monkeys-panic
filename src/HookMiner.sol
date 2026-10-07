// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "./HookFlags.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt that places a hook on an address carrying the required permission bits.
/// @dev Pure library used by the deploy script and the tests. The deployer address must be the account
/// that will actually execute CREATE2 (a factory, the deterministic deployer proxy, or a test contract).
library HookMiner {
    error NoSaltFound(uint160 flags, uint256 attempts);

    /// @notice Mines a salt starting at `startSalt` such that CREATE2 from `deployer` lands on an
    /// address whose low 14 bits equal `flags`.
    /// @param deployer The address that will perform the CREATE2.
    /// @param flags The required permission bits (compared under `HookFlags.ALL`).
    /// @param creationCode The full creation code including ABI-encoded constructor arguments.
    /// @param startSalt The first salt to try (lets a caller resume or avoid a used salt).
    /// @param maxAttempts Upper bound on salts tried before reverting.
    function find(address deployer, uint160 flags, bytes memory creationCode, uint256 startSalt, uint256 maxAttempts)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < maxAttempts; i++) {
            salt = bytes32(startSalt + i);
            hook = computeAddress(deployer, salt, initCodeHash);
            if (HookFlags.matches(hook, flags)) return (hook, salt);
        }
        revert NoSaltFound(flags, maxAttempts);
    }

    /// @notice The CREATE2 address for the given deployer, salt and init code hash.
    /// @dev Hashes in scratch memory without allocating, so a long mining loop does not pay quadratic
    /// memory-expansion gas (which made in-test mining cost well over 100M gas).
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address addr) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), initCodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer)
            let start := add(ptr, 0x0b)
            mstore8(start, 0xff)
            addr := and(keccak256(start, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
