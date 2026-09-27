// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LastBuyerJackpotHook} from "../../src/LastBuyerJackpotHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract RefundReceiver {
    LastBuyerJackpotHook public immutable hook;
    PoolKey private _key;
    bool public rejectRefund;
    bool public attempted;
    bool public buyReentered;
    bool public claimReentered;
    bytes4 public buyError;
    bytes4 public claimError;

    constructor(LastBuyerJackpotHook hook_) {
        hook = hook_;
    }

    function execute(PoolKey calldata key, bool reject) external payable returns (uint256) {
        _key = key;
        rejectRefund = reject;
        return hook.buy{value: msg.value}(key, 0);
    }

    receive() external payable {
        require(!rejectRefund, "refund rejected");
        attempted = true;
        bytes memory result;
        (buyReentered, result) = address(hook).call{value: 1}(abi.encodeCall(hook.buy, (_key, 0)));
        buyError = bytes4(result);
        (claimReentered, result) = address(hook).call(abi.encodeCall(hook.claim, (_key)));
        claimError = bytes4(result);
    }
}

contract AdversarialToken is ERC20 {
    bool public failTransfers;
    bool public attack;
    bool public reentered;
    bool public sawReset;
    bytes4 public rejection;
    LastBuyerJackpotHook private _hook;
    PoolKey private _key;

    constructor() ERC20("Adversarial test token", "TEST") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function setFailure(bool fail) external {
        failTransfers = fail;
    }

    function arm(LastBuyerJackpotHook hook, PoolKey calldata key) external {
        _hook = hook;
        _key = key;
        attack = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        if (attack) {
            attack = false;
            sawReset = _hook.jackpot(_key.toId()) == 0 && _hook.lastBuyer(_key.toId()) == address(0)
                && _hook.round(_key.toId()) == 1;
            bytes memory result;
            (reentered, result) = address(_hook).call(abi.encodeCall(_hook.claim, (_key)));
            rejection = bytes4(result);
        }
        return super.transfer(to, amount);
    }
}
