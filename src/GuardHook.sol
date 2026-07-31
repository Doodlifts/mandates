// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Reference price feed for a pool, in sqrtPriceX96 terms.
/// In production this adapts Chainlink/TWAP; tests use a settable mock.
interface ISqrtPriceOracle {
    function sqrtPriceX96(PoolId poolId) external view returns (uint160);
}

/// @title GuardHook — declarative pre/post conditions for pools
///
/// @notice Cadence transactions carry `pre { }` and `post { }` blocks:
/// assertions the runtime enforces around arbitrary execution, so a
/// transaction cannot complete outside its stated envelope. This hook gives
/// a v4 pool the same shape, fail-closed:
///
///  - PRE (beforeSwap):  the pool price must be within `maxDeviationBps`
///    of the reference oracle — swaps against an already-manipulated pool
///    are refused — and the guardian's circuit breaker must not be tripped.
///  - POST (afterSwap):  the pool price must STILL be within the band —
///    any single swap that would push the pool off-market reverts whole,
///    leaving the pool untouched. This bounds per-swap price impact and
///    doubles as MEV/manipulation protection for mandated flow.
///
/// Deviation is measured in bps of sqrt-price (≈ half the bps of price for
/// small moves) — document limits accordingly.
contract GuardHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error NotPoolManager();
    error HookNotImplemented();
    error NotGuardian();
    error AlreadyGuarded();
    error BreakerTripped();
    error PriceDeviatedBefore(uint160 poolSqrtPrice, uint160 oracleSqrtPrice);
    error PriceDeviatedAfter(uint160 poolSqrtPrice, uint160 oracleSqrtPrice);
    error InvalidConfig();

    event GuardSet(PoolId indexed poolId, address indexed guardian, address oracle, uint16 maxDeviationBps);
    event BreakerSet(PoolId indexed poolId, bool tripped);

    struct GuardConfig {
        address guardian; // may trip/reset the breaker and update the oracle
        ISqrtPriceOracle oracle;
        uint16 maxDeviationBps; // sqrt-price deviation tolerance, 1 bp = 0.01%
        bool tripped;
    }

    IPoolManager public immutable poolManager;
    mapping(PoolId => GuardConfig) public guards;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ------------------------------------------------------------------
    // Guard administration
    // ------------------------------------------------------------------
    function setGuard(PoolKey calldata key, ISqrtPriceOracle oracle, uint16 maxDeviationBps) external {
        if (address(oracle) == address(0) || maxDeviationBps == 0) revert InvalidConfig();
        PoolId poolId = key.toId();
        if (guards[poolId].guardian != address(0)) revert AlreadyGuarded();
        guards[poolId] =
            GuardConfig({guardian: msg.sender, oracle: oracle, maxDeviationBps: maxDeviationBps, tripped: false});
        emit GuardSet(poolId, msg.sender, address(oracle), maxDeviationBps);
    }

    function setBreaker(PoolKey calldata key, bool tripped) external {
        PoolId poolId = key.toId();
        GuardConfig storage g = guards[poolId];
        if (g.guardian != msg.sender) revert NotGuardian();
        g.tripped = tripped;
        emit BreakerSet(poolId, tripped);
    }

    // ------------------------------------------------------------------
    // Pre-condition
    // ------------------------------------------------------------------
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        GuardConfig storage g = guards[poolId];

        if (g.guardian != address(0)) {
            if (g.tripped) revert BreakerTripped();

            (uint160 poolSqrtPrice,,,) = poolManager.getSlot0(poolId);
            uint160 oracleSqrtPrice = g.oracle.sqrtPriceX96(poolId);
            if (_deviationBps(poolSqrtPrice, oracleSqrtPrice) > g.maxDeviationBps) {
                revert PriceDeviatedBefore(poolSqrtPrice, oracleSqrtPrice);
            }
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ------------------------------------------------------------------
    // Post-condition
    // ------------------------------------------------------------------
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        GuardConfig storage g = guards[poolId];

        if (g.guardian != address(0)) {
            (uint160 poolSqrtPrice,,,) = poolManager.getSlot0(poolId);
            uint160 oracleSqrtPrice = g.oracle.sqrtPriceX96(poolId);
            if (_deviationBps(poolSqrtPrice, oracleSqrtPrice) > g.maxDeviationBps) {
                // Reverting here unwinds the ENTIRE swap — the post-condition
                // failed, so the state change never happens.
                revert PriceDeviatedAfter(poolSqrtPrice, oracleSqrtPrice);
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    function _deviationBps(uint160 a, uint160 b) internal pure returns (uint256) {
        uint256 diff = a > b ? uint256(a) - uint256(b) : uint256(b) - uint256(a);
        return diff * 10_000 / uint256(b);
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
