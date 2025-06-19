// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookTest} from "./HookTest.sol";

/**
 * @title DifferentialTester
 * @notice Testing utility for comparing hook behavior against unhooked baseline
 * @dev Provides generic abstraction for executing identical operations on both hooked and unhooked pools
 */
abstract contract DifferentialTester is HookTest {
    /// @notice Result structure for liquidity modification operations
    struct LiquidityResult {
        BalanceDelta callerDelta;
        BalanceDelta feesAccrued;
    }

    /// @notice Result structure for liquidity modification operations with both pools
    struct DiffLiquidityResult {
        LiquidityResult hooked;
        LiquidityResult unhooked;
    }

    /// @notice The hooked pool key
    PoolKey private _hookedPool;

    /// @notice The unhooked pool key (baseline comparison)
    PoolKey private _unhookedPool;

    /// @notice Initialize the differential testing setup
    /// @param hookedPool Pool with hooks enabled
    /// @param unhookedPool Pool without hooks (baseline)
    function initDifferentialTester(PoolKey memory hookedPool, PoolKey memory unhookedPool) internal {
        _hookedPool = hookedPool;
        _unhookedPool = unhookedPool;
    }

    /// @notice Result structure for swap operations
    struct SwapResult {
        BalanceDelta swapDelta;
    }

    /// @notice Result structure for swap operations with both pools
    struct DiffSwapResult {
        SwapResult hooked;
        SwapResult unhooked;
    }

    /**
     * @notice Execute swap on both pools
     * @param zeroForOne Direction of the swap
     * @param amountSpecified Amount to swap (negative for exact input, positive for exact output)
     * @param hookData Additional data for hooks
     * @return result DiffSwapResult as a tuple of the results of the swap on both pools
     */
    function diffSwap(bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (DiffSwapResult memory result)
    {
        result.hooked.swapDelta = swap(_hookedPool, zeroForOne, amountSpecified, hookData);
        result.unhooked.swapDelta = swap(_unhookedPool, zeroForOne, amountSpecified, hookData);
        return result;
    }

    /**
     * @notice Execute modifyLiquidity on both pools
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @param liquidity Liquidity change amount
     * @param salt Unique identifier for position
     * @return result DiffLiquidityResult as a tuple of the results of the liquidity modification on both pools
     */
    function diffModifyLiquidity(int24 tickLower, int24 tickUpper, int256 liquidity, bytes32 salt)
        internal
        returns (DiffLiquidityResult memory result)
    {
        // @tbd Modify `HookTest.sol` `Deployers.sol` core dependency so `modifyLiquidity` returns both `callerDelta` and `feesAccrued`
        (result.hooked.callerDelta) = modifyLiquidity(_hookedPool, tickLower, tickUpper, liquidity, salt);
        (result.unhooked.callerDelta) = modifyLiquidity(_unhookedPool, tickLower, tickUpper, liquidity, salt);
        return result;
    }
}
