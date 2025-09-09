// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// Internal imports
import {ReHypothecationHook} from "../general/ReHypothecationHook.sol";

/// @title ERC4626Mock
/// @notice A mock implementation of the ERC-4626 yield source.
contract ERC4626Mock is ERC4626 {
    constructor(IERC20 token, string memory name, string memory symbol) ERC4626(token) ERC20(name, symbol) {}
}

/// @title ReHypothecationERC4626Mock
/// @notice A mock implementation of the ReHypothecationHook for ERC-4626 yield sources.
contract ReHypothecationERC4626Mock is ReHypothecationHook {
    using SafeERC20 for IERC20;

    address private _yieldSource0;
    address private _yieldSource1;

    /// @dev Error thrown when attempting to use an unsupported currency.
    error UnsupportedCurrency();

    constructor(IPoolManager poolManager_, address yieldSource0_, address yieldSource1_)
        ReHypothecationHook(poolManager_)
    {
        _yieldSource0 = yieldSource0_;
        _yieldSource1 = yieldSource1_;
    }

    /// @inheritdoc ReHypothecationHook
    function getCurrencyYieldSource(Currency currency) public view override returns (address) {
        PoolKey memory poolKey = getPoolKey();
        if (currency == poolKey.currency0) return _yieldSource0;
        if (currency == poolKey.currency1) return _yieldSource1;
        revert UnsupportedCurrency();
    }

    /// @inheritdoc ReHypothecationHook
    function _depositToYieldSource(Currency currency, uint256 amount) internal virtual override {
        // In this ERC4626 implementation, native currency is not supported.
        if (currency.isAddressZero()) revert UnsupportedCurrency();
        IERC20 token = IERC20(Currency.unwrap(currency));

        IERC4626 yieldSource = IERC4626(getCurrencyYieldSource(currency));
        if (address(yieldSource) == address(0)) revert UnsupportedCurrency();

        token.safeTransferFrom(msg.sender, address(this), amount);
        token.approve(address(yieldSource), amount);
        yieldSource.deposit(amount, address(this));
    }

    /// @inheritdoc ReHypothecationHook
    function _withdrawFromYieldSource(Currency currency, uint256 amount) internal virtual override {
        IERC4626 yieldSource = IERC4626(getCurrencyYieldSource(currency));
        if (address(yieldSource) == address(0)) revert UnsupportedCurrency();

        yieldSource.withdraw(amount, address(this), address(this));
        currency.transfer(msg.sender, amount);
    }

    /// @inheritdoc ReHypothecationHook
    function _getAmountInYieldSource(Currency currency) internal view virtual override returns (uint256 amount) {
        IERC4626 yieldSource = IERC4626(getCurrencyYieldSource(currency));
        uint256 yieldSourceShares = yieldSource.balanceOf(address(this));
        return yieldSource.convertToAssets(yieldSourceShares);
    }

    // Exclude from coverage report
    function test() public {}
}
