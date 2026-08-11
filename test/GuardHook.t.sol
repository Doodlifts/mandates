// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {GuardHook, ISqrtPriceOracle} from "../src/GuardHook.sol";
import {Guarded} from "../src/base/Guarded.sol";

contract MockSqrtOracle is ISqrtPriceOracle {
    uint160 public price;

    function set(uint160 _price) external {
        price = _price;
    }

    function sqrtPriceX96(PoolId) external view returns (uint160) {
        return price;
    }
}

contract GuardHookTest is Test, Deployers {
    GuardHook guard;
    MockSqrtOracle oracle;

    address guardian = makeAddr("guardian");
    address rando = makeAddr("rando");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr =
            address(uint160((0x5555 << 20)) | uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("GuardHook.sol:GuardHook", abi.encode(manager), hookAddr);
        guard = GuardHook(hookAddr);

        (key,) = initPool(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);

        // Moderate liquidity so a large swap can move price out of band.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: 1_000e18,
                salt: 0
            }),
            ZERO_BYTES
        );

        oracle = new MockSqrtOracle();
        oracle.set(SQRT_PRICE_1_1); // oracle agrees with pool at start

        vm.prank(guardian);
        guard.setGuard(key, oracle, 100); // 100 bps sqrt-price band
    }

    function _swap(int256 amountSpecified) internal {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_SwapWithinBandPasses() public {
        _swap(-0.1e18); // tiny vs 1000e18 liquidity — well within 1% band
    }

    function test_PreCondition_RevertsWhenPoolAlreadyOffMarket() public {
        // Oracle says the real price moved 5% — the pool is stale/manipulated.
        oracle.set(uint160(uint256(SQRT_PRICE_1_1) * 105 / 100));
        vm.expectRevert();
        _swap(-0.1e18);
    }

    function test_PostCondition_RevertsWholeSwapOnExcessImpact() public {
        // A swap large enough to push the pool >1% (sqrt) off the oracle.
        // The POST-condition catches it and the entire swap unwinds.
        vm.expectRevert();
        _swap(-50e18);

        // Pool state untouched — the failed post-condition left no trace.
        _swap(-0.1e18); // still passes, price unmoved
    }

    function test_Breaker_BlocksAllSwaps() public {
        vm.prank(guardian);
        guard.setBreaker(key, true);
        vm.expectRevert();
        _swap(-0.1e18);

        vm.prank(guardian);
        guard.setBreaker(key, false);
        _swap(-0.1e18); // flows again
    }

    function test_RevertWhen_NonGuardianTripsBreaker() public {
        vm.prank(rando);
        vm.expectRevert(Guarded.NotGuardian.selector);
        guard.setBreaker(key, true);
    }

    function test_RevertWhen_GuardAlreadySet() public {
        vm.prank(rando);
        vm.expectRevert(Guarded.AlreadyGuarded.selector);
        guard.setGuard(key, oracle, 50);
    }

    function test_UnguardedPoolPassesThrough() public {
        // A second pool on the same hook with no guard config: unrestricted.
        (PoolKey memory key2,) = initPool(currency0, currency1, IHooks(address(guard)), 500, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key2,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887270,
                tickUpper: 887270,
                liquidityDelta: 1_000e18,
                salt: 0
            }),
            ZERO_BYTES
        );
        swapRouter.swap(
            key2,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -50e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }
}
