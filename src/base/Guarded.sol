// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Reference price feed for a pool, in sqrtPriceX96 terms.
interface ISqrtPriceOracle {
    function sqrtPriceX96(PoolId poolId) external view returns (uint160);
}

/// @title Guarded — reusable pre/post price-band conditions for pools
///
/// @notice The guard logic extracted so any hook can compose it (v4 allows
/// exactly one hook per pool, so composition happens by inheritance, not by
/// stacking hooks). See GuardHook for the standalone version and
/// MandateGuardHook for guards + mandate enforcement on one address.
abstract contract Guarded {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error NotGuardian();
    error AlreadyGuarded();
    error BreakerTripped();
    error PriceDeviatedBefore(uint160 poolSqrtPrice, uint160 oracleSqrtPrice);
    error PriceDeviatedAfter(uint160 poolSqrtPrice, uint160 oracleSqrtPrice);
    error InvalidConfig();

    event GuardSet(PoolId indexed poolId, address indexed guardian, address oracle, uint16 maxDeviationBps);
    event BreakerSet(PoolId indexed poolId, bool tripped);

    struct GuardConfig {
        address guardian; // may trip/reset the breaker
        ISqrtPriceOracle oracle;
        uint16 maxDeviationBps; // sqrt-price deviation tolerance, 1 bp = 0.01%
        bool tripped;
    }

    mapping(PoolId => GuardConfig) public guards;

    /// Implementing hooks supply their PoolManager reference.
    function _manager() internal view virtual returns (IPoolManager);

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
    // Conditions (call from beforeSwap / afterSwap)
    // ------------------------------------------------------------------
    /// PRE: breaker not tripped; the pool isn't already off-market.
    function _checkPre(PoolId poolId) internal view {
        GuardConfig storage g = guards[poolId];
        if (g.guardian == address(0)) return; // unguarded pool
        if (g.tripped) revert BreakerTripped();

        (uint160 poolSqrtPrice,,,) = _manager().getSlot0(poolId);
        uint160 oracleSqrtPrice = g.oracle.sqrtPriceX96(poolId);
        if (_deviationBps(poolSqrtPrice, oracleSqrtPrice) > g.maxDeviationBps) {
            revert PriceDeviatedBefore(poolSqrtPrice, oracleSqrtPrice);
        }
    }

    /// POST: the swap left the pool within the band — else the revert
    /// unwinds the ENTIRE swap, and the state change never happens.
    function _checkPost(PoolId poolId) internal view {
        GuardConfig storage g = guards[poolId];
        if (g.guardian == address(0)) return;

        (uint160 poolSqrtPrice,,,) = _manager().getSlot0(poolId);
        uint160 oracleSqrtPrice = g.oracle.sqrtPriceX96(poolId);
        if (_deviationBps(poolSqrtPrice, oracleSqrtPrice) > g.maxDeviationBps) {
            revert PriceDeviatedAfter(poolSqrtPrice, oracleSqrtPrice);
        }
    }

    function _deviationBps(uint160 a, uint160 b) internal pure returns (uint256) {
        uint256 diff = a > b ? uint256(a) - uint256(b) : uint256(b) - uint256(a);
        return diff * 10_000 / uint256(b);
    }
}
