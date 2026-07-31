// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ChronoHook, IChronoJob} from "../src/ChronoHook.sol";

contract MockJob is IChronoJob {
    uint256 public execCount;
    bytes public lastData;
    bool public shouldRevert;

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function chronoExec(uint256, bytes calldata data) external {
        if (shouldRevert) revert("job broken");
        execCount++;
        lastData = data;
    }
}

contract ChronoHookTest is Test, Deployers {
    ChronoHook chrono;
    MockJob job;

    address swapper = makeAddr("swapper");
    address keeper = makeAddr("keeper");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(uint160((0x6666 << 20)) | uint160(Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("ChronoHook.sol:ChronoHook", abi.encode(manager), hookAddr);
        chrono = ChronoHook(payable(hookAddr));

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);

        job = new MockJob();
        vm.deal(address(this), 100 ether);
    }

    function _swap() internal {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_SwapExecutesDueJob() public {
        chrono.schedule{value: 0.01 ether}(
            job, hex"beef", uint64(block.timestamp), 0, 1, 0.01 ether
        );

        uint256 originBefore = tx.origin.balance;
        _swap();

        assertEq(job.execCount(), 1);
        assertEq(job.lastData(), hex"beef");
        // The bounty rebated the transaction origin (the swapper's EOA).
        assertEq(tx.origin.balance, originBefore + 0.01 ether);
    }

    function test_JobNotDueYetIsSkipped() public {
        chrono.schedule{value: 0.01 ether}(
            job, "", uint64(block.timestamp + 1 hours), 0, 1, 0.01 ether
        );

        _swap();
        assertEq(job.execCount(), 0);

        vm.warp(block.timestamp + 1 hours + 1);
        _swap();
        assertEq(job.execCount(), 1);
    }

    function test_RecurringJobReschedules() public {
        chrono.schedule{value: 0.03 ether}(
            job, "", uint64(block.timestamp), 1 hours, 3, 0.01 ether
        );

        _swap();
        assertEq(job.execCount(), 1); // run 1, rescheduled +1h

        _swap();
        assertEq(job.execCount(), 1); // not due again yet

        vm.warp(block.timestamp + 1 hours + 1);
        _swap();
        assertEq(job.execCount(), 2);

        vm.warp(block.timestamp + 1 hours + 1);
        _swap();
        assertEq(job.execCount(), 3);

        // Runs exhausted — inert forever after.
        vm.warp(block.timestamp + 1 hours + 1);
        _swap();
        assertEq(job.execCount(), 3);
    }

    function test_FailingJobNeverBlocksSwap() public {
        chrono.schedule{value: 0.01 ether}(job, "", uint64(block.timestamp), 0, 1, 0.01 ether);
        job.setRevert(true);

        _swap(); // must not revert
        assertEq(job.execCount(), 0);

        // The run was consumed (fail-open, no retry loop).
        (,,,, uint32 runsRemaining,, bool active,) = chrono.jobs(1);
        assertEq(runsRemaining, 0);
        assertFalse(active);
    }

    function test_PokeExecutesWithoutTraffic() public {
        chrono.schedule{value: 0.01 ether}(job, "", uint64(block.timestamp), 0, 1, 0.01 ether);

        vm.prank(keeper);
        chrono.poke(1);

        assertEq(job.execCount(), 1);
        assertEq(keeper.balance, 0.01 ether); // keeper of last resort earns the bounty
    }

    function test_RevertWhen_PokeBeforeDue() public {
        chrono.schedule{value: 0.01 ether}(job, "", uint64(block.timestamp + 1 days), 0, 1, 0.01 ether);
        vm.expectRevert(ChronoHook.JobNotDue.selector);
        chrono.poke(1);
    }

    function test_CancelRefundsRemainingBounty() public {
        chrono.schedule{value: 0.05 ether}(job, "", uint64(block.timestamp), 1 hours, 5, 0.01 ether);

        _swap(); // one run consumed
        assertEq(job.execCount(), 1);

        uint256 before = address(this).balance;
        chrono.cancel(1);
        assertEq(address(this).balance, before + 0.04 ether); // 4 unused runs refunded

        vm.warp(block.timestamp + 2 hours);
        _swap();
        assertEq(job.execCount(), 1); // cancelled — never runs again
    }

    function test_RevertWhen_CancelByNonOwner() public {
        chrono.schedule{value: 0.01 ether}(job, "", uint64(block.timestamp), 0, 1, 0.01 ether);
        vm.prank(keeper);
        vm.expectRevert(ChronoHook.NotJobOwner.selector);
        chrono.cancel(1);
    }

    function test_RevertWhen_UnderfundedSchedule() public {
        vm.expectRevert(ChronoHook.InsufficientBounty.selector);
        chrono.schedule{value: 0.01 ether}(job, "", uint64(block.timestamp), 0, 5, 0.01 ether);
    }
}
