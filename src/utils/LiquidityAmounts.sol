// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.2) (src/utils/LiquidityAmounts.sol)

pragma solidity ^0.8.26;

// External imports
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @dev Library for computing token amounts and liquidity for a position, given prices at the position's
 * boundaries and the current pool price.
 *
 * Based on the https://github.com/Uniswap/v4-core/blob/main/test/utils/LiquidityAmounts.sol[Uniswap v4 test
 * utils implementation], with two differences: uses {Math-mulDiv} for full-precision, rounding-aware
 * arithmetic instead of `FullMath`, and lets the caller choose the rounding direction on every function.
 *
 * WARNING: For `getLiquidityForAmount0`, `getLiquidityForAmount1` and `getLiquidityForAmounts`, rounding
 * up is unsafe when the amounts represent a balance you actually hold: it can compute a `liquidity` value
 * that costs more than that balance to provide, which then fails or overdraws elsewhere. Round down unless
 * you have a specific reason not to.
 */
library LiquidityAmounts {
    using SafeCast for uint256;

    /**
     * @dev Computes the amount of liquidity received for a given amount of token0 and price range, rounding
     * according to `rounding`.
     *
     * Calculates `amount0 * (sqrt(upper) * sqrt(lower)) / (sqrt(upper) - sqrt(lower))`.
     */
    function getLiquidityForAmount0(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        Math.Rounding rounding
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        uint256 intermediate = Math.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96, rounding);
        return Math.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96, rounding).toUint128();
    }

    /**
     * @dev Computes the amount of liquidity received for a given amount of token1 and price range, rounding
     * according to `rounding`.
     *
     * Calculates `amount1 / (sqrt(upper) - sqrt(lower))`.
     */
    function getLiquidityForAmount1(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount1,
        Math.Rounding rounding
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        return Math.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96, rounding).toUint128();
    }

    /**
     * @dev Computes the maximum amount of liquidity received for a given amount of token0, token1, the
     * current pool price and the prices at the tick boundaries, rounding according to `rounding`.
     */
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1,
        Math.Rounding rounding
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0, rounding);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0, rounding);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1, rounding);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1, rounding);
        }
    }

    /**
     * @dev Computes the amount of token0 for a given amount of liquidity and a price range, rounding
     * according to `rounding`.
     */
    function getAmount0ForLiquidity(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity,
        Math.Rounding rounding
    ) internal pure returns (uint256 amount0) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        uint256 numerator = Math.mulDiv(
            uint256(liquidity) << FixedPoint96.RESOLUTION, sqrtPriceBX96 - sqrtPriceAX96, sqrtPriceBX96, rounding
        );
        return Math.mulDiv(numerator, 1, sqrtPriceAX96, rounding);
    }

    /**
     * @dev Computes the amount of token1 for a given amount of liquidity and a price range, rounding
     * according to `rounding`.
     */
    function getAmount1ForLiquidity(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity,
        Math.Rounding rounding
    ) internal pure returns (uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        return Math.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96, rounding);
    }

    /**
     * @dev Computes the token0 and token1 value for a given amount of liquidity, the current pool price
     * and the prices at the tick boundaries, rounding according to `rounding`.
     */
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity,
        Math.Rounding rounding
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = getAmount0ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity, rounding);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = getAmount0ForLiquidity(sqrtPriceX96, sqrtPriceBX96, liquidity, rounding);
            amount1 = getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceX96, liquidity, rounding);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity, rounding);
        }
    }
}
