# Last Buyer (LBUY)

**Sepolia test toy with no value.** A fixed-supply token and Uniswap v4 last-buyer jackpot. This repository is the contract implementation and test contribution for `lab-jackpot-hook`.

## Build and test

Requires Foundry and Solidity **0.8.26**. The compiler version is pinned in `foundry.toml`; dependencies are ordinary source files under `lib/`, so no package installation, submodules, RPC, or network is required once the compiler is installed.

```sh
forge build
forge test
forge fmt --check
```

The EVM target is Cancun, optimization is enabled with 200 runs, and `bytecode_hash = "none"`. FFI is disabled and no filesystem permissions are added. Tests do not read or set environment variables. The vendored dependency provenance is in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

## Contracts and round rules

- `src/LaunchToken.sol:LaunchToken`: Last Buyer, symbol LBUY, 18 decimals, **1,000,000,000 LBUY** minted once to `msg.sender`. No constructor arguments, further minting, burn entry point, owner, tax, proxy, or pause.
- `src/LastBuyerJackpotHook.sol:LastBuyerJackpotHook`: constructor `(IPoolManager manager)` only. Its address must encode **0x0044 under mask 0x3fff**. OpenZeppelin BaseHook validates that address during construction and restricts callbacks to the immutable manager. Only `afterSwap` and `afterSwapReturnDelta` are enabled. No administrative or upgrade authority exists.

For each pool with native ETH as currency0, an exact-input buy (`zeroForOne && amountSpecified < 0`) contributes `floor(gross token output / 100)` token base units. The fee is deducted from the output, never from an assumed ETH reserve. Router swaps return a positive unspecified hook delta and mint the same amount of ERC-6909 token claims to the hook. The jackpot consists of these claims at PoolManager. Sells, exact-output buys, and non-native pools do not change hook state or pay a hook fee. The pool's ordinary LP fee still applies.

A buy qualifies when its **specified input is at least 0.001 ETH** and `hookData` is exactly one canonical ABI address word containing a nonzero address. Empty, short, long, zero-address, and dirty-high-bit payloads still pay the fee but neither appoint a leader nor reset the timer. There is no router-sender fallback. With no qualifying buy, the jackpot accumulates indefinitely.

**Router hookData is unauthenticated.** A buyer can gift leadership to any nonzero address. No signature or origin is inferred. The wallet `buy(key, minOut)` path authenticates its recipient as `msg.sender`; it passes that address as hookData, buys with `msg.value`, settles the actual ETH debit, refunds only unspent input, and transfers net output to the caller. Uniswap skips callbacks for a swap initiated by the hook itself, so this path applies the same fee and leadership logic once directly after `swap`, splitting its gross token credit into claims and the buyer's output. `minOut` is in raw token units **after LP and hook fees**. Failure, including a rejected refund, reverts the entire operation.

Anyone can call `claim(key)` at `lastBuyAt + 3600` or later. It pays the recorded last buyer regardless of the caller. Before unlocking, it clears the jackpot, buyer, and timestamp, and increments the pool's round. The callback burns that pool's recorded claims and takes its token to the winner. A failed transfer restores all state and claims atomically; anyone may retry. Rounds start at zero; `JackpotClaimed` names the completed round. A qualifying buy can reset an expired timer until a claim actually executes. At the deadline, transaction ordering determines whether the old winner is paid or replaced.

## Assumptions and limits

LBUY is a standard ERC20. This hook learns the token from each pool key and keeps state by full PoolId; it does not authorize a token brand, LP fee, or factory. Other native-token pools can use it. Fee-on-transfer, rebasing, and malicious tokens are outside the supported launch configuration. Non-native pools receive zero deltas and no state.

Qualification follows the requested **specified** amount, including partially filled swaps. Low liquidity can make actual spend less than 0.001 ETH; an empty pool and `minOut = 0` can also produce no tokens. Wallets should use a fresh quote and nonzero slippage-adjusted `minOut`. This is a known economic limit, not a spent-ETH qualification guarantee. A winner can be a contract that cannot recover its tokens. There is no rescue function or refund for tokens voluntarily gifted to an unusable address.

The tested accounting invariant is `PoolManager.balanceOf(hook, tokenId) == sum(jackpots for that token)` for fees and payouts produced by the hook. PoolManager also permits unsolicited ERC-6909 transfers to any address. Such donations create surplus claims, so the general adversarial relation is `balance >= sum(jackpots)`. Donations do not increase any jackpot and cannot redirect a payout. Forced ETH and directly sent ERC20s likewise have no recovery path. [The settlement tests](test/Settlement.t.sol) cover the donation case explicitly.

The timer is based on chain timestamps; there is no random selection, oracle, VRF, automatic payout, or guaranteed claim ordering. Participants keep their purchased tokens whether or not they win. The prize is solely the accumulated token fee.

## Deployment and service handoff

The intended deployment is **Sepolia, chain ID 11155111**:

| Parameter | Value |
| --- | --- |
| Hook constructor argument | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Hook permission bits | `0x0044` / decimal `68` |
| Token constructor arguments | none |
| Pool currency0 | `0x0000000000000000000000000000000000000000` (native ETH) |
| Pool currency1 | deployed LBUY address |
| Pool LP fee | `3000` (0.30%) |
| Tick spacing | `60` |
| Initial funding | LBUY only; no ETH required |

The manifest contributor supplies `launch.json`, with the manager address above as the **literal sole constructorArgs value**, and source/artifact references to these contracts. The launch factory receives the token supply as its deployer and mines CREATE2 using its actual deployer address, the final hook creation code, and ABI-encoded manager argument. Rebuilds or a different deployer/constructor argument require a fresh salt. The constructor must run at the mined address; production deployment must never use the test harness's `vm.etch` technique.

`BaseHookTest` reproduces the starter's launch curve: initial tick 138000, LP range from the minimum usable tick through 138000, full supply seeded as token only (with sub-1000-base-unit rounding dust). Factory source, actual initial price/range, token allocation, and deployed addresses must be checked in the separate manifest/review/service stages; this assignment sends no transactions.

Services handle source publication, signed artifact linkage, attestation, admission, rehearsal against the actual manager, and deployment. The independent reviewer inspects accepted source and manifest; [docs/REVIEW-HANDOFF.md](docs/REVIEW-HANDOFF.md) records implementation evidence and issues to assess. Local tests are not an independent security review, and no such review or live deployment is claimed here.

The later frontend contributor uses the deployed addresses and [ABI exports](docs/abi), reads views/events over a public Sepolia RPC, and builds the one-page `lab-jackpot-hook` static site with `dist/index.html`. It must display the test-toy label, obtain a net-output quote, compute slippage-based `minOut`, call payable `buy`, and enable permissionless claim after the timer. Services/operators verify chain and pool configuration, monitor claims and failed settlements, and may submit claims; there is no privileged keeper or governance key.

## Test coverage

All economic tests run swaps through a freshly deployed, real `PoolManager` using the starter's `BaseHookTest` launch setup and LBUY implementation. The suite covers:

- Token metadata, fixed supply, transfers/allowances and failures, missing mint/admin paths, and runtime opcode/size checks corresponding to the supplied floor definitions.
- CREATE2 deployment at matching bits, constructor rejection at wrong bits, permissions, and direct callback refusal including `afterSwap` and `unlockCallback`.
- First buy against token-only liquidity; fee sign, output deduction, rounding including zero fee, exact-output buys, both sell modes, non-native pools, liquidity removal, and emitted events.
- Every hookData shape, arbitrary malformed bytes, dirty address words, spoofed gifts, no router fallback, and the qualification threshold immediately below/at/above 0.001 ETH.
- 3599/3600-second claim boundaries, duplicate claims, no-leader claims, both claim/buy orderings in the same block, winner/caller separation, and isolated pools sharing one token.
- Authenticated wallet buying, precise minOut boundary and rollback, partial fills/refunds, retained forced ETH, rejected refunds, failed token transfers and retry, claim effects before payout, reentrancy, forged pool keys, unsolicited unlock callbacks, and unauthorized claim transfers.
- Stateful invariants over two pools, randomized wallet/router buys, malformed identities, sells, time advances and claims: claim backing, settled manager deltas, no hook custody from normal flows, and conserved LBUY supply. Default: 128 runs × 64 actions, failing on unexpected reverts.

ABI usage and return units are documented in [docs/ABI.md](docs/ABI.md).
