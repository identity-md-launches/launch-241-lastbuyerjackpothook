// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JackpotFixture} from "./JackpotFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {LastBuyerJackpotHook} from "../src/LastBuyerJackpotHook.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract LastBuyerJackpotHookTest is JackpotFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function test_permissionsAndMinedConstructor() public {
        assertEq(flagsOf(hook.getHookPermissions()), 0x44);
        assertEq(HookFlags.flagsOf(address(hook)), 0x44);
        assertEq(address(hook.poolManager()), address(manager));

        bytes memory init = abi.encodePacked(type(LastBuyerJackpotHook).creationCode, abi.encode(manager));
        bytes32 hash = keccak256(init);
        for (uint256 salt; salt < 200_000; ++salt) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (!HookFlags.matches(predicted, 0x44)) continue;
            LastBuyerJackpotHook deployed = new LastBuyerJackpotHook{salt: bytes32(salt)}(manager);
            assertEq(address(deployed), predicted);
            assertEq(flagsOf(deployed.getHookPermissions()), 0x44);
            return;
        }
        fail("no CREATE2 salt found");
    }

    function test_constructorRejectsWrongAddressFlags() public {
        bytes memory init = abi.encodePacked(type(LastBuyerJackpotHook).creationCode, abi.encode(manager));
        bytes32 hash = keccak256(init);
        uint256 salt;
        address predicted;
        do {
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), ++salt, hash)))));
        } while (HookFlags.matches(predicted, 0x44));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new LastBuyerJackpotHook{salt: bytes32(salt)}(manager);
    }

    function test_afterSwapAndUnlockRejectNonManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(
            ALICE, key, SwapParams(true, -1 ether, MIN_PRICE_LIMIT), BalanceDeltaLibrary.ZERO_DELTA, abi.encode(ALICE)
        );
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        jackpotHook.unlockCallback("");
    }

    function test_unsolicitedManagerCallbackCannotSpendClaims() public {
        swap(key, true, -1 ether, abi.encode(ALICE));
        uint256 pot = jackpotHook.jackpot(id);
        vm.prank(address(manager));
        vm.expectRevert(LastBuyerJackpotHook.UnexpectedUnlock.selector);
        jackpotHook.unlockCallback(
            abi.encode(LastBuyerJackpotHook.UnlockData(LastBuyerJackpotHook.Action.Claim, key, BOB, pot, 0))
        );
        assertBacked();
        assertEq(jackpotHook.jackpot(id), pot);
    }

    function test_firstBuyOnTokenOnlyPoolTakesPositiveOutputFee() public {
        assertEq(address(manager).balance, 0);
        assertApproxEqAbs(token.balanceOf(address(manager)), token.totalSupply(), 1000);
        uint256 before = token.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta delta = swap(key, true, -0.001 ether, abi.encode(ALICE));
        uint256 gross = grossOutput(vm.getRecordedLogs());
        uint256 fee = gross / 100;
        assertGt(fee, 0);
        assertEq(jackpotHook.jackpot(id), fee);
        assertEq(uint256(uint128(delta.amount1())), gross - fee);
        assertEq(token.balanceOf(address(this)) - before, gross - fee);
        assertEq(address(manager).balance, 0.001 ether);
        assertEq(jackpotHook.lastBuyer(id), ALICE);
        assertBacked();
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function test_sellsAndExactOutputBuysDoNotFeedOrChangeLeader() public {
        swap(key, true, -1 ether, abi.encode(ALICE));
        uint256 pot = jackpotHook.jackpot(id);
        uint256 timestamp = jackpotHook.lastBuyAt(id);
        vm.warp(block.timestamp + 100);
        swap(key, false, -100 ether, abi.encode(BOB));
        swapNativeInput(key, false, 0.00001 ether, abi.encode(BOB), 0);
        swapNativeInput(key, true, 100 ether, abi.encode(BOB), 0.01 ether);
        assertEq(jackpotHook.jackpot(id), pot);
        assertEq(jackpotHook.lastBuyer(id), ALICE);
        assertEq(jackpotHook.lastBuyAt(id), timestamp);
        assertEq(jackpotHook.round(id), 0);
        assertBacked();
    }

    function test_qualificationThresholdBelowAtAbove() public {
        swap(key, true, -int256(0.001 ether - 1), abi.encode(ALICE));
        assertEq(jackpotHook.lastBuyer(id), address(0));
        assertEq(jackpotHook.claimableAt(id), 0);
        assertGt(jackpotHook.jackpot(id), 0);
        swap(key, true, -0.001 ether, abi.encode(ALICE));
        assertEq(jackpotHook.lastBuyer(id), ALICE);
        assertEq(jackpotHook.lastBuyAt(id), block.timestamp);
        vm.warp(block.timestamp + 1);
        swap(key, true, -int256(0.001 ether + 1), abi.encode(BOB));
        assertEq(jackpotHook.lastBuyer(id), BOB);
        assertEq(jackpotHook.lastBuyAt(id), block.timestamp);
        assertBacked();
    }

    function test_allMalformedHookDataShapesPayButNeverQualify() public {
        bytes[7] memory data = [
            bytes(""),
            hex"01",
            new bytes(31),
            new bytes(33),
            abi.encode(ALICE, BOB),
            abi.encode(address(0)),
            abi.encode((uint256(1) << 160) | uint160(ALICE))
        ];
        for (uint256 i; i < data.length; ++i) {
            uint256 before = jackpotHook.jackpot(id);
            swap(key, true, -0.001 ether, data[i]);
            assertGt(jackpotHook.jackpot(id), before);
            assertEq(jackpotHook.lastBuyer(id), address(0));
            assertEq(jackpotHook.lastBuyAt(id), 0);
            assertEq(jackpotHook.claimableAt(id), 0);
        }
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(LastBuyerJackpotHook.NothingToClaim.selector);
        jackpotHook.claim(key);
        assertBacked();
    }

    function test_unqualifiedBuysPreserveExistingLeaderAndTimer() public {
        swap(key, true, -0.001 ether, abi.encode(ALICE));
        uint256 timestamp = jackpotHook.lastBuyAt(id);
        vm.warp(timestamp + 3599);
        swap(key, true, -0.001 ether, "");
        swap(key, true, -0.0001 ether, abi.encode(BOB));
        assertEq(jackpotHook.lastBuyer(id), ALICE);
        assertEq(jackpotHook.lastBuyAt(id), timestamp);
        vm.warp(timestamp + 3600);
        jackpotHook.claim(key);
        assertGt(token.balanceOf(ALICE), 0);
        assertBacked();
    }

    function test_timerAt3599And3600PaysLeaderNotCaller() public {
        swap(key, true, -0.001 ether, abi.encode(ALICE));
        uint256 pot = jackpotHook.jackpot(id);
        uint256 deadline = jackpotHook.lastBuyAt(id) + 3600;
        assertEq(jackpotHook.claimableAt(id), deadline);
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(LastBuyerJackpotHook.TooEarly.selector, deadline));
        jackpotHook.claim(key);
        vm.warp(deadline);
        vm.prank(BOB);
        jackpotHook.claim(key);
        assertEq(token.balanceOf(ALICE), pot);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(jackpotHook.round(id), 1);
        assertEq(jackpotHook.lastBuyer(id), address(0));
        assertEq(jackpotHook.lastBuyAt(id), 0);
        assertEq(jackpotHook.claimableAt(id), 0);
        assertEq(jackpotHook.jackpot(id), 0);
        vm.expectRevert(LastBuyerJackpotHook.NothingToClaim.selector);
        jackpotHook.claim(key);
        assertBacked();
    }

    function test_buyInClaimBlockResetsTimer() public {
        swap(key, true, -0.001 ether, abi.encode(ALICE));
        vm.warp(block.timestamp + 3600);
        swap(key, true, -0.001 ether, abi.encode(BOB));
        uint256 deadline = block.timestamp + 3600;
        vm.expectRevert(abi.encodeWithSelector(LastBuyerJackpotHook.TooEarly.selector, deadline));
        jackpotHook.claim(key);
        vm.warp(deadline);
        jackpotHook.claim(key);
        assertEq(token.balanceOf(ALICE), 0);
        assertGt(token.balanceOf(BOB), 0);
        assertBacked();
    }

    function test_claimBeforeBuyInSameBlockStartsNextRound() public {
        swap(key, true, -0.001 ether, abi.encode(ALICE));
        uint256 pot = jackpotHook.jackpot(id);
        vm.warp(block.timestamp + 3600);
        jackpotHook.claim(key);
        swap(key, true, -0.001 ether, abi.encode(BOB));
        assertEq(token.balanceOf(ALICE), pot);
        assertEq(jackpotHook.lastBuyer(id), BOB);
        assertEq(jackpotHook.round(id), 1);
        assertEq(jackpotHook.claimableAt(id), block.timestamp + 3600);
        assertBacked();
    }

    function test_spoofingBuyerOnlyGiftsWinnerRouterHasNoFallback() public {
        swap(key, true, -0.001 ether, "");
        assertEq(jackpotHook.lastBuyer(id), address(0));
        swap(key, true, -0.001 ether, abi.encode(BOB));
        uint256 pot = jackpotHook.jackpot(id);
        vm.warp(block.timestamp + 3600);
        jackpotHook.claim(key);
        assertEq(token.balanceOf(BOB), pot);
        assertEq(token.balanceOf(address(swapRouter)), 0);
        assertBacked();
    }

    function test_walletBuyAuthenticatesCallerAndChargesOnce() public {
        vm.deal(ALICE, 1 ether);
        vm.recordLogs();
        vm.prank(ALICE);
        uint256 received = jackpotHook.buy{value: 0.001 ether}(key, 1);
        uint256 gross = grossOutput(vm.getRecordedLogs());
        assertEq(jackpotHook.jackpot(id), gross / 100);
        assertEq(received, gross - gross / 100);
        assertEq(token.balanceOf(ALICE), received);
        assertEq(jackpotHook.lastBuyer(id), ALICE);
        assertEq(ALICE.balance, 0.999 ether);
        assertBacked();
    }

    function test_walletMinOutBoundaryAndRollback() public {
        uint256 snapshot = vm.snapshotState();
        uint256 expected = jackpotHook.buy{value: 0.001 ether}(key, 0);
        assertTrue(vm.revertToState(snapshot));
        (uint160 priceBefore,,,) = manager.getSlot0(id);
        uint256 balanceBefore = token.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(LastBuyerJackpotHook.InsufficientOutput.selector, expected, expected + 1)
        );
        jackpotHook.buy{value: 0.001 ether}(key, expected + 1);
        (uint160 priceAfter,,,) = manager.getSlot0(id);
        assertEq(priceBefore, priceAfter);
        assertEq(token.balanceOf(address(this)), balanceBefore);
        assertEq(jackpotHook.jackpot(id), 0);
        assertEq(jackpotHook.lastBuyer(id), address(0));
        assertEq(address(manager).balance, 0);
        assertEq(jackpotHook.buy{value: 0.001 ether}(key, expected), expected);
        assertBacked();
    }

    function test_walletRejectsZeroAndForeignPool() public {
        vm.expectRevert(LastBuyerJackpotHook.InvalidAmount.selector);
        jackpotHook.buy(key, 0);
        PoolKey memory bad = key;
        bad.hooks = IHooks(address(0));
        vm.expectRevert(LastBuyerJackpotHook.InvalidPool.selector);
        jackpotHook.buy{value: 0.001 ether}(bad, 0);
        vm.expectRevert(LastBuyerJackpotHook.InvalidPool.selector);
        jackpotHook.claim(bad);
        bad = key;
        bad.currency0 = Currency.wrap(ALICE);
        vm.expectRevert(LastBuyerJackpotHook.InvalidPool.selector);
        jackpotHook.buy{value: 0.001 ether}(bad, 0);
        vm.expectRevert(LastBuyerJackpotHook.InvalidPool.selector);
        jackpotHook.claim(bad);
    }

    function test_nonNativePoolHasZeroFeeAndNoState() public {
        (Currency c0, Currency c1) = deployMintAndApprove2Currencies();
        PoolKey memory other = PoolKey(c0, c1, 3000, 60, IHooks(address(hook)));
        manager.initialize(other, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(other, ModifyLiquidityParams(-120, 120, 100 ether, 0), "");
        vm.recordLogs();
        BalanceDelta delta = swap(other, true, -0.001 ether, abi.encode(ALICE));
        assertEq(uint256(uint128(delta.amount1())), grossOutput(vm.getRecordedLogs()));
        assertEq(jackpotHook.jackpot(other.toId()), 0);
        assertEq(jackpotHook.lastBuyer(other.toId()), address(0));
        assertEq(jackpotHook.lastBuyAt(other.toId()), 0);
        assertEq(jackpotHook.round(other.toId()), 0);
        assertEq(manager.balanceOf(address(hook), c1.toId()), 0);
    }

    function test_multiplePoolsIsolatedAndClaimsSum() public {
        PoolKey memory other = secondPool();
        uint256 firstPot = jackpotHook.jackpot(id);
        vm.warp(block.timestamp + 1);
        swap(other, true, -0.001 ether, abi.encode(BOB));
        uint256 otherPot = jackpotHook.jackpot(other.toId());
        assertGt(otherPot, 0);
        assertEq(jackpotHook.jackpot(id), firstPot);
        assertEq(jackpotHook.lastBuyer(id), address(this));
        assertEq(jackpotHook.lastBuyer(other.toId()), BOB);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), firstPot + otherPot);
        vm.warp(jackpotHook.lastBuyAt(id) + 3600);
        jackpotHook.claim(key);
        assertEq(jackpotHook.jackpot(other.toId()), otherPot);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), otherPot);
        assertEq(jackpotHook.round(other.toId()), 0);
        vm.warp(block.timestamp + 1);
        jackpotHook.claim(other);
        assertEq(token.balanceOf(BOB), otherPot);
        assertBacked();
    }

    function test_liquidityCanBeRemovedWithOutstandingJackpot() public {
        swap(key, true, -0.001 ether, abi.encode(ALICE));
        uint256 pot = jackpotHook.jackpot(id);
        // At the initial tick liquidity starts out of range; after the buy it is active.
        uint128 liquidity = manager.getLiquidity(id);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(tickLower, tickUpper, -int256(uint256(liquidity)), 0), ""
        );
        assertEq(jackpotHook.jackpot(id), pot);
        vm.warp(block.timestamp + 3600);
        jackpotHook.claim(key);
        assertEq(token.balanceOf(ALICE), pot);
        assertBacked();
    }

    function test_eventsUsePoolAndCompletedRound() public {
        vm.recordLogs();
        swap(key, true, -0.001 ether, abi.encode(ALICE));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fed;
        uint256 leaders;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            assertEq(logs[i].topics[1], PoolId.unwrap(id));
            if (logs[i].topics[0] == keccak256("JackpotFed(bytes32,uint256)")) {
                assertEq(abi.decode(logs[i].data, (uint256)), jackpotHook.jackpot(id));
                ++fed;
            } else if (logs[i].topics[0] == keccak256("NewLeader(bytes32,address,uint256)")) {
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(ALICE))));
                assertEq(abi.decode(logs[i].data, (uint256)), 0);
                ++leaders;
            }
        }
        assertEq(fed, 1);
        assertEq(leaders, 1);
        vm.warp(block.timestamp + 3600);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LastBuyerJackpotHook.JackpotClaimed(id, ALICE, jackpotHook.jackpot(id), 0);
        jackpotHook.claim(key);
    }

    function testFuzz_feeAndQualification(uint96 amount, address buyer, bool wallet) public {
        uint256 input = bound(uint256(amount), 1, 10 ether);
        uint256 balanceBefore = token.balanceOf(address(this));
        vm.recordLogs();
        if (wallet) jackpotHook.buy{value: input}(key, 0);
        else swap(key, true, -int256(input), abi.encode(buyer));
        uint256 gross = grossOutput(vm.getRecordedLogs());
        assertEq(jackpotHook.jackpot(id), gross / 100);
        assertEq(token.balanceOf(address(this)) - balanceBefore, gross - gross / 100);
        address recipient = wallet ? address(this) : buyer;
        bool qualifies = input >= 0.001 ether && recipient != address(0);
        assertEq(jackpotHook.lastBuyer(id), qualifies ? recipient : address(0));
        assertEq(jackpotHook.lastBuyAt(id), qualifies ? block.timestamp : 0);
        assertBacked();
    }

    function testFuzz_arbitraryMalformedBytesCannotBrickSwap(bytes memory payload) public {
        vm.assume(payload.length != 32);
        swap(key, true, -0.001 ether, payload);
        assertEq(jackpotHook.lastBuyer(id), address(0));
        assertGt(jackpotHook.jackpot(id), 0);
        assertBacked();
    }

    function testFuzz_dirtyAddressWordCannotBrickSwap(uint96 high, address low) public {
        high = uint96(bound(high, 1, type(uint96).max));
        swap(key, true, -0.001 ether, abi.encode((uint256(high) << 160) | uint160(low)));
        assertEq(jackpotHook.lastBuyer(id), address(0));
        assertGt(jackpotHook.jackpot(id), 0);
        assertBacked();
    }
}
