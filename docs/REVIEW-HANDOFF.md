# Implementation evidence for the independent reviewer

This is an implementation handoff, not an independent review or approval. Review the final source, compiler artifacts, constructor arguments and separately generated manifest together.

| Attack surface | Implementation and local evidence |
| --- | --- |
| Malformed hookData | Checks length 32, decodes uint256, rejects dirty high bits without reverting; shape and fuzz tests swap through real core. |
| Wrong fee sign / unsettled deltas | Positive unspecified token delta, equal claim mint; buy path consumes gross output credit directly because core skips self callbacks. First zero-ETH buy, gross Swap-event comparison and zero-delta invariants pass. |
| Spoofed buyers / router capture | No sender fallback. External hookData intentionally allows gifts. Wallet path always uses caller. Tests pay the nominated address independently of the claimer. |
| Claim timing / transaction races | Timestamp deadline uses >=; qualifying buys overwrite deadline even after expiry. Tests cover 3599, 3600 and both same-block orderings. No fairness or protected-claim-window claim is made. |
| Confused unlock actions | Distinct Buy/Claim enum plus one-use hash of all callback data and onlyPoolManager. Unsolicited callback fails. |
| Payout theft / cross-pool accounting | State keyed by full PoolId; claim uses stored winner and amount, resets effects first, burns claims, then takes token. No ERC6909 approval path. Multiple-pool, forged-key, failed-transfer and reentrancy tests pass. |
| Mutability / permissions | Only afterSwap + return delta; constructor validates 0x44. No proxy, delegatecall, selfdestruct, owner or pause. Real CREATE2 and deployed-runtime tests pass. |

Behavioral qualifications to retain in any review:

1. The workflow measures **specified input**, not actual ETH spent. A partial fill can appoint a leader for less actual spend; in an exhausted/no-liquidity pool, `minOut = 0` does not prevent a zero-output buy. Changing qualification to actual spend would change the approved behavior. The frontend should use a nonzero net-output limit. Review this economic behavior explicitly before release.
2. ERC6909 claims are freely transferable to the hook. The requested equality is invariant over protocol fee/payout operations, but cannot hold after arbitrary unsolicited donations. Surplus is unassigned and not withdrawable. The adversarial safety property is sufficient backing (`>=`), with no cross-pool or caller entitlement. A dedicated test demonstrates this limitation rather than concealing it.
3. The hook accepts arbitrary native-token pool keys. It cannot identify the intended LBUY address before the launch token exists. Launch services and the frontend must bind to the reviewed pool. Nonstandard/malicious currencies are not supported; transfer-failure and callback mocks test rollback and entry guards, not comprehensive support for arbitrary token economics.
4. HookData is not an authentication mechanism on third-party routers. It can name a contract, the manager or the hook itself; an unusable destination can strand a voluntarily gifted payout. There is no rescue authority.

The reviewer should confirm the manifest's manager literal, one-argument constructor, exact permissions, static 3000 fee, spacing 60, native/LBUY ordering, and token constructor with no arguments. Policy and signed artifact linkage are service responsibilities. Concrete source/constructor/authorization conflicts are review findings. The actual Sepolia manager/factory rehearsal, artifact admission, transactions, and live-site integration have not been performed by this assignment.
