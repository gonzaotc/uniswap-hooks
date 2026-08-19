// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ReHypothecationERC4626Mock, ERC4626YieldSourceMock} from "src/mocks/general/ReHypothecationERC4626Mock.sol";
import {HookTest} from "test/utils/HookTest.sol";
import {ReHypothecationHookHandler} from "../../handlers/ReHypothecationHook/ReHypothecationHookHandler.sol";

/**
 * @dev Campaign for {ReHypothecationHook} invariants. See `ReHypothecationHook.invariants.md`.
 */
contract ReHypothecationHookInvariantsTest is HookTest {
    using StateLibrary for IPoolManager;

    ReHypothecationERC4626Mock hook;
    ReHypothecationHookHandler handler;

    ERC4626YieldSourceMock yieldSource0;
    ERC4626YieldSourceMock yieldSource1;

    uint24 constant FEE = 3000;

    /// @dev Pool tick right after initialization
    int24 ghost_initialTick;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        yieldSource0 = new ERC4626YieldSourceMock(IERC20(Currency.unwrap(currency0)));
        yieldSource1 = new ERC4626YieldSourceMock(IERC20(Currency.unwrap(currency1)));

        hook = ReHypothecationERC4626Mock(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                            | Hooks.AFTER_SWAP_FLAG
                    )
                ))
        );
        deployCodeTo(
            "src/mocks/general/ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(yieldSource0), address(yieldSource1)),
            address(hook)
        );

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), FEE, SQRT_PRICE_1_1);

        handler = new ReHypothecationHookHandler(hook, manager, swapRouter, modifyLiquidityRouter, key);

        address[] memory actors = handler.actors();
        for (uint256 i; i < actors.length; ++i) {
            _fund(actors[i]);
        }

        // The hook borrows from PoolManager reserves for its JIT flash-accounting; fund the
        // singleton so a swap doesn't spuriously fail for lack of reserves (a separate, known,
        // self-healing concern, out of scope for this campaign).
        deal(Currency.unwrap(currency0), address(manager), 1e30);
        deal(Currency.unwrap(currency1), address(manager), 1e30);

        targetContract(address(handler));

        ghost_initialTick = handler.currentTick();
    }

    function _fund(address who) private {
        IERC20Minimal(Currency.unwrap(currency0)).transfer(who, 1e28);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(who, 1e28);

        vm.startPrank(who);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev INV-M-01, state side: whenever shares are outstanding, at least one currency backs
    /// them.
    function invariant_M01_sharesAreBackedByAssets() public view {
        if (hook.totalSupply() == 0) return;

        assertTrue(
            hook.getAmountInYieldSource(currency0) > 0 || hook.getAmountInYieldSource(currency1) > 0,
            "INV-M-01: shares outstanding but both currencies are unbacked"
        );
    }

    /// @dev INV-J-01: the hook holds no pool position liquidity between transactions; JIT
    /// liquidity only exists briefly inside a swap.
    function invariant_J01_noResidualPositionLiquidity() public view {
        (uint128 liquidity,,) =
            manager.getPositionInfo(key.toId(), address(hook), hook.getTickLower(), hook.getTickUpper(), bytes32(0));

        assertEq(liquidity, 0, "INV-J-01: hook holds pool position liquidity outside a swap");
    }

    /// @dev INV-J-02: the hook holds no loose currency, or native ETH, between transactions.
    function invariant_J02_noResidualCurrencyBalance() public view {
        assertEq(
            IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook)),
            0,
            "INV-J-02: hook holds loose currency0 outside a swap"
        );
        assertEq(
            IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook)),
            0,
            "INV-J-02: hook holds loose currency1 outside a swap"
        );
        assertEq(address(hook).balance, 0, "INV-J-02: hook holds loose native ETH outside a swap");
    }

    /// @dev Per-sequence coverage report: actions that reached the hook and the tick range the
    /// fuzzer landed on for this run.
    function afterInvariant() public view {
        console.log("--- STATS ---");
        _reportActions();
        _reportConfig();
    }

    function _reportActions() private view {
        uint256 setTickRangeCalls = handler.calls("setTickRange");
        uint256 addReHypothecatedLiquidityCalls = handler.calls("addReHypothecatedLiquidity");
        uint256 removeReHypothecatedLiquidityCalls = handler.calls("removeReHypothecatedLiquidity");
        uint256 addLiquidityCalls = handler.calls("addLiquidity");
        uint256 addLiquiditySaturationCalls = handler.ghost_addLiquiditySaturation();
        uint256 addLiquiditySuccess = handler.ghost_addLiquiditySuccess();
        uint256 swapCalls = handler.calls("swap");

        console.log("--- actions ---");
        console.log("setTickRange        ", setTickRangeCalls);
        console.log("addReHypothecatedLiquidity                ", addReHypothecatedLiquidityCalls);
        console.log("removeReHypothecatedLiquidity              ", removeReHypothecatedLiquidityCalls);
        console.log("addLiquidity        ", addLiquidityCalls);
        console.log("  saturation         ", addLiquiditySaturationCalls);
        console.log("  success            ", addLiquiditySuccess);
        console.log("swap                ", swapCalls);
        console.log(
            "total               ",
            setTickRangeCalls + addReHypothecatedLiquidityCalls + removeReHypothecatedLiquidityCalls + addLiquidityCalls
                + swapCalls
        );

        assertGt(setTickRangeCalls, 0, "setTickRange was not exercised");
        assertGt(addReHypothecatedLiquidityCalls, 0, "addReHypothecatedLiquidity was not exercised");
        assertGt(removeReHypothecatedLiquidityCalls, 0, "removeReHypothecatedLiquidity was not exercised");
        assertGt(addLiquidityCalls, 0, "addLiquidity was not exercised");
        assertGt(swapCalls, 0, "swap was not exercised");
    }

    function _reportConfig() private view {
        int24 tickLower = hook.getTickLower();
        int24 tickUpper = hook.getTickUpper();
        int24 currentTick = handler.currentTick();

        console.log("--- config ---");
        console.log("tickLower       ", tickLower);
        console.log("tickUpper       ", tickUpper);
        console.log("initialTick     ", ghost_initialTick);
        console.log("lastTick        ", currentTick);
    }
}
