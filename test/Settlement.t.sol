// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JackpotFixture} from "./JackpotFixture.sol";
import {AdversarialToken, RefundReceiver} from "./mocks/AdversarialActors.sol";
import {LastBuyerJackpotHook} from "../src/LastBuyerJackpotHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract SettlementTest is JackpotFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function adversarialPool() internal returns (PoolKey memory other, AdversarialToken asset) {
        asset = new AdversarialToken();
        other = key;
        other.currency1 = Currency.wrap(address(asset));
        asset.approve(address(modifyLiquidityRouter), type(uint256).max);
        manager.initialize(other, TickMath.getSqrtPriceAtTick(START_TICK));
        modifyLiquidityRouter.modifyLiquidity(other, ModifyLiquidityParams(137_940, 138_000, 100e18, 0), "");
    }

    function test_partialBuyRefundsOnlyUnspentInputAndChargesOnce() public {
        PoolKey memory other = secondPool();
        uint256 managerBefore = address(manager).balance;
        uint256 buyerBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));
        // An unrelated forced balance must not be swept into the buyer's refund.
        vm.deal(address(hook), 7 wei);
        vm.recordLogs();
        uint256 received = jackpotHook.buy{value: 1 ether}(other, 1);
        uint256 gross = grossOutput(vm.getRecordedLogs());
        uint256 spent = address(manager).balance - managerBefore;
        assertGt(spent, 0);
        assertLt(spent, 0.001 ether);
        assertEq(buyerBefore - address(this).balance, spent);
        assertEq(address(hook).balance, 7);
        assertEq(token.balanceOf(address(this)) - tokenBefore, received);
        assertEq(received, gross - gross / 100);
        assertEq(jackpotHook.jackpot(other.toId()), gross / 100);
        // Qualification uses specified input, as required, including partial fills.
        assertEq(jackpotHook.lastBuyer(other.toId()), address(this));
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), jackpotHook.jackpot(id) + gross / 100);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_rejectedRefundRollsBackSwapAndAccounting() public {
        PoolKey memory other = secondPool();
        RefundReceiver receiver = new RefundReceiver(jackpotHook);
        (uint160 priceBefore,,,) = manager.getSlot0(other.toId());
        uint256 firstPot = jackpotHook.jackpot(id);
        uint256 managerBefore = address(manager).balance;
        vm.expectRevert(LastBuyerJackpotHook.RefundFailed.selector);
        receiver.execute{value: 1 ether}(other, true);
        (uint160 priceAfter,,,) = manager.getSlot0(other.toId());
        assertEq(priceBefore, priceAfter);
        assertEq(jackpotHook.jackpot(other.toId()), 0);
        assertEq(jackpotHook.lastBuyer(other.toId()), address(0));
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(address(manager).balance, managerBefore);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), firstPot);
        assertEq(address(hook).balance, 0);
    }

    function test_refundCannotReenterBuyOrClaim() public {
        PoolKey memory other = secondPool();
        RefundReceiver receiver = new RefundReceiver(jackpotHook);
        receiver.execute{value: 1 ether}(other, false);
        assertTrue(receiver.attempted());
        assertFalse(receiver.buyReentered());
        assertFalse(receiver.claimReentered());
        assertEq(receiver.buyError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(receiver.claimError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(jackpotHook.lastBuyer(other.toId()), address(receiver));
        assertEq(
            manager.balanceOf(address(hook), key.currency1.toId()),
            jackpotHook.jackpot(id) + jackpotHook.jackpot(other.toId())
        );
        assertEq(address(hook).balance, 0);
    }

    function test_failedTokenPayoutPreservesRoundAndCanRetry() public {
        (PoolKey memory other, AdversarialToken asset) = adversarialPool();
        swap(other, true, -0.001 ether, abi.encode(ALICE));
        PoolId otherId = other.toId();
        uint256 pot = jackpotHook.jackpot(otherId);
        uint256 timestamp = jackpotHook.lastBuyAt(otherId);
        vm.warp(timestamp + 3600);
        asset.setFailure(true);
        vm.expectRevert(); // PoolManager wraps the ERC20's failed transfer.
        jackpotHook.claim(other);
        assertEq(jackpotHook.jackpot(otherId), pot);
        assertEq(jackpotHook.lastBuyer(otherId), ALICE);
        assertEq(jackpotHook.lastBuyAt(otherId), timestamp);
        assertEq(jackpotHook.round(otherId), 0);
        assertEq(manager.balanceOf(address(hook), other.currency1.toId()), pot);
        assertEq(asset.balanceOf(ALICE), 0);
        asset.setFailure(false);
        vm.prank(BOB);
        jackpotHook.claim(other);
        assertEq(asset.balanceOf(ALICE), pot);
        assertEq(jackpotHook.round(otherId), 1);
        assertEq(manager.balanceOf(address(hook), other.currency1.toId()), 0);
    }

    function test_failedWalletTokenTransferRollsBackFeeAndETH() public {
        (PoolKey memory other, AdversarialToken asset) = adversarialPool();
        (uint160 priceBefore,,,) = manager.getSlot0(other.toId());
        asset.setFailure(true);
        vm.expectRevert();
        jackpotHook.buy{value: 0.001 ether}(other, 1);
        (uint160 priceAfter,,,) = manager.getSlot0(other.toId());
        assertEq(priceBefore, priceAfter);
        assertEq(jackpotHook.jackpot(other.toId()), 0);
        assertEq(jackpotHook.lastBuyer(other.toId()), address(0));
        assertEq(manager.balanceOf(address(hook), other.currency1.toId()), 0);
        assertEq(address(manager).balance, 0);
        assertEq(address(hook).balance, 0);
        asset.setFailure(false);
        assertGt(jackpotHook.buy{value: 0.001 ether}(other, 1), 0);
    }

    function test_claimResetsBeforeTokenCallAndRejectsReentrancy() public {
        (PoolKey memory other, AdversarialToken asset) = adversarialPool();
        swap(other, true, -0.001 ether, abi.encode(ALICE));
        uint256 pot = jackpotHook.jackpot(other.toId());
        vm.warp(block.timestamp + 3600);
        asset.arm(jackpotHook, other);
        jackpotHook.claim(other);
        assertTrue(asset.sawReset());
        assertFalse(asset.reentered());
        assertEq(asset.rejection(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(asset.balanceOf(ALICE), pot);
        assertEq(manager.balanceOf(address(hook), other.currency1.toId()), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_noApprovalLetsAnAttackerTransferJackpotClaims() public {
        swap(key, true, -0.001 ether, abi.encode(ALICE));
        vm.prank(BOB);
        vm.expectRevert();
        manager.transferFrom(address(hook), BOB, key.currency1.toId(), 1);
        assertFalse(manager.isOperator(address(hook), BOB));
        assertEq(manager.allowance(address(hook), BOB, key.currency1.toId()), 0);
        assertBacked();
    }

    function test_claimCannotBeRedirectedWithAChangedPoolKey() public {
        swap(key, true, -0.001 ether, abi.encode(ALICE));
        vm.warp(block.timestamp + 3600);
        PoolKey memory forged = key;
        forged.fee = 500;
        vm.expectRevert(LastBuyerJackpotHook.NothingToClaim.selector);
        jackpotHook.claim(forged);
        assertBacked();
        jackpotHook.claim(key);
        assertGt(token.balanceOf(ALICE), 0);
    }

    function test_unsolicitedClaimsCannotBeStolenOrBecomeAnotherPoolsJackpot() public {
        swap(key, true, -0.001 ether, abi.encode(ALICE));
        uint256 pot = jackpotHook.jackpot(id);
        // ERC6909 transfers are permissionless. Donations necessarily create surplus
        // backing, not a new entitlement or a way to withdraw another pool's claims.
        swapRouter.swap{value: 0.01 ether}(
            key, SwapParams(true, 100 ether, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(true, false), ""
        );
        manager.transfer(address(hook), key.currency1.toId(), 1 ether);
        assertEq(jackpotHook.jackpot(id), pot);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), pot + 1 ether);
        vm.warp(block.timestamp + 3600);
        jackpotHook.claim(key);
        assertEq(token.balanceOf(ALICE), pot);
        assertEq(jackpotHook.jackpot(id), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 1 ether);
    }

    function test_feeFloorsToZeroForOutputUnder100BaseUnits() public {
        jackpotHook.buy{value: 0.001 ether}(key, 0);
        PoolKey memory tiny = key;
        tiny.fee = 500;
        manager.initialize(tiny, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(tiny, ModifyLiquidityParams(-60, 0, 1 ether, 0), "");
        vm.recordLogs();
        uint256 received = jackpotHook.buy{value: 99}(tiny, 1);
        uint256 gross = grossOutput(vm.getRecordedLogs());
        assertGt(gross, 0);
        assertLt(gross, 100);
        assertEq(gross, received);
        assertEq(jackpotHook.jackpot(tiny.toId()), 0);
        assertEq(jackpotHook.lastBuyer(tiny.toId()), address(0));
        assertBacked();
    }
}
