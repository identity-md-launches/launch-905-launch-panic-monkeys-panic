// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PanicAccountingHandler} from "./handlers/PanicAccountingHandler.sol";
import {PanicTestBase} from "./utils/PanicTestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev No storage edits, mocked callbacks, RPC, or token minting after setup. Each campaign
/// starts at a flat price and can cross all tiers in either direction, in the same or later blocks.
abstract contract PanicAccountingInvariantBase is PanicTestBase {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    PanicAccountingHandler internal handler;

    function _startCampaign() internal {
        _fundAndApprove();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
        handler = new PanicAccountingHandler(hook, panic, IPoolManager(address(manager)), swapRouter, key);
        for (uint256 i; i < 3; i++) {
            address actor = handler.actors(i);
            panic.transfer(actor, 1e25);
            vm.deal(actor, 1e25);
            if (!paired.isAddressZero()) MockERC20(Currency.unwrap(paired)).transfer(actor, 1e25);
            vm.startPrank(actor);
            panic.approve(address(swapRouter), type(uint256).max);
            if (!paired.isAddressZero()) {
                MockERC20(Currency.unwrap(paired)).approve(address(swapRouter), type(uint256).max);
            }
            vm.stopPrank();
        }
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.sell.selector;
        selectors[1] = handler.buy.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.buyback.selector;
        selectors[6] = handler.transferPanic.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationReferenceAndSupply() public view virtual {
        uint256 outstanding = hook.oracleFundBucket() + hook.donationBucket() + hook.burnBucket();
        assertEq(manager.balanceOf(address(hook), paired.toId()), outstanding, "every obligation backed by claims");
        assertEq(hook.totalAccruedFees(), outstanding);
        assertEq(
            outstanding + handler.claimed() + hook.totalDonated() + handler.spent(),
            handler.fees(),
            "all fees accounted for"
        );
        assertEq(hook.oracleFundBucket() + handler.claimed(), handler.expectedOracle(), "oracle allocation");
        assertEq(hook.donationBucket() + hook.totalDonated(), handler.expectedLp(), "LP allocation");
        assertEq(hook.burnBucket() + handler.spent(), handler.expectedBurn(), "burn allocation");
        assertEq(paired.balanceOf(oracleFund), handler.claimed(), "only the budget wallet receives claims");
        assertEq(panic.balanceOf(DEAD), handler.burned(), "all bought PANIC sent to dead address");
        assertEq(paired.balanceOf(address(hook)), 0, "no loose paired currency");
        assertEq(panic.balanceOf(address(hook)), 0, "no stranded PANIC");
        assertEq(hook.referenceTick(), handler.modelReferenceTick(), "one-hour independent reference");

        uint256 tracked = panic.balanceOf(address(this)) + panic.balanceOf(address(manager)) + panic.balanceOf(DEAD);
        for (uint256 i; i < 3; i++) {
            tracked += panic.balanceOf(handler.actors(i));
        }
        assertEq(tracked, 1_000_000_000 ether, "supply conserved across pool and all holders");
        assertEq(panic.totalSupply(), tracked);
        assertEq(panic.balanceOf(address(0)), 0);
        assertEq(panic.balanceOf(address(swapRouter)), 0);
        assertEq(panic.balanceOf(address(lpRouter)), 0);
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0, "all v4 debts settled");
        assertFalse(IPoolManager(address(manager)).isUnlocked(), "manager relocked after each action");
    }

    /// @dev Exercise successful and failed outlets deterministically so the campaign is not
    /// trusted merely because an empty bucket happened to satisfy the accounting identities.
    function test_handlerExercisesFundedAndRejectedOperations() public {
        handler.claim(0);
        handler.donate(1);
        handler.buyback(2, 0);
        handler.sell(0, 1200 ether);
        handler.buy(1, 1 ether);
        handler.buyback(2, 0.1 ether);
        handler.claim(1);
        handler.advance(3600);
        handler.buy(2, 200 ether);
        handler.buy(2, 200 ether);
        handler.buyback(0, 1 ether);
        assertEq(handler.successfulSwaps(), 4);
        assertGt(handler.successfulBuybacks(), 0);
        assertGe(handler.rejectedBuybacks(), 2);
        assertGt(handler.claimed(), 0);
        invariant_conservationReferenceAndSupply();
    }
}

contract PanicNativeInvariantTest is PanicAccountingInvariantBase {
    function setUp() public {
        _setUpNativePool(SQRT_PRICE_1_1);
        _startCampaign();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationReferenceAndSupply() public view override {
        super.invariant_conservationReferenceAndSupply();
    }
}

contract PanicCurrency0InvariantTest is PanicAccountingInvariantBase {
    function setUp() public {
        _setUpErc20Pool(true, SQRT_PRICE_1_1);
        _startCampaign();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationReferenceAndSupply() public view override {
        super.invariant_conservationReferenceAndSupply();
    }
}

contract PanicCurrency1InvariantTest is PanicAccountingInvariantBase {
    function setUp() public {
        _setUpErc20Pool(false, SQRT_PRICE_1_1);
        _startCampaign();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationReferenceAndSupply() public view override {
        super.invariant_conservationReferenceAndSupply();
    }
}
