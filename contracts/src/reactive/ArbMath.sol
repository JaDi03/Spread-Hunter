// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title ArbMath
/// @notice Constant-product math for buying a token on one pool and selling it on another.
/// Fees are in pips (1e6 = 100%) and charged on the input, as Uniswap V4 does.
library ArbMath {
    uint256 internal constant PIPS = 1e6;

    /// @notice Virtual reserves of a pool from its price and active liquidity.
    /// @return usdc Reserve of the USDC side; @return token Reserve of the token side.
    function reserves(uint160 sqrtPriceX96, uint128 liquidity, bool usdcIsCurrency0)
        internal
        pure
        returns (uint256 usdc, uint256 token)
    {
        uint256 reserve0 = FullMath.mulDiv(liquidity, FixedPoint96.Q96, sqrtPriceX96);
        uint256 reserve1 = FullMath.mulDiv(liquidity, sqrtPriceX96, FixedPoint96.Q96);
        (usdc, token) = usdcIsCurrency0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @notice True when the token is cheaper in USDC on pool A than on pool B.
    function cheaperOnA(uint256 usdcA, uint256 tokenA, uint256 usdcB, uint256 tokenB) internal pure returns (bool) {
        return usdcA * tokenB < usdcB * tokenA;
    }

    /// @notice Output of one swap.
    function amountOut(uint256 reserveIn, uint256 reserveOut, uint24 fee, uint256 amountIn)
        internal
        pure
        returns (uint256)
    {
        uint256 netIn = amountIn * (PIPS - fee);
        return FullMath.mulDiv(reserveOut, netIn, reserveIn * PIPS + netIn);
    }

    /// @notice Input that buys at most `out` from one swap; 0 when `out` is the whole reserve or more.
    function amountInFor(uint256 reserveIn, uint256 reserveOut, uint24 fee, uint256 out)
        internal
        pure
        returns (uint256)
    {
        if (out >= reserveOut) return 0;
        return FullMath.mulDiv(reserveIn * PIPS, out, (PIPS - fee) * (reserveOut - out));
    }

    /// @notice USDC to spend on pool A that maximizes USDC back from selling the bought token on pool B.
    /// @dev The two swaps compose into one constant-product swap with reserves e0 and e1; its optimum is
    /// (sqrt(rA * e0 * e1) - e0) / rA. Returns 0 when there is no gain.
    function optimalUsdcIn(uint256 usdcA, uint256 tokenA, uint24 feeA, uint256 usdcB, uint256 tokenB, uint24 feeB)
        internal
        pure
        returns (uint256)
    {
        uint256 rA = PIPS - feeA;
        uint256 rB = PIPS - feeB;
        uint256 den = tokenB * PIPS + rB * tokenA;
        uint256 e0 = FullMath.mulDiv(usdcA, tokenB * PIPS, den);
        uint256 e1 = FullMath.mulDiv(usdcB, rB * tokenA, den);
        if (rA * e1 <= PIPS * e0) return 0;
        uint256 root = Math.sqrt(FullMath.mulDiv(e0 * rA, e1, PIPS));
        if (root <= e0) return 0;
        return FullMath.mulDiv(root - e0, PIPS, rA);
    }

    /// @notice Pool price after swapping `amountIn` of the input side, from the input's virtual reserve.
    function sqrtPriceAfter(
        uint160 sqrtPriceX96,
        uint256 reserveIn,
        bool inputIsCurrency0,
        uint24 fee,
        uint256 amountIn
    ) internal pure returns (uint256) {
        uint256 netIn = amountIn * (PIPS - fee) / PIPS;
        return inputIsCurrency0
            ? FullMath.mulDiv(sqrtPriceX96, reserveIn, reserveIn + netIn)
            : FullMath.mulDiv(sqrtPriceX96, reserveIn + netIn, reserveIn);
    }
}
