// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
// Internal imports
import {AntiSandwichHook} from "../../general/AntiSandwichHook.sol";
import {CurrencySettler} from "../../utils/CurrencySettler.sol";
import {BaseHook} from "../../base/BaseHook.sol";

contract AntiSandwichMock is AntiSandwichHook {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    struct AccumulatedFees {
        uint256 amount0;
        uint256 amount1;
    }

    mapping(PoolId poolId => AccumulatedFees accumulatedFees) private _accumulatedFees;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Handles the excess tokens collected during the swap due to the anti-sandwich mechanism.
     * When a swap executes at a worse price than what's currently available in the pool (due to
     * enforcing the beginning-of-block price), the excess tokens are donated back to the pool
     * to benefit all liquidity providers.
     *
     * WARNING: This example handles the accumulated anti-sandwich fees by donating the excess tokens to in-range
     * liquidity providers. Be aware that this type of donations may be vulnerable to JIT attacks. If this particular
     * type of handling is desired, consider combining with a JIT protection mechanism such as
     * https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/general/LiquidityPenaltyHook.sol[LiquidityPenaltyHook].
     */
    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        uint256,
        uint256 feeAmount
    ) internal override {
        PoolId poolId = key.toId();

        bool feeIsCurrency0 = (params.amountSpecified < 0 == params.zeroForOne);

        AccumulatedFees storage accumulatedFees = _accumulatedFees[poolId];

        // Donate only if there is in-range liquidity to receive donations, accumulate otherwise.
        if (poolManager.getLiquidity(poolId) != 0) {
            uint256 fees0;
            uint256 fees1;
            if (feeIsCurrency0) {
                fees0 = feeAmount + accumulatedFees.amount0;
                fees1 = accumulatedFees.amount1;
            } else {
                fees0 = accumulatedFees.amount0;
                fees1 = feeAmount + accumulatedFees.amount1;
            }

            poolManager.donate(key, fees0, fees1, "");
            if (fees0 > 0) key.currency0.settle(poolManager, address(this), fees0, true);
            if (fees1 > 0) key.currency1.settle(poolManager, address(this), fees1, true);

            accumulatedFees.amount0 = 0;
            accumulatedFees.amount1 = 0;
        } else {
            accumulatedFees.amount0 += feeAmount;
            accumulatedFees.amount1 += feeAmount;
        }
    }

    /**
     * @dev Exposes checkpoint quoting for tests.
     */
    function quoteSwapAtCheckpoint(PoolKey calldata key, SwapParams calldata params) external returns (BalanceDelta) {
        return quoteSwapAtPoolState(
            key.toId(),
            Pool.SwapParams({
                tickSpacing: key.tickSpacing,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                lpFeeOverride: 0
            })
        );
    }

    // Exclude from coverage report
    function test() public {}
}
