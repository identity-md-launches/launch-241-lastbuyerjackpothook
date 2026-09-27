// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JackpotFixture} from "./JackpotFixture.sol";
import {LastBuyerJackpotHook} from "../src/LastBuyerJackpotHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract JackpotHandler is Test {
    using StateLibrary for IPoolManager;
    LastBuyerJackpotHook public immutable hook;
    LaunchToken public immutable token;
    PoolSwapTest public immutable router;
    PoolKey[2] private _keys;
    uint256 public paidOut;
    uint256 public successfulBuys;
    uint256 public successfulClaims;

    constructor(
        LastBuyerJackpotHook hook_,
        LaunchToken token_,
        PoolSwapTest router_,
        PoolKey memory first,
        PoolKey memory second
    ) {
        hook = hook_;
        token = token_;
        router = router_;
        _keys[0] = first;
        _keys[1] = second;
        token.approve(address(router_), type(uint256).max);
    }

    function buy(uint8 pool, uint96 rawAmount, uint8 shape, bool wallet) external {
        PoolKey memory key = _keys[pool % 2];
        (uint160 price,,,) = hook.poolManager().getSlot0(key.toId());
        if (price <= TickMath.MIN_SQRT_PRICE + 1) return;
        uint256 amount = bound(rawAmount, 1, 0.01 ether);
        if (wallet) {
            hook.buy{value: amount}(key, 0);
        } else {
            bytes memory data;
            uint256 choice = shape % 5;
            if (choice == 0) data = abi.encode(address(this));
            else if (choice == 1) data = abi.encode(address(0));
            else if (choice == 2) data = abi.encode(uint256(1) << 200);
            else if (choice == 3) data = hex"010203";
            else data = "";
            router.swap{value: amount}(
                key,
                SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                data
            );
        }
        ++successfulBuys;
    }

    function sell(uint8 pool, uint96 rawAmount) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance);
        PoolKey memory key = _keys[pool % 2];
        (uint160 price,,,) = hook.poolManager().getSlot0(key.toId());
        if (price >= TickMath.MAX_SQRT_PRICE - 1) return;
        uint256 potBefore = hook.jackpot(key.toId());
        address leaderBefore = hook.lastBuyer(key.toId());
        uint256 timeBefore = hook.lastBuyAt(key.toId());
        router.swap(
            key,
            SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        assertEq(hook.jackpot(key.toId()), potBefore);
        assertEq(hook.lastBuyer(key.toId()), leaderBefore);
        assertEq(hook.lastBuyAt(key.toId()), timeBefore);
    }

    function advanceAndClaim(uint8 pool, uint16 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 7200));
        PoolKey memory key = _keys[pool % 2];
        uint256 deadline = hook.claimableAt(key.toId());
        if (deadline == 0 || block.timestamp < deadline) return;
        uint256 amount = hook.jackpot(key.toId());
        address winner = hook.lastBuyer(key.toId());
        uint256 before = token.balanceOf(winner);
        uint256 roundBefore = hook.round(key.toId());
        hook.claim(key);
        assertEq(token.balanceOf(winner), before + amount);
        assertEq(hook.jackpot(key.toId()), 0);
        assertEq(hook.lastBuyer(key.toId()), address(0));
        assertEq(hook.round(key.toId()), roundBefore + 1);
        paidOut += amount;
        ++successfulClaims;
    }

    receive() external payable {}
}

contract JackpotInvariantTest is JackpotFixture {
    using TransientStateLibrary for IPoolManager;
    JackpotHandler private _handler;
    PoolKey private _other;

    function setUp() public override {
        super.setUp();
        _other = secondPool();
        _handler = new JackpotHandler(jackpotHook, token, swapRouter, key, _other);
        vm.deal(address(_handler), 10_000 ether);
        targetContract(address(_handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = JackpotHandler.buy.selector;
        selectors[1] = JackpotHandler.sell.selector;
        selectors[2] = JackpotHandler.advanceAndClaim.selector;
        targetSelector(FuzzSelector(address(_handler), selectors));
    }

    function invariant_claimsEqualSumOfPoolJackpots() public view {
        assertEq(
            manager.balanceOf(address(hook), key.currency1.toId()),
            jackpotHook.jackpot(id) + jackpotHook.jackpot(_other.toId())
        );
    }

    function invariant_noOpenDeltasOrHookCustody() public view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function invariant_tokenSupplyConserved() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(manager)) + token.balanceOf(address(this)) + token.balanceOf(address(_handler)),
            token.totalSupply()
        );
    }
}
