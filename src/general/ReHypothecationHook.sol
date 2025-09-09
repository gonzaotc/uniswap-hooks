// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/general/ReHypothecationHook.sol)

pragma solidity ^0.8.24;

// External imports
import {ERC6909TokenSupply} from "@openzeppelin/contracts/token/ERC6909/extensions/draft-ERC6909TokenSupply.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
// Internal imports
import {BaseHook} from "../base/BaseHook.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";

/**
 * @dev A Uniswap V4 hook that enables rehypothecation of liquidity positions.
 *
 * This hook allows users to deposit assets into yield-generating sources (e.g., ERC-4626 vaults)
 * while still making the same capital available as swapping liquidity in Uniswap pools.
 * Assets earn yield in yield sources most of the time, but are temporarily surfaced as pool
 * liquidity through Just-in-Time (JIT) provisioning during swaps.
 *
 * Conceptually, the hook acts as an intermediary that manages:
 * - the user-facing ERC20 share token (representing rehypothecated positions), and
 * - the underlying relationship between yield sources and pool liquidity.
 *
 * Key features:
 * - Users can deposit assets into yield sources via the hook and receive ERC20 shares
 *   that represent their rehypothecated liquidity position.
 * - The hook dynamically manages pool liquidity based on available yield source assets,
 *   performing JIT provisioning during swaps.
 * - After swaps, assets are rebalanced back into yield sources to continue earning yield.
 * - Supports both ERC20 tokens and native ETH (with proper integration).
 *
 * NOTE: By default, the hook liquidity position is placed in the entire curve range. Override
 * the `getTickLower` and `getTickUpper` functions to customize the position.
 *
 * NOTE: By default, both rehypothecated and cannonical liquidity modifications are allowed. Override
 *  `beforeAddLiquidity` and `beforeRemoveLiquidity` and revert to enforce rehypothecated liquidity modifications only.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis.
 * We do not give any warranties and will not be liable for any losses incurred through any use of
 * this code base.
 * _Available since v1.1.0_
 */
abstract contract ReHypothecationHook is BaseHook, ERC6909TokenSupply {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for *;
    using Math for uint256;

    /// @dev The pool key for the hook. Note that the hook supports only one pool key.
    PoolKey private _poolKey;

    /// @dev Error thrown when attempting to add or remove zero liquidity.
    error ZeroLiquidity();

    /// @dev Error thrown when trying to initialize a pool that has already been initialized.
    error AlreadyInitialized();

    /// @dev Error thrown when attempting to interact with a pool that has not been initialized.
    error NotInitialized();

    /// @dev Error thrown when the message value doesn't match the expected amount for native ETH deposits.
    error InvalidMsgValue();

    /// @dev Error thrown when an excess ETH refund fails.
    error RefundFailed();

    /// @dev Error thrown when the calculated amounts for liquidity modification operations are invalid.
    error InvalidAmounts();

    /**
     * @dev Emitted when a `sender` adds rehypothecated `liquidity` to the `poolKey` pool,
     *  transferring `amount0` of `currency0` and `amount1` of `currency1` to the hook.
     */
    event ReHypothecatedLiquidityAdded(
        address indexed sender, PoolKey indexed poolKey, uint256 amount0, uint256 amount1
    );

    /**
     * @dev Emitted when a `sender` removes rehypothecated `liquidity` from the `poolKey` pool,
     *  receiving `amount0` of `currency0` and `amount1` of `currency1` from the hook.
     */
    event ReHypothecatedLiquidityRemoved(
        address indexed sender, PoolKey indexed poolKey, uint256 amount0, uint256 amount1
    );

    /**
     * @dev Sets the `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Returns the `poolKey` for the hook pool.
     */
    function getPoolKey() public view returns (PoolKey memory poolKey) {
        return _poolKey;
    }

    /**
     * @dev Initialize the hook's `poolKey`. The stored key by the hook is unique and
     * should not be modified so that it can safely be used across the hook's lifecycle.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (address(_poolKey.hooks) != address(0)) revert AlreadyInitialized();
        _poolKey = key;
        return this.beforeInitialize.selector;
    }

    /**
     * @dev Adds rehypothecated `liquidity` to the pool, returns the caller's `delta`, and mints ERC20 shares to them.
     *
     * This function calculates the required amounts of both currencies based on the desired liquidity, transfers the assets
     * from the user, deposits them into yield sources, and mints shares to the user representing the user's position.
     *
     * Returns a balance `delta` representing the assets deposited into the hook.
     *
     * Requirements:
     * - Pool must be initialized
     *
     * Note: The hook might accept native currency, in which case the function `_depositToYieldSource` must be
     * overridden to handle it.
     */
    function addReHypothecatedLiquidity(uint256 amount0, uint256 amount1)
        public
        payable
        virtual
        returns (BalanceDelta delta)
    {
        if (address(_poolKey.hooks) == address(0)) revert NotInitialized();
        // if (liquidity == 0) revert ZeroLiquidity();

        // Calculate the relationship between `amount` and `liquidity` to achieve the target liquidity,
        // considering the current price and tick boundaries
        // (uint256 amount0, uint256 amount1) = _getAmountsForLiquidity(liquidity);

        if (amount0 > 0) {
            uint256 amount0shares = previewDeposit(_poolKey.currency0, amount0);
            _depositToYieldSource(_poolKey.currency0, amount0);
            _mint(msg.sender, _poolKey.currency0.toId(), amount0shares);
        }
        if (amount1 > 0) {
            uint256 amount1shares = previewDeposit(_poolKey.currency1, amount1);
            _depositToYieldSource(_poolKey.currency1, amount1);
            _mint(msg.sender, _poolKey.currency1.toId(), amount1shares);
        }

        emit ReHypothecatedLiquidityAdded(msg.sender, _poolKey, amount0, amount1);

        return toBalanceDelta(int256(amount0).toInt128(), int256(amount1).toInt128());
    }

    /**
     * @dev Removes rehypothecated `liquidity` for a given sender and burns their shares.
     *
     * This function calculates the required amounts of both currencies based on the desired liquidity
     * to be removed, withdraws the assets from the yield sources, and burns the shares from the user.
     *
     * Returns a balance `delta` representing the assets withdrawn from the hook.
     *
     * Requirements:
     * - Pool must be initialized
     * - Sender must have enough shares to remove the desired liquidity
     *
     */
    function removeReHypothecatedLiquidity(uint256 amount0, uint256 amount1)
        public
        virtual
        returns (BalanceDelta delta)
    {
        if (address(_poolKey.hooks) == address(0)) revert NotInitialized();
        // if (liquidity == 0) revert ZeroLiquidity();

        // (uint256 amount0, uint256 amount1) = _getAmountsForLiquidity(liquidity);

        if (amount0 > 0) {
            uint256 amount0shares = previewWithdraw(_poolKey.currency0, amount0);
            _burn(msg.sender, _poolKey.currency0.toId(), amount0shares);
            _withdrawFromYieldSource(_poolKey.currency0, amount0);
        }
        if (amount1 > 0) {
            uint256 amount1shares = previewWithdraw(_poolKey.currency1, amount1);
            _burn(msg.sender, _poolKey.currency1.toId(), amount1shares);
            _withdrawFromYieldSource(_poolKey.currency1, amount1);
        }

        emit ReHypothecatedLiquidityRemoved(msg.sender, _poolKey, amount0, amount1);

        return toBalanceDelta(int256(amount0).toInt128(), int256(amount1).toInt128());
    }

    /**
     * @dev Returns the amount of shares that would be minted for a given amount of liquidity.
     */
    function previewDeposit(Currency currency, uint256 liquidity) public view virtual returns (uint256) {
        return _convertToShares(currency, liquidity, Math.Rounding.Floor);
    }

    /**
     * @dev Returns the amount of shares that would be burned for a given amount of liquidity.
     */
    function previewWithdraw(Currency currency, uint256 liquidity) public view virtual returns (uint256) {
        return _convertToShares(currency, liquidity, Math.Rounding.Ceil);
    }

    /**
     * @dev Internal conversion function (from liquidity to shares) with support for rounding direction.
     */
    function _convertToShares(Currency currency, uint256 liquidity, Math.Rounding rounding)
        internal
        view
        virtual
        returns (uint256)
    {
        uint256 sharesTotalSupply = totalSupply(currency.toId());
        uint256 amountInYieldSource = _getAmountInYieldSource(currency);
        return liquidity.mulDiv(sharesTotalSupply + 10 ** _decimalsOffset(), amountInYieldSource + 1, rounding);
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }

    /**
     * @dev Returns the total hook-owned liquidity units from the amounts currently deposited in the yield sources.
     */
    // function _getTotalLiquidity() internal view virtual returns (uint256) {
    //     uint256 totalAmount0 = _getAmountInYieldSource(_poolKey.currency0);
    //     uint256 totalAmount1 = _getAmountInYieldSource(_poolKey.currency1);
    //     return _getLiquidityForAmounts(totalAmount0, totalAmount1);
    // }

    /**
     * @dev Retrieves the current `liquidity` of the hook owned liquidity position in the `_poolKey` pool.
     *
     * WARNING: Given that we are doing just-in-time liquidity provisioning, the liquidity will only be inside the
     * hook's position between `beforeSwap` and `afterSwap`. It will be zero in any other point in the hook lifecycle.
     */
    function _getHookPositionLiquidity() internal view virtual returns (uint128 liquidity) {
        bytes32 positionKey = Position.calculatePositionKey(address(this), getTickLower(), getTickUpper(), bytes32(0));
        return poolManager.getPositionLiquidity(_poolKey.toId(), positionKey);
    }

    /**
     * @dev Determines the liquidity to add to the pool.
     *
     * By default, returns the maximum `liquidity` that can be added to the pool at the
     * current price given the current `amount0` and `amount1` in the yield sources.
     *
     * Note that if the `amount0` and `amount1` are not in the same ratio as the current price,
     * the liquidity returned will not be using all the `amount0` and `amount1` available.
     *
     * i.e, if the current price is 1:1, and the hook has 200 `amount0` and 500 `amount1` in the yield sources,
     * 200 `amount0` and `200` `amount1` will be used (balanced to the pool price ratio), while 300 `amount1`
     * will be left unused in the yield sources.
     *
     * However, since we know the swap direction, we can optimize doing single-currency liquidity provisioning, by
     * putting 100% of the available funds in the pool.
     */
    function _getLiquidityToUse() internal view virtual returns (uint256 liquidity) {
        uint256 amount0 = _getAmountInYieldSource(_poolKey.currency0);
        uint256 amount1 = _getAmountInYieldSource(_poolKey.currency1);
        return _getLiquidityForAmounts(amount0, amount1);
    }

    /**
     * @dev Hook executed before a swap operation to provide liquidity from rehypothecated assets.
     *
     * This function gets the amount of liquidity to be provided from yield sources and temporarily
     * adds it to the pool, in a Just-in-Time provision of liquidity.
     *
     * Note that at this point there are no actual transfers of tokens happening to the pool, instead,
     * thanks to the Flash Accounting model this addition creates a currencyDelta to the hook, which
     * must be settled during the `_afterSwap` function before locking the poolManager again.
     */
    function _beforeSwap(
        address, /* sender */
        PoolKey calldata, /* key */
        SwapParams calldata, /* params */
        bytes calldata /* hookData */
    ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        // Get the total hook-owned liquidity from the amounts currently deposited in the yield sources
        uint256 totalLiquidity = _getLiquidityToUse();

        // Add liquidity to the pool (in a Just-in-Time provision of liquidity)
        if (totalLiquidity > 0) _modifyLiquidity(totalLiquidity.toInt256());

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev Hook executed after a swap operation to remove temporary liquidity and rebalance assets.
     *
     * This function removes the liquidity that was temporarily added in `_beforeSwap`, and resolves
     * the hook's deltas in each currency in order to zero them.
     */
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata, /* params */
        BalanceDelta, /* delta */
        bytes calldata /* hookData */
    ) internal virtual override returns (bytes4, int128) {
        // Remove all of the hook owned liquidity from the pool
        uint128 liquidity = _getHookPositionLiquidity();
        if (liquidity > 0) {
            _modifyLiquidity(-liquidity.toInt256());

            // Take or settle any pending deltas with the PoolManager
            _resolveHookDelta(key.currency0);
            _resolveHookDelta(key.currency1);
        }

        return (this.afterSwap.selector, 0);
    }

    /**
     * @dev Returns the lower tick boundary for the hook's liquidity position.
     */
    function getTickLower() public view virtual returns (int24) {
        return TickMath.minUsableTick(_poolKey.tickSpacing);
    }

    /**
     * @dev Returns the upper tick boundary for the hook's liquidity position.
     */
    function getTickUpper() public view virtual returns (int24) {
        return TickMath.maxUsableTick(_poolKey.tickSpacing);
    }

    /**
     * @dev Calculates the amounts required for adding a specific amount of liquidity.
     *
     * This function uses the current price and tick boundaries to determine the exact amounts
     * of both currencies needed to achieve the target liquidity.
     */
    // function _getAmountsForLiquidity(uint128 liquidity)
    //     internal
    //     view
    //     virtual
    //     returns (uint256 amount0, uint256 amount1)
    // {
    //     (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(_poolKey.toId());
    //     return LiquidityAmounts.getAmountsForLiquidity(
    //         currentSqrtPriceX96,
    //         TickMath.getSqrtPriceAtTick(getTickLower()),
    //         TickMath.getSqrtPriceAtTick(getTickUpper()),
    //         liquidity
    //     );
    // }

    /**
     * @dev Calculates the amount of liquidity required for a given amount of tokens.
     *
     * This function uses the current price and tick boundaries to determine the exact amount of liquidity
     * required to achieve the target amounts of both currencies.
     */
    function _getLiquidityForAmounts(uint256 amount0, uint256 amount1)
        internal
        view
        virtual
        returns (uint128 liquidity)
    {
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(_poolKey.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            currentSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(getTickLower()),
            TickMath.getSqrtPriceAtTick(getTickUpper()),
            amount0,
            amount1
        );
    }

    /**
     * @dev Modifies the hook's liquidity position in the pool.
     *
     * This function adds or removes liquidity from the hook's position using the pool manager.
     *
     * Positive liquidityDelta adds liquidity, while negative removes it.
     */
    function _modifyLiquidity(int256 liquidityDelta) internal virtual returns (BalanceDelta delta) {
        (delta,) = poolManager.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({
                tickLower: getTickLower(),
                tickUpper: getTickUpper(),
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /**
     * @dev Takes or settles any pending `currencyDelta` amount with the poolManager, effectively
     * resolving the Flash Accounting requirements before locking the poolManager again.
     */
    function _resolveHookDelta(Currency currency) internal virtual {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);
        if (currencyDelta > 0) {
            currency.take(poolManager, address(this), currencyDelta.toUint256(), false);
            _depositToYieldSource(currency, currencyDelta.toUint256());
        }
        if (currencyDelta < 0) {
            _withdrawFromYieldSource(currency, (-currencyDelta).toUint256());
            currency.settle(poolManager, address(this), (-currencyDelta).toUint256(), false);
        }
    }

    /**
     * @dev Returns the `yieldSource` address for a given `currency`.
     *
     * Note: Must be implemented and adapted for the desired type of yield sources, such as
     *  ERC-4626 Vaults, or any custom DeFi protocol interface, optionally handling native currency.
     */
    function getCurrencyYieldSource(Currency currency) public view virtual returns (address yieldSource);

    /**
     * @dev Deposits a specified `amount` of `currency` into its corresponding yield source.
     *
     * This function must take the `amount` of `currency` from the sender and deposit it into the yield source.
     *
     * Note: Must be implemented and adapted for the desired type of yield sources, such as
     *  ERC-4626 Vaults, or any custom DeFi protocol interface, optionally handling native currency.
     */
    function _depositToYieldSource(Currency currency, uint256 amount) internal virtual;

    /**
     * @dev Withdraws a specified `amount` of `currency` from its corresponding yield source.
     *
     * This function must withdraw the `amount` of `currency` from the yield source and return them
     * to the hook for further processing (e.g., transferring to users or adding to pool liquidity).
     *
     * Note: Must be implemented and adapted for the desired type of yield sources, such as
     *  ERC-4626 Vaults, or any custom DeFi protocol interface, optionally handling native currency.
     */
    function _withdrawFromYieldSource(Currency currency, uint256 amount) internal virtual;

    /**
     * @dev Gets the `amount` of `currency` deposited in its corresponding yield source.
     *
     * This function must return the `amount` of `currency` deposited in its corresponding yield source.
     *
     * Note: Must be implemented and adapted for the desired type of yield sources, such as
     *  ERC-4626 Vaults, or any custom DeFi protocol interface, optionally handling native currency.
     */
    function _getAmountInYieldSource(Currency currency) internal view virtual returns (uint256 amount);

    /**
     * Set the hooks permissions, specifically `beforeInitialize`, `beforeSwap`, `afterSwap`.
     * @return permissions The permissions for the hook.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
