// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ArbMath} from "../../src/reactive/ArbMath.sol";

contract ArbMathTest is Test {
    uint24 internal constant FEE = 500;

    function test_reserves_matchDemoPool() public pure {
        // 400 USDC + 40 000 TOKEN full range: sqrtPrice 1e7 * 2^96, liquidity 4e15
        (uint256 u, uint256 t) = ArbMath.reserves(uint160(1e7 << 96), 4e15, true);
        assertEq(u, 400e6);
        assertEq(t, 40_000e18);
        (uint256 u2, uint256 t2) = ArbMath.reserves(uint160(1e7 << 96), 4e15, false);
        assertEq(u2, 40_000e18);
        assertEq(t2, 400e6);
    }

    function test_cheaperOnA() public pure {
        assertTrue(ArbMath.cheaperOnA(400e6, 40_000e18, 440e6, 40_000e18));
        assertFalse(ArbMath.cheaperOnA(440e6, 40_000e18, 400e6, 40_000e18));
        assertFalse(ArbMath.cheaperOnA(400e6, 40_000e18, 400e6, 40_000e18));
    }

    function test_amountOut_chargesFeeOnInput() public pure {
        // 1 USDC into 400 USDC / 40 000 TOKEN: 40 000 * 0.9995 / 400.9995 = 99.7009 TOKEN
        assertEq(ArbMath.amountOut(400e6, 40_000e18, FEE, 1e6), 99_700_872_444_978_110_945);
    }

    function test_amountInFor_buysAtMostTheTarget() public pure {
        uint256 target = 50e18;
        uint256 amountIn = ArbMath.amountInFor(400e6, 40_000e18, FEE, target);
        assertLe(ArbMath.amountOut(400e6, 40_000e18, FEE, amountIn), target);
        assertGe(ArbMath.amountOut(400e6, 40_000e18, FEE, amountIn + 1), target);
        assertEq(ArbMath.amountInFor(400e6, 40_000e18, FEE, 40_000e18), 0);
    }

    function test_optimal_isZeroWhenGapBelowFees() public pure {
        // 0.05% gap with two 0.05% fees: no gain
        assertEq(ArbMath.optimalUsdcIn(400e6, 40_000e18, FEE, 400.2e6, 40_000e18, FEE), 0);
        assertEq(ArbMath.optimalUsdcIn(400e6, 40_000e18, FEE, 400e6, 40_000e18, FEE), 0);
    }

    function test_optimal_tenPercentGapOnDemoPools() public pure {
        // pool B priced 10% higher at the same depth: a brute-force search gives ~9.44 USDC in and ~0.46 out
        uint256 rootGap = 1_048_809; // sqrt(1.1) in millionths
        uint256 usdcB = uint256(400e6) * rootGap / 1e6;
        uint256 tokenB = uint256(40_000e18) * 1e6 / rootGap;
        uint256 dIn = ArbMath.optimalUsdcIn(400e6, 40_000e18, FEE, usdcB, tokenB, FEE);
        uint256 profit = _profit(400e6, 40_000e18, usdcB, tokenB, dIn);
        assertApproxEqRel(dIn, 9.44e6, 0.01e18);
        assertApproxEqRel(profit, 0.4555e6, 0.01e18);
    }

    function testFuzz_optimal_beatsNeighbours(uint256 usdcA, uint256 priceA, uint256 gapBps, uint256 depthB)
        public
        pure
    {
        usdcA = bound(usdcA, 100e6, 10_000_000e6);
        priceA = bound(priceA, 1e8, 1e18); // token units per USDC unit
        gapBps = bound(gapBps, 1, 2000);
        depthB = bound(depthB, 1, 100);
        uint256 tokenA = usdcA * priceA;
        uint256 usdcB = usdcA * depthB / 10;
        if (usdcB == 0) usdcB = usdcA;
        uint256 tokenB = usdcB * priceA * 10_000 / (10_000 + gapBps);

        uint256 dIn = ArbMath.optimalUsdcIn(usdcA, tokenA, FEE, usdcB, tokenB, FEE);
        if (dIn == 0) return;
        uint256 best = _profit(usdcA, tokenA, usdcB, tokenB, dIn);
        uint256 tol = 2 + best / 1e6;
        assertGe(best + tol, _profit(usdcA, tokenA, usdcB, tokenB, dIn * 99 / 100));
        assertGe(best + tol, _profit(usdcA, tokenA, usdcB, tokenB, dIn * 101 / 100));
    }

    function test_sqrtPriceAfter_followsTheCurve() public pure {
        uint160 p = uint160(1e7 << 96);
        // USDC is currency0: buying the token adds currency0, so the price falls
        uint256 down = ArbMath.sqrtPriceAfter(p, 400e6, true, 0, 400e6);
        assertEq(down, uint256(p) / 2);
        // token is the input as currency1: the price rises
        uint256 up = ArbMath.sqrtPriceAfter(p, 40_000e18, false, 0, 40_000e18);
        assertEq(up, uint256(p) * 2);
    }

    function test_sqrtPriceAfter_appliesTheFee() public pure {
        uint160 p = uint160(1e7 << 96);
        // 0.05% fee: only 99.95% of the input moves the price
        uint256 withFee = ArbMath.sqrtPriceAfter(p, 400e6, true, FEE, 400e6);
        assertEq(withFee, uint256(p) * 400e6 / (400e6 + 399.8e6));
        assertGt(withFee, ArbMath.sqrtPriceAfter(p, 400e6, true, 0, 400e6));
    }

    function _profit(uint256 usdcA, uint256 tokenA, uint256 usdcB, uint256 tokenB, uint256 dIn)
        internal
        pure
        returns (uint256)
    {
        uint256 bought = ArbMath.amountOut(usdcA, tokenA, FEE, dIn);
        uint256 back = ArbMath.amountOut(tokenB, usdcB, FEE, bought);
        return back > dIn ? back - dIn : 0;
    }
}
