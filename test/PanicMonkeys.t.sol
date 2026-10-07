// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PanicMonkeys} from "../src/PanicMonkeys.sol";

contract PanicMonkeysTest is Test {
    PanicMonkeys token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new PanicMonkeys();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Panic Monkeys");
        assertEq(token.symbol(), "PANIC");
        assertEq(token.decimals(), 18);
    }

    function test_mintsExactlyOneBillionToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234 ether;
        uint256 before = token.balanceOf(address(this));
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), before - amount);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PanicMonkeys.InsufficientBalance.selector, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(PanicMonkeys.TransferToZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 60 ether);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 50 ether));
        assertEq(token.balanceOf(bob), 50 ether);
        assertEq(token.allowance(alice, bob), 10 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PanicMonkeys.InsufficientAllowance.selector, 10 ether, 11 ether));
        token.transferFrom(alice, bob, 11 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(address(this), alice, 5 ether);
        assertEq(token.allowance(address(this), bob), type(uint256).max);
    }

    function test_noMintOrAdminEntrypoints() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
