// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice A scheduled job. Implementations MUST be safe to call by anyone
/// at-or-after the due time; the hook caps gas and treats reverts as fail-open.
interface IChronoJob {
    function chronoExec(uint256 jobId, bytes calldata data) external;
}

/// @title ChronoHook — swap traffic as a clock
///
/// @notice Flow has protocol-level Scheduled Transactions: validators execute
/// your handler at a future time, no keeper subscription, no trusted relay.
/// Ethereum has nothing native — so this hook recreates the *guarantee shape*
/// with the resource a busy AMM has in abundance: other people's transactions.
///
/// Jobs are queued with an ETH bounty per run. Every swap on a chrono-enabled
/// pool sweeps a bounded window of the job ring in afterSwap; due jobs are
/// executed (gas-capped, fail-open — a broken job can never block a swap) and
/// the bounty pays the transaction origin, refunding the swapper for carrying
/// the work. A busy pool becomes a fine-grained heartbeat. When traffic is
/// quiet, `poke()` lets anyone execute a due job for the same bounty — a
/// permissionless keeper of last resort, so liveness never depends on volume.
contract ChronoHook is IHooks {
    error NotPoolManager();
    error HookNotImplemented();
    error BadSchedule();
    error NotJobOwner();
    error JobNotActive();
    error JobNotDue();
    error InsufficientBounty();

    event JobScheduled(
        uint256 indexed jobId,
        address indexed owner,
        address target,
        uint64 executeAfter,
        uint32 interval,
        uint32 runsRemaining,
        uint96 bountyPerRun
    );
    event JobExecuted(uint256 indexed jobId, address indexed rewardee, bool success);
    event JobCancelled(uint256 indexed jobId, uint256 refund);

    struct Job {
        address owner;
        IChronoJob target;
        uint64 executeAfter; // due timestamp
        uint32 interval; // 0 = one-shot; else reschedule +interval after run
        uint32 runsRemaining; // decremented per run; 0 deactivates
        uint96 bountyPerRun; // ETH paid to whoever's tx carried the work
        bool active;
        bytes data;
    }

    /// Gas forwarded to a job. A job that needs more must split its work.
    uint256 public constant JOB_GAS_CAP = 400_000;
    /// Jobs inspected per swap — bounds the overhead any swap can bear.
    uint256 public constant JOBS_PER_SWAP = 2;

    IPoolManager public immutable poolManager;

    uint256 public nextJobId = 1;
    mapping(uint256 => Job) public jobs;
    uint256[] public ring; // active job ids, swept round-robin
    uint256 public cursor;
    /// Bounties that failed to pay out are pull-claimable, never lost.
    mapping(address => uint256) public owed;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ------------------------------------------------------------------
    // Scheduling
    // ------------------------------------------------------------------
    function schedule(
        IChronoJob target,
        bytes calldata data,
        uint64 executeAfter,
        uint32 interval,
        uint32 runs,
        uint96 bountyPerRun
    ) external payable returns (uint256 jobId) {
        if (address(target) == address(0) || runs == 0) revert BadSchedule();
        if (msg.value < uint256(bountyPerRun) * runs) revert InsufficientBounty();

        jobId = nextJobId++;
        jobs[jobId] = Job({
            owner: msg.sender,
            target: target,
            executeAfter: executeAfter,
            interval: interval,
            runsRemaining: runs,
            bountyPerRun: bountyPerRun,
            active: true,
            data: data
        });
        ring.push(jobId);

        emit JobScheduled(jobId, msg.sender, address(target), executeAfter, interval, runs, bountyPerRun);
    }

    function cancel(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (j.owner != msg.sender) revert NotJobOwner();
        if (!j.active) revert JobNotActive();
        j.active = false;
        uint256 refund = uint256(j.bountyPerRun) * j.runsRemaining;
        j.runsRemaining = 0;
        emit JobCancelled(jobId, refund);
        _pay(msg.sender, refund);
    }

    /// Quiet-market fallback: anyone may run a due job for its bounty.
    function poke(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (!j.active) revert JobNotActive();
        if (block.timestamp < j.executeAfter) revert JobNotDue();
        _run(jobId, j, msg.sender);
    }

    function ringLength() external view returns (uint256) {
        return ring.length;
    }

    // ------------------------------------------------------------------
    // The clock: every swap sweeps a window of the ring
    // ------------------------------------------------------------------
    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        uint256 len = ring.length;
        if (len == 0) return (IHooks.afterSwap.selector, 0);

        uint256 inspect = len < JOBS_PER_SWAP ? len : JOBS_PER_SWAP;
        uint256 c = cursor;
        for (uint256 i = 0; i < inspect; i++) {
            uint256 jobId = ring[c % len];
            c++;
            Job storage j = jobs[jobId];
            if (j.active && block.timestamp >= j.executeAfter) {
                // tx.origin: the bounty belongs to the account whose swap
                // carried the work, not the router in the middle. Prototype
                // tradeoff, documented — origin-less designs (paying `sender`)
                // just rebate routers instead.
                _run(jobId, j, tx.origin);
            }
        }
        cursor = c % len;

        return (IHooks.afterSwap.selector, 0);
    }

    function _run(uint256 jobId, Job storage j, address rewardee) internal {
        // Effects first; a job cannot re-trigger itself.
        j.runsRemaining--;
        if (j.interval > 0 && j.runsRemaining > 0) {
            j.executeAfter = uint64(block.timestamp) + j.interval;
        } else {
            j.active = false;
        }

        // Fail-open: a reverting job never blocks the swap that carried it.
        bool success;
        try j.target.chronoExec{gas: JOB_GAS_CAP}(jobId, j.data) {
            success = true;
        } catch {}

        emit JobExecuted(jobId, rewardee, success);
        _pay(rewardee, j.bountyPerRun);
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: 30_000}("");
        if (!ok) owed[to] += amount; // pull-claimable, never lost
    }

    function claimOwed() external {
        uint256 amount = owed[msg.sender];
        owed[msg.sender] = 0;
        _pay(msg.sender, amount);
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    // Pass-through / unused callbacks
    // ------------------------------------------------------------------
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented(); // beforeSwap flag is off for this hook
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
