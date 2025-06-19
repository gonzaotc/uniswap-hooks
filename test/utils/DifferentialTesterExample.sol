// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DifferentialTester} from "./DifferentialTester.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {AntiSandwichMock} from "../mocks/AntiSandwichMock.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDeltaAssertions} from "./BalanceDeltaAssertions.sol";

/**
 * @title DifferentialTesterUsageExample
 * @notice Example showing how to refactor AntiSandwichHook.t.sol using DifferentialTester
 */
contract DifferentialTesterUsageExample is DifferentialTester, BalanceDeltaAssertions {
    AntiSandwichMock hook;
    PoolKey hookedPoolKey;
    PoolKey unhookedPoolKey;

    int128 constant SWAP_AMOUNT_1e15 = 1e15;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy your hook (commented out for example)
        hook = AntiSandwichMock(
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG))
        );
        deployCodeTo("AntiSandwichMock.sol:AntiSandwichMock", abi.encode(manager), address(hook));

        // Initialize pools - one with hooks, one without
        (hookedPoolKey,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        (unhookedPoolKey,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(0)), 100, SQRT_PRICE_1_1
        );

        // Initialize differential testing
        initDifferentialTester(hookedPoolKey, unhookedPoolKey);
    }

    /// @notice Example of using DifferentialTester to test a swap
    function test_swap() public {
        int256 SWAP_AMOUNT = -1e15;

        // Front run - this automatically executes on both pools
        DiffSwapResult memory frontRun = diffSwap(true, SWAP_AMOUNT, "");
        assertNotEq(frontRun.hooked.swapDelta, frontRun.unhooked.swapDelta, "front run");

        // User swap - this automatically executes on both pools
        DiffSwapResult memory userSwap = diffSwap(true, SWAP_AMOUNT, "");
        assertNotEq(userSwap.hooked.swapDelta, userSwap.unhooked.swapDelta, "user swap");

        // Back run - this automatically executes on both pools
        DiffSwapResult memory backRun = diffSwap(true, SWAP_AMOUNT, "");
        assertNotEq(backRun.hooked.swapDelta, backRun.unhooked.swapDelta, "back run");
    }
}
