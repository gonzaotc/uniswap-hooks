// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AntiSandwichHook} from "src/general/AntiSandwichHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract AntiSandwichMock is AntiSandwichHook {
    constructor(IPoolManager _poolManager) AntiSandwichHook(_poolManager) {}

    function withdrawFees(Currency[] calldata currencies) public {
        for (uint256 i = 0; i < currencies.length; i++) {
            uint256 balance = poolManager.balanceOf(address(this), currencies[i].toId());
            poolManager.transfer(msg.sender, currencies[i].toId(), balance);
        }
    }

    function _handleCollectedFees(PoolKey calldata key, Currency currency, uint256 feeAmount) internal override {
        // empty
    }

    // Exclude from coverage report
    function test() public {}
}
