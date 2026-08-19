// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ReHypothecationERC4626Mock} from "src/mocks/general/ReHypothecationERC4626Mock.sol";
import {BaseHandler} from "../BaseHandler.sol";

/**
 * @dev Handler for `ReHypothecationHook` invariant campaigns.
 *
 * Fuzzable surface:
 * - `setTickRange` (once)
 * - `addReHypothecatedLiquidity`
 * - `removeReHypothecatedLiquidity`
 * - `addLiquidity`
 * - `swap`
 */
contract ReHypothecationHookHandler is BaseHandler {
    using StateLibrary for IPoolManager;

    ReHypothecationERC4626Mock public hook;

    /// @dev Fuzzer bounds for `shares`, biased low to hunt the rounding corner in INV-M-01.
    uint256 internal constant MINT_SHARES_MIN_BOUND = 1;
    uint256 internal constant MINT_SHARES_MAX_BOUND = 1e6;

    /// @dev Fuzzer bounds for a swap's input amount.
    uint256 internal constant SWAP_AMOUNT_MIN_BOUND = 1;
    uint256 internal constant SWAP_AMOUNT_MAX_BOUND = 1e21;

    /// @dev 1-in-4 `addLiquidity` calls target one of the hook's own boundary ticks; the rest
    /// are fully randomized.
    uint256 internal constant ADD_LIQUIDITY_BOUNDARY_TARGET_DIVISOR = 4;

    /// @dev Count of `addLiquidity` calls that targeted a boundary tick.
    uint256 public ghost_addLiquiditySaturation;

    /// @dev Count of `addLiquidity` calls that succeeded.
    uint256 public ghost_addLiquiditySuccess;

    constructor(
        ReHypothecationERC4626Mock hook_,
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        PoolModifyLiquidityTest modifyLiquidityRouter_,
        PoolKey memory key_
    ) {
        hook = hook_;
        manager = manager_;
        swapRouter = swapRouter_;
        modifyLiquidityRouter = modifyLiquidityRouter_;
        key = key_;
        poolId = key_.toId();

        address[] memory actors_ = new address[](4);
        actors_[0] = makeAddr("alice");
        actors_[1] = makeAddr("bob");
        actors_[2] = makeAddr("carol");
        actors_[3] = makeAddr("dave");
        _createActors(actors_);
    }

    // ------------------ FUZZABLE SURFACE ------------------ //

    /// @dev Sets the hook's tick range once; spacing-aligned and valid by construction.
    function setTickRange(int24 tickLowerSeed, int24 tickUpperSeed) external recordCall("setTickRange") {
        vm.assume(!isTickRangeSet());

        int24 spacing = key.tickSpacing;
        int256 minUnits = TickMath.minUsableTick(spacing) / spacing;
        int256 maxUnits = TickMath.maxUsableTick(spacing) / spacing;

        int256 lowerUnits = bound(int256(tickLowerSeed), minUnits, maxUnits - 1);
        int256 upperUnits = bound(int256(tickUpperSeed), lowerUnits + 1, maxUnits);

        hook.setTickRange(int24(lowerUnits * spacing), int24(upperUnits * spacing));
    }

    /// @dev Mints `shares` for a random actor. Requires the range to be set.
    function addReHypothecatedLiquidity(uint256 actorSeed, uint256 sharesSeed)
        external
        recordCall("addReHypothecatedLiquidity")
    {
        vm.assume(isTickRangeSet());

        address actor = _actorFromSeed(actorSeed);
        vm.assume(actor != address(0));

        uint256 shares = bound(sharesSeed, MINT_SHARES_MIN_BOUND, MINT_SHARES_MAX_BOUND);

        (uint256[] memory amount0sBefore, uint256[] memory amount1sBefore) = _redeemableSnapshot();

        vm.prank(actor);
        BalanceDelta delta = hook.addReHypothecatedLiquidity(shares);

        (uint256[] memory amount0sAfter, uint256[] memory amount1sAfter) = _redeemableSnapshot();

        _INV_M01_assertMintTakesAssets(delta);
        _INV_E01_assertNonDecreasingRedeemableAmounts(
            actor, amount0sBefore, amount1sBefore, amount0sAfter, amount1sAfter
        );
    }

    /// @dev Redeems `shares` of a random actor's own balance. No-op if the actor holds none.
    function removeReHypothecatedLiquidity(uint256 actorSeed, uint256 sharesSeed)
        external
        recordCall("removeReHypothecatedLiquidity")
    {
        address actor = _actorFromSeed(actorSeed);
        vm.assume(actor != address(0));

        uint256 balance = hook.balanceOf(actor);
        vm.assume(balance > 0);
        uint256 shares = bound(sharesSeed, 1, balance);

        (uint256[] memory amount0sBefore, uint256[] memory amount1sBefore) = _redeemableSnapshot();

        vm.prank(actor);
        hook.removeReHypothecatedLiquidity(shares);

        (uint256[] memory amount0sAfter, uint256[] memory amount1sAfter) = _redeemableSnapshot();

        _INV_E01_assertNonDecreasingRedeemableAmounts(
            actor, amount0sBefore, amount1sBefore, amount0sAfter, amount1sAfter
        );
    }

    /// @dev Adds liquidity directly to the pool, bypassing the hook.
    /// `saturateMode` bias towards hook boundary tick; otherwise random.
    function addLiquidity(uint256 actorSeed, uint256 modeSeed, int24 tickSeed, int24 widthSeed, uint256 amountSeed)
        external
        recordCall("addLiquidity")
    {
        vm.assume(isTickRangeSet());

        address actor = _actorFromSeed(actorSeed);
        vm.assume(actor != address(0));

        int24 tickLower;
        int24 tickUpper;
        uint128 liquidityToAdd;

        bool saturateMode = modeSeed % ADD_LIQUIDITY_BOUNDARY_TARGET_DIVISOR == 0;
        if (saturateMode) {
            ghost_addLiquiditySaturation++;
            (tickLower, tickUpper) = _saturationTickRange((modeSeed / ADD_LIQUIDITY_BOUNDARY_TARGET_DIVISOR) % 2 == 0);
            liquidityToAdd = _saturationLiquidityDelta(tickLower, tickUpper);
        } else {
            (tickLower, tickUpper) = _randomTickRange(tickSeed, widthSeed);
            liquidityToAdd = _boundedLiquidityDelta(tickLower, tickUpper, amountSeed);
        }
        vm.assume(liquidityToAdd > 0);

        (uint256[] memory amount0sBefore, uint256[] memory amount1sBefore) = _redeemableSnapshot();

        vm.prank(actor);
        try modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidityToAdd)),
                salt: bytes32(uint256(uint160(actor)))
            }),
            ""
        ) returns (
            BalanceDelta
        ) {
            ghost_addLiquiditySuccess++;
        } catch {}

        (uint256[] memory amount0sAfter, uint256[] memory amount1sAfter) = _redeemableSnapshot();

        _INV_E01_assertNonDecreasingRedeemableAmounts(
            address(0), amount0sBefore, amount1sBefore, amount0sAfter, amount1sAfter
        );
    }

    /// @dev Requires the pool or the hook to have liquidity; otherwise a swap can legitimately
    /// fail for reasons unrelated to INV-J-03.
    function swap(uint256 actorSeed, bool zeroForOne, uint256 amountSeed) external recordCall("swap") {
        vm.assume(manager.getLiquidity(poolId) > 0 || hook.totalSupply() > 0);

        address actor = _actorFromSeed(actorSeed);
        vm.assume(actor != address(0));

        uint256 amount = bound(amountSeed, SWAP_AMOUNT_MIN_BOUND, SWAP_AMOUNT_MAX_BOUND);

        vm.prank(actor);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta
        ) {}
        catch (bytes memory reason) {
            _INV_J03_assertSwapDidNotOverflowBoundaryTick(reason);
        }
    }

    // ------------------ UTILS ------------------ //

    /// @dev True once `setTickRange` has run.
    function isTickRangeSet() public view returns (bool) {
        return hook.getTickLower() != 0 || hook.getTickUpper() != 0;
    }

    /// @dev The narrowest range that can saturate a hook boundary tick: one end pinned to it
    /// (`getTickUpper()` if `upper`, else `getTickLower()`), the other one spacing inward.
    function _saturationTickRange(bool upper) private view returns (int24 tickLower, int24 tickUpper) {
        int24 spacing = key.tickSpacing;
        int24 boundaryTick = upper ? hook.getTickUpper() : hook.getTickLower();
        int24 innerTick = upper ? boundaryTick - spacing : boundaryTick + spacing;
        return upper ? (innerTick, boundaryTick) : (boundaryTick, innerTick);
    }

    /// @dev A random, spacing-aligned range (same bounding pattern as `setTickRange`).
    function _randomTickRange(int24 tickSeed, int24 widthSeed) private view returns (int24, int24) {
        int24 spacing = key.tickSpacing;
        int256 minUnits = TickMath.minUsableTick(spacing) / spacing;
        int256 maxUnits = TickMath.maxUsableTick(spacing) / spacing;
        int256 lowerUnits = bound(int256(tickSeed), minUnits, maxUnits - 1);
        int256 upperUnits = bound(int256(widthSeed), lowerUnits + 1, maxUnits);
        return (int24(lowerUnits * spacing), int24(upperUnits * spacing));
    }

    /// @dev Remaining liquidity `[tickLower, tickUpper]` can absorb without a `TickLiquidityOverflow`
    function _saturationLiquidityDelta(int24 tickLower, int24 tickUpper) private view returns (uint128) {
        uint128 cap = _maxLiquidityPerTick(key.tickSpacing);
        (uint128 grossLower,) = manager.getTickLiquidity(poolId, tickLower);
        (uint128 grossUpper,) = manager.getTickLiquidity(poolId, tickUpper);

        uint128 headroomLower = grossLower < cap ? cap - grossLower : 0;
        uint128 headroomUpper = grossUpper < cap ? cap - grossUpper : 0;
        return headroomLower < headroomUpper ? headroomLower : headroomUpper;
    }

    /// @dev A random liquidity amount within `[tickLower, tickUpper]`'s headroom. 0 if none left.
    function _boundedLiquidityDelta(int24 tickLower, int24 tickUpper, uint256 amountSeed)
        private
        view
        returns (uint128)
    {
        uint128 headroom = _saturationLiquidityDelta(tickLower, tickUpper);
        if (headroom == 0) return 0;
        return uint128(bound(amountSeed, 1, headroom));
    }

    /// @dev Per-tick liquidityGross cap Uniswap v4 enforces: type(uint128).max split evenly
    /// across every valid, spacing-aligned tick, so no tick's aggregate liquidity can overflow.
    function _maxLiquidityPerTick(int24 tickSpacing) private pure returns (uint128) {
        int24 minT = TickMath.MIN_TICK / tickSpacing;
        if (TickMath.MIN_TICK % tickSpacing != 0) minT -= 1;
        int24 maxT = TickMath.MAX_TICK / tickSpacing;
        uint256 numTicks = uint256(int256(maxT - minT)) + 1;
        return uint128(type(uint128).max / numTicks);
    }

    /// @dev Each registered actor's currently redeemable amounts, indexed like `actors()`.
    function _redeemableSnapshot() private view returns (uint256[] memory amount0s, uint256[] memory amount1s) {
        address[] memory actorsList = actors();
        amount0s = new uint256[](actorsList.length);
        amount1s = new uint256[](actorsList.length);
        for (uint256 i; i < actorsList.length; ++i) {
            (amount0s[i], amount1s[i]) = hook.previewRedeem(hook.balanceOf(actorsList[i]));
        }
    }

    /// @dev True if `selector` appears anywhere in `reason`, including inside a wrapped error.
    function _reasonIncludesSelector(bytes memory reason, bytes4 selector) private pure returns (bool) {
        for (uint256 i; i + 4 <= reason.length; ++i) {
            if (
                reason[i] == selector[0] && reason[i + 1] == selector[1] && reason[i + 2] == selector[2]
                    && reason[i + 3] == selector[3]
            ) {
                return true;
            }
        }
        return false;
    }

    // ------------------ STATE TRANSITION INVARIANTS ------------------ //

    /// @dev INV-M-01: a mint must take a positive amount of at least one currency.
    function _INV_M01_assertMintTakesAssets(BalanceDelta delta) private pure {
        assertFalse(delta.amount0() == 0 && delta.amount1() == 0, "INV-M-01: mint took no assets from the caller");
    }

    /// @dev INV-E-01: a mint or redeem by `actor` must not decrease any other holder's redeemable
    /// amount. All four arrays are indexed like `actors()`.
    function _INV_E01_assertNonDecreasingRedeemableAmounts(
        address actor,
        uint256[] memory amount0sBefore,
        uint256[] memory amount1sBefore,
        uint256[] memory amount0sAfter,
        uint256[] memory amount1sAfter
    ) private view {
        address[] memory actorsList = actors();
        for (uint256 i; i < actorsList.length; ++i) {
            if (actorsList[i] == actor) continue;

            assertGe(amount0sAfter[i], amount0sBefore[i], "INV-E-01: mint/redeem decreased another holder's currency0");
            assertGe(amount1sAfter[i], amount1sBefore[i], "INV-E-01: mint/redeem decreased another holder's currency1");
        }
    }

    /// @dev INV-J-03: a swap must not fail from the hook's JIT add overflowing a boundary tick.
    function _INV_J03_assertSwapDidNotOverflowBoundaryTick(bytes memory reason) private pure {
        assertFalse(
            _reasonIncludesSelector(reason, bytes4(keccak256("TickLiquidityOverflow(int24)"))),
            "INV-J-03: swap reverted because the hook's JIT add overflowed a boundary tick"
        );
    }
}
