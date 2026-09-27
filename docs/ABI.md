# Contract interface

The JSON arrays in `docs/abi/LaunchToken.json` and `docs/abi/LastBuyerJackpotHook.json` are generated from the compiled contracts. Regenerate with:

```sh
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/LastBuyerJackpotHook.sol:LastBuyerJackpotHook abi --json > docs/abi/LastBuyerJackpotHook.json
```

`PoolKey` is `(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)` in that order. A `PoolId` is `keccak256(abi.encode(key))`, not packed encoding, and appears as `bytes32` in the ABI. It includes the hook address, fee and spacing. Every view is per complete PoolId. Use the exact deployed pool key.

| Hook method | Meaning |
| --- | --- |
| `buy(PoolKey,uint256 minOut) payable returns (uint256)` | Buys with msg.value wei; returns and transfers net LBUY base units to caller; refunds unused ETH. Requires this hook and native currency0. |
| `claim(PoolKey)` | Permissionless payout to stored winner after expiry; errors if no leader or early. |
| `jackpot(bytes32)` | Accrued LBUY base units represented by manager claims. |
| `lastBuyer(bytes32)` | Leader or zero. |
| `lastBuyAt(bytes32)` | Unix timestamp of qualifying buy, or zero after claim/no leader. |
| `round(bytes32)` | Zero-based current round, incremented once per successful claim. |
| `claimableAt(bytes32)` | Zero if no leader, otherwise lastBuyAt + 3600 seconds. |
| `poolManager()` | Immutable manager address. |
| `getHookPermissions()` | Fourteen booleans in v4 order; only afterSwap and afterSwapReturnDelta true. |
| `FEE_BPS()`, `MIN_BUY()`, `ROUND_DELAY()` | Constants 100, 1000000000000000 wei, and 3600 seconds. |

Hook events:

- `JackpotFed(bytes32 indexed poolId, uint256 amount)`: nonzero fee added, raw token units.
- `NewLeader(bytes32 indexed poolId, address indexed buyer, uint256 round)`: qualification; also emitted when the current leader buys again.
- `JackpotClaimed(bytes32 indexed poolId, address indexed winner, uint256 amount, uint256 round)`: amount paid and completed round, before the increment from the event's perspective.

Use current views as the source of truth after an event or reorganization. A countdown reaching zero does not reserve a payout; another buy may reset it before a claim lands.

App-facing errors include `InvalidPool`, `InvalidAmount`, `NothingToClaim`, `TooEarly(uint256)`, `InsufficientOutput(uint256 received,uint256 minimum)` and `RefundFailed`. Core may return its own errors for an uninitialized or exhausted pool. Settlement failures revert the whole transaction. `NotPoolManager`, `UnexpectedUnlock`, and `ReentrancyGuardReentrantCall` reject unauthorized callback/entry attempts.

`afterSwap` and the other BaseHook functions are manager callbacks. `unlockCallback(bytes)` is an internal protocol entry point, exposed because PoolManager must call it, and cannot be used as a wallet payout method. Its payload has a one-use commitment established by `buy`/`claim` and includes an explicit action discriminator.

LBUY uses standard ERC20 `transfer`, `approve`, `transferFrom`, `balanceOf`, `allowance`, `totalSupply`, `name`, `symbol` and `decimals`. `TOTAL_SUPPLY()` is `1000000000 * 10**18`. Format jackpot and output values with 18 decimals. The hook does not hardcode token decimals or convert its fee to display units.
