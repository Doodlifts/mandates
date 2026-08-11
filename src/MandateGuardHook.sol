// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {Guarded} from "./base/Guarded.sol";
import {MandateBook} from "./MandateBook.sol";

/// @title MandateGuardHook — mandates + guards on a single hook address
///
/// @notice v4 allows exactly one hook per pool, so the two enforcement
/// layers compose by inheritance rather than stacking:
///
///  - every swap (mandated or not) passes the Guarded pre/post price-band
///    conditions and the circuit breaker;
///  - swaps carrying mandate hookData are additionally re-validated and
///    budget-debited against the MandateBook, and must originate from it.
///
/// The result for an owner reads like a Cadence transaction: "this executor
/// may spend 100 USDC/day here until June — and no execution, theirs or
/// anyone's, may move this pool more than 1% off the reference price."
///
/// This is the canonical production hook; MandateHook and GuardHook remain
/// as the single-purpose variants.
contract MandateGuardHook is IHooks, Guarded {
    using PoolIdLibrary for PoolKey;

    error NotPoolManager();
    error NotMandateBook();
    error HookNotImplemented();

    IPoolManager public immutable poolManager;
    MandateBook public immutable book;

    constructor(IPoolManager _poolManager, MandateBook _book) {
        poolManager = _poolManager;
        book = _book;
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        // PRE-conditions apply to ALL traffic on the pool.
        _checkPre(poolId);

        // Mandate enforcement applies to mandate-carrying swaps only.
        if (hookData.length != 0) {
            if (sender != address(book)) revert NotMandateBook();
            (uint256 mandateId, address executor) = abi.decode(hookData, (uint256, address));
            book.enforceAndDebit(mandateId, executor, poolId, params.zeroForOne, params.amountSpecified);
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, int128) {
        // POST-condition: nobody's swap may leave the pool off-market.
        _checkPost(key.toId());
        return (IHooks.afterSwap.selector, 0);
    }

    // ------------------------------------------------------------------
    // Unused hook callbacks (flags are off; never invoked)
    // ------------------------------------------------------------------
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
