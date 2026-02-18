// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/utils/Quoter.sol)

pragma solidity ^0.8.26;

import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @dev Utility contract for on-chain mutation-safe quotes at arbitrary pool states.
 *
 * The revert rolls back all writes produced during quote execution, preserving the quoted state unchanged.
 *
 * NOTE: Inheriting contracts must provide pool state lookup through {_getPoolStateForQuote}.
 */
abstract contract StatefulQuoter {
    /// @dev Reverted by quote execution to return the quoted swap delta.
    error QuoteSwapAtPoolState(BalanceDelta swapDelta);

    /// @dev Thrown when quote execution succeeds unexpectedly.
    error UnexpectedQuoteSuccess();

    /// @dev Thrown when a quote-only entrypoint is called by non-self.
    error NotSelfCall();

    /// @dev Restricts quote-only entrypoints to self-calls.
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelfCall();
        _;
    }

    /**
     * @dev Quotes a swap at the given stored pool state defined by {_getPoolStateForQuote}
     * without persisting intermediate mutations.
     */
    function _quoteSwapAtPoolState(PoolId poolId, Pool.SwapParams memory swapParams)
        internal
        returns (BalanceDelta swapDelta)
    {
        try this.quoteSwapAtPoolState(poolId, swapParams) {
            revert UnexpectedQuoteSuccess();
        } catch (bytes memory reason) {
            return _parseQuoteSwapAtPoolState(reason);
        }
    }

    /**
     * @dev Parses quote payloads and bubbles non-quote reverts.
     */
    function _parseQuoteSwapAtPoolState(bytes memory reason) internal pure returns (BalanceDelta swapDelta) {
        if (reason.length == 0) revert UnexpectedQuoteSuccess();

        uint32 selector;
        assembly ("memory-safe") {
            selector := shr(224, mload(add(reason, 0x20)))
        }

        if (selector == uint32(bytes4(QuoteSwapAtPoolState.selector))) {
            assembly ("memory-safe") {
                swapDelta := mload(add(reason, 0x24))
            }
            return swapDelta;
        }

        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }

    /**
     * @dev Executes `Pool.swap` against the pool state defined by {_getPoolStateForQuote}
     * and reverts with encoded quote.
     */
    function quoteSwapAtPoolState(PoolId poolId, Pool.SwapParams calldata params) external selfOnly {
        (BalanceDelta swapDelta,,,) = Pool.swap(_getPoolStateForQuote(poolId), params);
        revert QuoteSwapAtPoolState(swapDelta);
    }

    /**
     * @dev Determines the storage pool state to be used during quote simulation.
     */
    function _getPoolStateForQuote(PoolId poolId) internal virtual returns (Pool.State storage);
}
