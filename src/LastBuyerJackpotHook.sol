// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Sepolia toy: 1% of exact-input ETH buys funds a last-buyer LBUY jackpot.
/// @dev Pool keys determine the token; only standard, non-rebasing ERC20s are supported.
contract LastBuyerJackpotHook is BaseHook, IUnlockCallback, ReentrancyGuard {
    uint256 public constant FEE_BPS = 100;
    uint256 public constant MIN_BUY = 0.001 ether;
    uint256 public constant ROUND_DELAY = 3600;

    mapping(PoolId => uint256) public jackpot;
    mapping(PoolId => address) public lastBuyer;
    mapping(PoolId => uint256) public lastBuyAt;
    mapping(PoolId => uint256) public round;

    enum Action {
        Buy,
        Claim
    }

    struct UnlockData {
        Action action;
        PoolKey key;
        address recipient;
        uint256 amount;
        uint256 minOut;
    }

    // Only a callback matching a locally initiated operation may spend hook assets.
    bytes32 private _pendingUnlock;

    error InvalidPool();
    error InvalidAmount();
    error InvalidManager();
    error NothingToClaim();
    error TooEarly(uint256 claimableAt);
    error UnexpectedUnlock();
    error InsufficientOutput(uint256 received, uint256 minimum);
    error RefundFailed();
    error InvalidSwapDelta();

    event JackpotFed(PoolId indexed poolId, uint256 amount);
    event NewLeader(PoolId indexed poolId, address indexed buyer, uint256 round);
    event JackpotClaimed(PoolId indexed poolId, address indexed winner, uint256 amount, uint256 round);

    constructor(IPoolManager manager) BaseHook(manager) {
        if (address(manager) == address(0)) revert InvalidManager();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Zero when no address has qualified in this round.
    function claimableAt(PoolId id) external view returns (uint256) {
        return lastBuyer[id] == address(0) ? 0 : lastBuyAt[id] + ROUND_DELAY;
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) internal override returns (bytes4, int128) {
        if (!key.currency0.isAddressZero() || !params.zeroForOne || params.amountSpecified >= 0) {
            return (this.afterSwap.selector, 0);
        }

        address buyer = address(0);
        if (data.length == 32) {
            // abi.decode(data, (address)) reverts on dirty high bits. Decode a full word
            // first so every malformed payload remains a successful, unqualified swap.
            uint256 word = abi.decode(data, (uint256));
            if (word <= type(uint160).max) buyer = address(uint160(word));
        }
        uint256 fee = _feed(key, params.amountSpecified, delta.amount1(), buyer);
        // Positive unspecified delta reduces the swapper's token output. The claims
        // minted in _feed offset this hook credit, leaving no unsettled hook balance.
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice Authenticated exact-input buy. minOut is the net token output after both fees.
    /// @return amountOut Tokens sent to msg.sender.
    function buy(PoolKey calldata key, uint256 minOut) external payable nonReentrant returns (uint256 amountOut) {
        _validatePool(key);
        if (msg.value == 0 || msg.value > uint256(type(int256).max)) revert InvalidAmount();
        bytes memory result = _unlock(UnlockData(Action.Buy, key, msg.sender, msg.value, minOut));
        uint256 spent;
        (amountOut, spent) = abi.decode(result, (uint256, uint256));
        uint256 refund = msg.value - spent;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @notice Anyone may settle an expired round, but payment always goes to lastBuyer.
    function claim(PoolKey calldata key) external nonReentrant {
        _validatePool(key);
        PoolId id = key.toId();
        address winner = lastBuyer[id];
        if (winner == address(0)) revert NothingToClaim();
        uint256 deadline = lastBuyAt[id] + ROUND_DELAY;
        if (block.timestamp < deadline) revert TooEarly(deadline);

        uint256 amount = jackpot[id];
        uint256 finishedRound = round[id];
        jackpot[id] = 0;
        lastBuyer[id] = address(0);
        lastBuyAt[id] = 0;
        round[id] = finishedRound + 1;

        _unlock(UnlockData(Action.Claim, key, winner, amount, 0));
        emit JackpotClaimed(id, winner, amount, finishedRound);
    }

    /// @dev PoolManager calls this only during buy/claim's own unlock. Action and all
    /// parameters are bound by a one-use hash; router unlocks cannot forge a payout.
    function unlockCallback(bytes calldata raw) external onlyPoolManager returns (bytes memory) {
        if (_pendingUnlock == bytes32(0) || keccak256(raw) != _pendingUnlock) revert UnexpectedUnlock();
        delete _pendingUnlock;
        UnlockData memory data = abi.decode(raw, (UnlockData));

        if (data.action == Action.Claim) {
            if (data.amount != 0) {
                poolManager.burn(address(this), data.key.currency1.toId(), data.amount);
                poolManager.take(data.key.currency1, data.recipient, data.amount);
            }
            return "";
        }

        SwapParams memory params = SwapParams(true, -int256(data.amount), TickMath.MIN_SQRT_PRICE + 1);
        BalanceDelta delta = poolManager.swap(data.key, params, abi.encode(data.recipient));
        if (delta.amount0() > 0 || delta.amount1() < 0) revert InvalidSwapDelta();
        uint256 spent = uint256(-int256(delta.amount0()));
        if (spent > data.amount) revert InvalidSwapDelta();

        // Core deliberately skips callbacks when the swap caller IS the hook. Apply
        // the identical fee/leader logic here exactly once, using the gross credit.
        uint256 fee = _feed(data.key, params.amountSpecified, delta.amount1(), data.recipient);
        uint256 amountOut = uint256(uint128(delta.amount1())) - fee;
        if (amountOut < data.minOut) revert InsufficientOutput(amountOut, data.minOut);

        // Reset any ERC20 sync left by an earlier operation before settling native ETH.
        poolManager.sync(data.key.currency0);
        poolManager.settle{value: spent}();
        if (amountOut != 0) poolManager.take(data.key.currency1, data.recipient, amountOut);
        return abi.encode(amountOut, spent);
    }

    function _feed(PoolKey memory key, int256 specified, int128 grossOutput, address buyer)
        private
        returns (uint256 fee)
    {
        PoolId id = key.toId();
        if (grossOutput > 0) {
            fee = uint256(uint128(grossOutput)) * FEE_BPS / 10_000;
            if (fee != 0) {
                jackpot[id] += fee;
                poolManager.mint(address(this), key.currency1.toId(), fee);
                emit JackpotFed(id, fee);
            }
        }
        // Compare signed values directly, including int256.min, without negation overflow.
        if (specified <= -int256(MIN_BUY) && buyer != address(0)) {
            lastBuyer[id] = buyer;
            lastBuyAt[id] = block.timestamp;
            emit NewLeader(id, buyer, round[id]);
        }
    }

    function _unlock(UnlockData memory data) private returns (bytes memory result) {
        bytes memory raw = abi.encode(data);
        _pendingUnlock = keccak256(raw);
        result = poolManager.unlock(raw);
        if (_pendingUnlock != bytes32(0)) revert UnexpectedUnlock();
    }

    function _validatePool(PoolKey calldata key) private view {
        if (!key.currency0.isAddressZero() || key.currency1.isAddressZero() || address(key.hooks) != address(this)) {
            revert InvalidPool();
        }
    }
}
