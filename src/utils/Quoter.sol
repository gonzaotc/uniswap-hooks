// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/utils/Quoter.sol)

pragma solidity ^0.8.26;

import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @dev Utility contract for mutation-safe pool state quotes.
 *
 * `quoteAtPoolState` executes `Pool.swap` in a self-call and then intentionally reverts with encoded quote data.
 * The revert rolls back all writes produced during quote execution, preserving the quoted state unchanged.
 *
 * NOTE: Inheriting contracts must provide pool state lookup through {_getPoolStateForQuote}.
 */
abstract contract Quoter {
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
     * @dev Quotes a swap at the given stored pool state without persisting intermediate mutations.
     *
     * WARNING: This function is non-view on purpose because it invokes `Pool.swap`, but all writes are reverted.
     *
     * @param poolId The id used by inheritors to resolve the quoted pool state.
     * @param swapParams The swap configuration used for simulation.
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
     *
     * The expected payload is the ABI encoding of `QuoteSwapAtPoolState(BalanceDelta)`.
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
     * @dev Executes `Pool.swap` against the selected state and reverts with encoded quote.
     */
    function quoteSwapAtPoolState(PoolId poolId, Pool.SwapParams calldata params) external selfOnly {
        (BalanceDelta swapDelta,,,) = Pool.swap(_getPoolStateForQuote(poolId), params);
        revert QuoteSwapAtPoolState(swapDelta);
    }

    /**
     * @dev Resolves the storage pool state to be used during quote simulation.
     */
    function _getPoolStateForQuote(PoolId poolId) internal virtual returns (Pool.State storage);
}
