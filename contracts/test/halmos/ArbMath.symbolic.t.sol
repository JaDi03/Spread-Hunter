// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ArbMath} from "../../src/reactive/ArbMath.sol";

/// Properties proved with Halmos for every 64-bit input (`halmos --match-contract ArbMathSymbolic`).
contract ArbMathSymbolic is Test {
    function check_cheaperOnA_neverBothWays(uint64 usdcA, uint64 tokenA, uint64 usdcB, uint64 tokenB) public pure {
        assert(!(ArbMath.cheaperOnA(usdcA, tokenA, usdcB, tokenB) && ArbMath.cheaperOnA(usdcB, tokenB, usdcA, tokenA)));
    }
}
