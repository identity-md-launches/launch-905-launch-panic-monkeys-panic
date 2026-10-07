// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PanicMonkeys} from "src/PanicMonkeys.sol";

contract PanicTokenHandler is Test {
    PanicMonkeys public immutable token;
    address[4] public actors = [address(0x1101), address(0x1102), address(0x1103), address(0x1104)];
    address constant DEAD = address(0xdEaD);
    uint256 constant SUPPLY = 1_000_000_000 ether;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    constructor(PanicMonkeys t) {
        token = t;
        balances[actors[0]] = SUPPLY;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 4];
        address to = toSeed % 5 == 4 ? DEAD : actors[toSeed % 5];
        uint256 amount = bound(amountSeed, 0, balances[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        balances[from] -= amount;
        balances[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool unlimited) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = unlimited ? type(uint256).max : bound(amountSeed, 0, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        allowances[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = toSeed % 5 == 4 ? DEAD : actors[toSeed % 5];
        uint256 allowed = allowances[owner][spender];
        // Exercise both valid transfers and exact insufficient-balance/allowance failures.
        uint256 maximum = amountSeed % 2 == 0 ? balances[owner] : SUPPLY + 1;
        uint256 amount = bound(amountSeed, 0, maximum);
        vm.prank(spender);
        if (allowed < amount) {
            vm.expectRevert(abi.encodeWithSelector(PanicMonkeys.InsufficientAllowance.selector, allowed, amount));
            token.transferFrom(owner, to, amount);
        } else if (balances[owner] < amount) {
            vm.expectRevert(abi.encodeWithSelector(PanicMonkeys.InsufficientBalance.selector, balances[owner], amount));
            token.transferFrom(owner, to, amount);
        } else {
            assertTrue(token.transferFrom(owner, to, amount));
            balances[owner] -= amount;
            balances[to] += amount;
            if (allowed != type(uint256).max) allowances[owner][spender] -= amount;
        }
    }
}

contract PanicMonkeysPropertiesTest is Test {
    PanicMonkeys internal token;
    PanicTokenHandler internal handler;

    function setUp() public {
        token = new PanicMonkeys();
        handler = new PanicTokenHandler(token);
        token.transfer(handler.actors(0), token.totalSupply());
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyBalancesAndAllowancesMatchIndependentLedger() public view {
        uint256 total = token.balanceOf(address(0xdEaD));
        assertEq(total, handler.balances(address(0xdEaD)));
        for (uint256 i; i < 4; i++) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.balances(actor));
            total += balance;
            for (uint256 j; j < 4; j++) {
                address spender = handler.actors(j);
                assertEq(token.allowance(actor, spender), handler.allowances(actor, spender));
            }
        }
        assertEq(total, 1_000_000_000 ether);
        assertEq(token.totalSupply(), total);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromFailureRestoresFiniteAllowance(uint256 allowanceSeed) public {
        address owner = handler.actors(1); // deliberately empty
        uint256 amount = bound(allowanceSeed, 1, type(uint256).max - 1);
        address recipient = handler.actors(2);
        vm.prank(owner);
        token.approve(address(this), amount);
        vm.expectRevert(abi.encodeWithSelector(PanicMonkeys.InsufficientBalance.selector, 0, amount));
        token.transferFrom(owner, recipient, amount);
        assertEq(token.allowance(owner, address(this)), amount, "revert restores allowance spent before transfer");
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(handler.actors(2)), 0);
    }

    function test_zeroAddressFailurePreservesBalanceAndAllowance() public {
        address owner = handler.actors(0);
        vm.prank(owner);
        token.approve(address(this), 1);
        uint256 balance = token.balanceOf(owner);
        vm.expectRevert(PanicMonkeys.TransferToZeroAddress.selector);
        token.transferFrom(owner, address(0), 1);
        assertEq(token.balanceOf(owner), balance);
        assertEq(token.allowance(owner, address(this)), 1);
    }

    function test_selfTransferOfFullSupplyAndZeroTransferFrom() public {
        address owner = handler.actors(0);
        uint256 supply = token.totalSupply();
        vm.prank(owner);
        assertTrue(token.transfer(owner, supply));
        assertEq(token.balanceOf(owner), supply);
        // Zero transfers require neither a balance nor an allowance.
        assertTrue(token.transferFrom(handler.actors(1), owner, 0));
        assertEq(token.balanceOf(owner), supply);
        assertEq(token.allowance(handler.actors(1), address(this)), 0);
    }
}
