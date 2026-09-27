// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHookTest} from "./BaseHookTest.sol";
import {LastBuyerJackpotHook} from "../src/LastBuyerJackpotHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Vm} from "forge-std/Vm.sol";

abstract contract JackpotFixture is BaseHookTest {
    LastBuyerJackpotHook internal jackpotHook;
    PoolId internal id;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function hookArtifact() internal pure override returns (string memory) {
        return "LastBuyerJackpotHook.sol:LastBuyerJackpotHook";
    }

    function setUp() public virtual override {
        super.setUp();
        jackpotHook = LastBuyerJackpotHook(address(hook));
        id = key.toId();
        vm.warp(10_000);
    }

    function secondPool() internal returns (PoolKey memory other) {
        // The same token in a second pool verifies aggregation by currency, isolation by PoolId.
        jackpotHook.buy{value: 1 ether}(key, 0);
        other = key;
        other.fee = 500;
        manager.initialize(other, TickMath.getSqrtPriceAtTick(START_TICK));
        modifyLiquidityRouter.modifyLiquidity(other, ModifyLiquidityParams(137_940, 138_000, 1e18, 0), "");
    }

    function grossOutput(Vm.Log[] memory logs) internal view returns (uint256) {
        bytes32 signature = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == signature) {
                (, int128 amount1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                require(amount1 >= 0, "not a buy");
                return uint256(uint128(amount1));
            }
        }
        revert("missing PoolManager Swap event");
    }

    function assertBacked() internal view {
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), jackpotHook.jackpot(id));
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }
}
