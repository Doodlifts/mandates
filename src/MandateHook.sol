// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {MandateBook} from "./MandateBook.sol";

/// @title MandateHook — venue-side enforcement for mandates
///
/// @notice Attached to pools that accept mandated flow. Ordinary swaps
/// (empty hookData) pass through untouched. Swaps carrying mandate hookData
/// are only accepted when initiated by the MandateBook itself, and the full
/// policy (revocation, expiry, direction, per-epoch budget) is re-validated
/// and debited here — inside the pool's own execution path — so no routing
/// trick can move mandated funds outside the policy envelope.
///
/// This is the Cadence idea transplanted: authority lives with the object
/// (the pool + capability), not the actor (the executor's software).
contract MandateHook is IHooks {
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
        // Swaps with no mandate attached are ordinary traffic — pass through.
        if (hookData.length == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Mandate executions must originate from the book's own unlock.
        // A third-party router forging mandate hookData is rejected here.
        if (sender != address(book)) revert NotMandateBook();

        (uint256 mandateId, address executor) = abi.decode(hookData, (uint256, address));
        book.enforceAndDebit(mandateId, executor, key.toId(), params.zeroForOne, params.amountSpecified);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
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
