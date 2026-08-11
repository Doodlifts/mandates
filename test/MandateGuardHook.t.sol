// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {MandateBook} from "../src/MandateBook.sol";
import {MandateGuardHook} from "../src/MandateGuardHook.sol";
import {MockSqrtOracle} from "./GuardHook.t.sol";

contract MandateGuardHookTest is Test, Deployers {
    MandateBook book;
    MandateGuardHook hook;
    MockSqrtOracle oracle;

    address executor = makeAddr("executor");
    address guardian = makeAddr("guardian");

    uint256 mandateId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        book = new MandateBook(manager);

        address hookAddr =
            address(uint160((0x7777 << 20)) | uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("MandateGuardHook.sol:MandateGuardHook", abi.encode(manager, book), hookAddr);
        hook = MandateGuardHook(hookAddr);
        book.setHook(hookAddr);

        (key,) = initPool(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);

        // Moderate liquidity: mandate-sized swaps fill, huge swaps move price.
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
        oracle.set(SQRT_PRICE_1_1);
        vm.prank(guardian);
        hook.setGuard(key, oracle, 100); // 1% sqrt-price band

        MockERC20(Currency.unwrap(currency0)).approve(address(book), type(uint256).max);
        book.deposit(currency0, 1_000e18);

        mandateId = book.createMandate(
            key,
            executor,
            100e18,
            1 days,
            uint40(block.timestamp),
            uint40(block.timestamp + 30 days),
            MandateBook.Direction.OnlyZeroForOne
        );
    }

    function test_MandateExecutionWithinBandPasses() public {
        vm.prank(executor);
        uint256 amountOut = book.execute(mandateId, true, 1e18, 1);
        assertGt(amountOut, 0);
        assertEq(book.spentInEpoch(mandateId, 0), 1e18);
    }

    function test_MandateExecutionBlockedWhenPoolOffMarket() public {
        // The pre-condition protects the OWNER's mandate from executing
        // against a manipulated pool — even though the mandate itself is valid.
        oracle.set(uint160(uint256(SQRT_PRICE_1_1) * 105 / 100));
        vm.prank(executor);
        vm.expectRevert();
        book.execute(mandateId, true, 1e18, 0);
    }

    function test_MandateExecutionBlockedByPostCondition() public {
        // A budget-legal swap whose IMPACT would break the band still fails:
        // the guard post-condition unwinds it whole.
        vm.prank(executor);
        vm.expectRevert();
        book.execute(mandateId, true, 50e18, 0);

        // Nothing happened: budget undebited, vault untouched.
        assertEq(book.spentInEpoch(mandateId, 0), 0);
        assertEq(book.vaultBalance(address(this), currency0), 1_000e18);
    }

    function test_BreakerBlocksMandateExecution() public {
        vm.prank(guardian);
        hook.setBreaker(key, true);
        vm.prank(executor);
        vm.expectRevert();
        book.execute(mandateId, true, 1e18, 0);
    }

    function test_OrdinaryTrafficStillGuarded() public {
        // Non-mandate swaps share the same pre/post envelope.
        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -50e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_ForgedHookDataStillRejected() public {
        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(mandateId, executor)
        );
    }

    function test_BudgetStillEnforced() public {
        vm.startPrank(executor);
        book.execute(mandateId, true, 1e18, 1);
        vm.expectRevert();
        book.execute(mandateId, true, 100e18, 0); // over remaining budget
        vm.stopPrank();
    }
}
