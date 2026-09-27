// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken private _token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        _token = new LaunchToken();
    }

    function test_fixedSupplyMetadataAndDeployer() public view {
        assertEq(_token.name(), "Last Buyer");
        assertEq(_token.symbol(), "LBUY");
        assertEq(_token.decimals(), 18);
        assertEq(_token.totalSupply(), 1_000_000_000 ether);
        assertEq(_token.balanceOf(address(this)), _token.totalSupply());
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, _token.totalSupply());
        assertTrue(_token.transfer(ALICE, amount));
        assertEq(_token.balanceOf(ALICE), amount);
        assertEq(_token.balanceOf(address(this)), _token.totalSupply() - amount);
        assertEq(_token.totalSupply(), 1_000_000_000 ether);
    }

    function test_approvalTransferFromAndFailurePaths() public {
        _token.approve(ALICE, 100);
        vm.prank(ALICE);
        assertTrue(_token.transferFrom(address(this), BOB, 60));
        assertEq(_token.allowance(address(this), ALICE), 40);
        assertEq(_token.balanceOf(BOB), 60);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 40, 41));
        _token.transferFrom(address(this), BOB, 41);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 60, 61));
        _token.transfer(ALICE, 61);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        _token.transfer(address(0), 1);
    }

    function test_neitherDeployerNorStrangerHasMintOrAdminPath() public {
        string[10] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 who; who < 2; ++who) {
            for (uint256 i; i < selectors.length; ++i) {
                vm.prank(who == 0 ? address(this) : ALICE);
                (bool ok,) = address(_token).call(abi.encodeWithSignature(selectors[i], ALICE, type(uint128).max));
                assertFalse(ok);
                assertEq(_token.totalSupply(), 1_000_000_000 ether);
                assertEq(_token.balanceOf(ALICE), 0);
            }
        }
    }
}
