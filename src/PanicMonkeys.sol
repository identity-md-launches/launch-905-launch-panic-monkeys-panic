// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Panic Monkeys ($PANIC)
/// @notice Fixed-supply ERC-20 launch token. The whole supply is minted once, to the deployer, in the
/// constructor. There is no owner, no mint, no pause, no blocklist, no transfer fee and no upgrade path.
/// Every trading rule of the launch lives in the Uniswap v4 hook (`PanicHook`), never in the token.
contract PanicMonkeys {
    string public constant name = "Panic Monkeys";
    string public constant symbol = "PANIC";
    uint8 public constant decimals = 18;

    /// @notice 1,000,000,000 PANIC in 18-decimal minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    uint256 public immutable totalSupply;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 available, uint256 required);
    error TransferToZeroAddress();

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance(allowed, value);
            unchecked {
                allowance[from][msg.sender] = allowed - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert TransferToZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert InsufficientBalance(fromBalance, value);
        unchecked {
            balanceOf[from] = fromBalance - value;
            // Total supply is fixed, so no balance can exceed it and this cannot overflow.
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
