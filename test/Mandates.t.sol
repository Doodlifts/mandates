// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {MandateBook} from "../src/MandateBook.sol";
import {MandateHook} from "../src/MandateHook.sol";

contract MandatesTest is Test, Deployers {
    MandateBook book;
    MandateHook hook;

    address executor = makeAddr("executor");
    address attacker = makeAddr("attacker");
    address subAgent = makeAddr("subAgent");

    uint128 constant BUDGET = 100e18;
    uint32 constant EPOCH = 1 days;

    uint256 mandateId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        book = new MandateBook(manager);

        // Hook address must carry exactly the beforeSwap|afterSwap flags.
        address hookAddr =
            address(uint160((0x4444 << 20)) | uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("MandateHook.sol:MandateHook", abi.encode(manager, book), hookAddr);
        hook = MandateHook(hookAddr);
        book.setHook(hookAddr);

        (key,) = initPool(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);

        // Deep full-range liquidity so mandate-sized swaps fill fully.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: 10_000e18,
                salt: 0
            }),
            ZERO_BYTES
        );

        // Owner (this test contract) funds the vault with both tokens.
        MockERC20(Currency.unwrap(currency0)).approve(address(book), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(book), type(uint256).max);
        book.deposit(currency0, 1_000e18);
        book.deposit(currency1, 1_000e18);

        mandateId = book.createMandate(
            key,
            executor,
            BUDGET,
            EPOCH,
            uint40(block.timestamp),
            uint40(block.timestamp + 30 days),
            MandateBook.Direction.OnlyZeroForOne
        );
    }

    // ------------------------------------------------------------------
    // Happy paths
    // ------------------------------------------------------------------

    function test_NormalSwapsPassThrough() public {
        // Unrelated traffic on the pool is untouched by mandate enforcement.
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_ExecutorSwapsWithinBudget() public {
        uint256 c0Before = book.vaultBalance(address(this), currency0);

        vm.prank(executor);
        uint256 amountOut = book.execute(mandateId, true, 50e18, 1);

        assertGt(amountOut, 49e18); // deep liquidity, ~0.3% fee
        assertEq(book.vaultBalance(address(this), currency0), c0Before - 50e18);
        assertEq(book.vaultBalance(address(this), currency1), 1_000e18 + amountOut);
        assertEq(book.spentInEpoch(mandateId, 0), 50e18);
        assertEq(book.remainingBudget(mandateId), BUDGET - 50e18);
    }

    function test_BudgetResetsNextEpoch() public {
        vm.startPrank(executor);
        book.execute(mandateId, true, uint256(BUDGET), 1); // exhaust epoch 0
        assertEq(book.remainingBudget(mandateId), 0);

        vm.warp(block.timestamp + EPOCH + 1);
        book.execute(mandateId, true, 50e18, 1); // fresh epoch budget
        vm.stopPrank();

        assertEq(book.spentInEpoch(mandateId, 1), 50e18);
    }

    function test_CapabilityTransferDelegates() public {
        // The 6909 token IS the capability — handing it over delegates.
        vm.prank(executor);
        book.transfer(subAgent, mandateId, 1);

        vm.prank(subAgent);
        book.execute(mandateId, true, 10e18, 1);

        vm.prank(executor);
        vm.expectRevert(MandateBook.NotCapabilityHolder.selector);
        book.execute(mandateId, true, 10e18, 1);
    }

    function test_OwnerCanAlwaysWithdraw() public {
        vm.prank(executor);
        book.execute(mandateId, true, 50e18, 1);

        uint256 remaining = book.vaultBalance(address(this), currency0);
        uint256 walletBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        book.withdraw(currency0, remaining);
        assertEq(
            MockERC20(Currency.unwrap(currency0)).balanceOf(address(this)), walletBefore + remaining
        );
    }

    // ------------------------------------------------------------------
    // Compromised / overreaching executor
    // ------------------------------------------------------------------

    function test_RevertWhen_BudgetExceeded() public {
        vm.startPrank(executor);
        book.execute(mandateId, true, uint256(BUDGET), 1);
        vm.expectRevert(); // MandateBook.BudgetExceeded, wrapped by hook-call bubbling
        book.execute(mandateId, true, 1e18, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_SingleSwapOverBudget() public {
        vm.prank(executor);
        vm.expectRevert();
        book.execute(mandateId, true, uint256(BUDGET) + 1, 0);
    }

    function test_RevertWhen_WrongDirection() public {
        // Mandate allows selling token0 only; buying back is forbidden.
        vm.prank(executor);
        vm.expectRevert();
        book.execute(mandateId, false, 10e18, 0);
    }

    function test_RevertWhen_Revoked() public {
        book.revoke(mandateId); // owner pulls the capability — instantly
        vm.prank(executor);
        vm.expectRevert();
        book.execute(mandateId, true, 10e18, 0);
    }

    function test_RevertWhen_Expired() public {
        vm.warp(block.timestamp + 31 days);
        vm.prank(executor);
        vm.expectRevert();
        book.execute(mandateId, true, 10e18, 0);
    }

    function test_RevertWhen_NotCapabilityHolder() public {
        vm.prank(attacker);
        vm.expectRevert(MandateBook.NotCapabilityHolder.selector);
        book.execute(mandateId, true, 10e18, 0);
    }

    function test_RevertWhen_ExecutorTriesToWithdraw() public {
        vm.prank(executor);
        vm.expectRevert(MandateBook.InsufficientVaultBalance.selector);
        book.withdraw(currency0, 1);
    }

    function test_RevertWhen_OnlyOwnerCanRevoke() public {
        vm.prank(executor);
        vm.expectRevert(MandateBook.NotOwner.selector);
        book.revoke(mandateId);
    }

    function test_RevertWhen_ForgedHookDataViaExternalRouter() public {
        // An attacker (or even the legit executor) routing through a
        // third-party router with mandate hookData is rejected at the venue:
        // mandate flows must originate from the MandateBook itself.
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

    function test_RevertWhen_DirectEnforceCall() public {
        // Only the hook — from inside the pool's execution — may debit budgets.
        vm.prank(attacker);
        vm.expectRevert(MandateBook.NotHook.selector);
        book.enforceAndDebit(mandateId, executor, key.toId(), true, -1e18);
    }

    function test_RevertWhen_HookRewired() public {
        vm.prank(attacker);
        vm.expectRevert(MandateBook.HookAlreadySet.selector);
        book.setHook(attacker);
    }

    function test_RevertWhen_MandatePoolLacksHook() public {
        // A mandate can only be created on a pool guarded by the hook.
        (PoolKey memory bareKey,) = initPool(currency0, currency1, IHooks(address(0)), 500, SQRT_PRICE_1_1);
        vm.expectRevert(MandateBook.InvalidPolicy.selector);
        book.createMandate(
            bareKey,
            executor,
            BUDGET,
            EPOCH,
            uint40(block.timestamp),
            uint40(block.timestamp + 30 days),
            MandateBook.Direction.Both
        );
    }
}
