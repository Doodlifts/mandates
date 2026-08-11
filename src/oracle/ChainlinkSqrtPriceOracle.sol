// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ISqrtPriceOracle} from "../base/Guarded.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @title ChainlinkSqrtPriceOracle — AggregatorV3 feeds as pool reference prices
///
/// @notice Adapts a Chainlink feed to the sqrtPriceX96 terms Guarded compares
/// against. Per pool, configure the feed, both token decimals, whether the
/// feed quotes token0-per-token1 (`invert`), and a staleness bound.
///
/// Math: v4 pool price P = token1_raw / token0_raw. With a feed quoting
/// token1-per-token0 at `feedDecimals`:
///   P = answer * 10^d1 / (10^feedDecimals * 10^d0)
/// We form X192 = P << 192 with a full-precision mulDiv, then
/// sqrtPriceX96 = floor(sqrt(X192)).
///
/// Range: X192 must fit uint256, i.e. raw-unit price < 2^64 (~1.8e19).
/// Holds for sane pairs; extreme-decimals exotica should use a TWAP adapter.
contract ChainlinkSqrtPriceOracle is ISqrtPriceOracle {
    error FeedAlreadySet();
    error FeedNotSet();
    error InvalidFeed();
    error StalePrice(uint256 updatedAt);
    error NegativeOrZeroAnswer();

    event FeedSet(
        PoolId indexed poolId, address indexed feed, uint8 token0Decimals, uint8 token1Decimals, bool invert
    );

    struct FeedConfig {
        AggregatorV3Interface feed;
        uint8 feedDecimals; // cached at configuration
        uint8 token0Decimals;
        uint8 token1Decimals;
        bool invert; // feed quotes token0-per-token1 instead of token1-per-token0
        uint32 maxStaleness; // seconds; 0 = no staleness check
    }

    mapping(PoolId => FeedConfig) public feeds;

    /// First-setter configuration, mirroring Guarded.setGuard. In production
    /// the guardian who sets the pool's guard should also set its feed.
    function setFeed(
        PoolId poolId,
        AggregatorV3Interface feed,
        uint8 token0Decimals,
        uint8 token1Decimals,
        bool invert,
        uint32 maxStaleness
    ) external {
        if (address(feed) == address(0)) revert InvalidFeed();
        if (address(feeds[poolId].feed) != address(0)) revert FeedAlreadySet();
        feeds[poolId] = FeedConfig({
            feed: feed,
            feedDecimals: feed.decimals(),
            token0Decimals: token0Decimals,
            token1Decimals: token1Decimals,
            invert: invert,
            maxStaleness: maxStaleness
        });
        emit FeedSet(poolId, address(feed), token0Decimals, token1Decimals, invert);
    }

    function sqrtPriceX96(PoolId poolId) external view returns (uint160) {
        FeedConfig storage c = feeds[poolId];
        if (address(c.feed) == address(0)) revert FeedNotSet();

        (, int256 answer,, uint256 updatedAt,) = c.feed.latestRoundData();
        if (answer <= 0) revert NegativeOrZeroAnswer();
        if (c.maxStaleness != 0 && block.timestamp - updatedAt > c.maxStaleness) {
            revert StalePrice(updatedAt);
        }

        // P = N / D in raw token units.
        uint256 n;
        uint256 d;
        if (!c.invert) {
            n = uint256(answer) * (10 ** c.token1Decimals);
            d = (10 ** c.feedDecimals) * (10 ** c.token0Decimals);
        } else {
            n = (10 ** c.feedDecimals) * (10 ** c.token1Decimals);
            d = uint256(answer) * (10 ** c.token0Decimals);
        }

        // X192 = (N/D) << 192, full precision; requires N/D < 2^64.
        uint256 x192 = FullMath.mulDiv(n, 1 << 192, d);
        return uint160(_sqrt(x192));
    }

    /// Babylonian square root, floor.
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
