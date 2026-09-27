// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JackpotFixture} from "./JackpotFixture.sol";

/// @dev Local, environment-free counterpart to the supplied runtime floor checks.
contract RuntimeTest is JackpotFixture {
    function test_tokenAndHookRuntimeHaveNoEscapeOpcodes() public view {
        checkRuntime(address(token).code);
        checkRuntime(address(hook).code);
    }

    function checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "forbidden runtime opcode");
        }
    }
}
