// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice The token a launch pool is seeded with: one billion units, minted once, then fixed.
 *
 * There is no mint function after construction and no owner, so the supply in the pool is the
 * entire supply that will ever exist. A hook reasoning about scarcity, vesting or fee accrual can
 * take that as given rather than defending against later inflation.
 */
contract LaunchToken is ERC20 {
    /// @dev One billion, at 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor() ERC20("Last Buyer", "LBUY") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
