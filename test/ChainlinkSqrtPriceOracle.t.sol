// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {
    ChainlinkSqrtPriceOracle,
    AggregatorV3Interface
} from "../src/oracle/ChainlinkSqrtPriceOracle.sol";

contract MockAggregator {
    int256 public answer;
    uint8 public decimals;
    uint256 public updatedAt;

    constructor(int256 _answer, uint8 _decimals) {
        answer = _answer;
        decimals = _decimals;
        updatedAt = block.timestamp;
    }

    function set(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract ChainlinkSqrtPriceOracleTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96

    ChainlinkSqrtPriceOracle oracle;
    PoolId poolId = PoolId.wrap(bytes32(uint256(1)));

    function setUp() public {
        oracle = new ChainlinkSqrtPriceOracle();
    }

    function _feed(int256 answer, uint8 dec) internal returns (AggregatorV3Interface) {
        return AggregatorV3Interface(address(new MockAggregator(answer, dec)));
    }

    function test_ParityPrice_SameDecimals() public {
        // price 1.0, 18/18 decimals -> sqrtPriceX96 == 2^96 exactly
        oracle.setFeed(poolId, _feed(1e8, 8), 18, 18, false, 0);
        assertEq(oracle.sqrtPriceX96(poolId), SQRT_PRICE_1_1);
    }

    function test_Price4_SameDecimals() public {
        // price 4.0 -> sqrt = 2 * 2^96
        oracle.setFeed(poolId, _feed(4e8, 8), 18, 18, false, 0);
        assertEq(oracle.sqrtPriceX96(poolId), 2 * uint256(SQRT_PRICE_1_1));
    }

    function test_InvertedFeed() public {
        // feed quotes token0-per-token1 at 4.0 -> pool price 0.25 -> sqrt = 2^96 / 2
        oracle.setFeed(poolId, _feed(4e8, 8), 18, 18, true, 0);
        assertEq(oracle.sqrtPriceX96(poolId), uint256(SQRT_PRICE_1_1) / 2);
    }

    function test_DecimalScaling_UsdcWeth() public {
        // token0 = USDC (6), token1 = WETH (18), feed: 1 USDC = 0.0004 WETH
        // raw price = 0.0004 * 10^(18-6) = 4e8 -> sqrt = 2e4 * 2^96
        oracle.setFeed(poolId, _feed(0.0004e8, 8), 6, 18, false, 0);
        assertApproxEqRel(uint256(oracle.sqrtPriceX96(poolId)), 2e4 * uint256(SQRT_PRICE_1_1), 1e12);
    }

    function test_RevertWhen_Stale() public {
        MockAggregator agg = new MockAggregator(1e8, 8);
        oracle.setFeed(poolId, AggregatorV3Interface(address(agg)), 18, 18, false, 3600);

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSqrtPriceOracle.StalePrice.selector, agg.updatedAt()));
        oracle.sqrtPriceX96(poolId);
    }

    function test_RevertWhen_BadAnswer() public {
        MockAggregator agg = new MockAggregator(0, 8);
        oracle.setFeed(poolId, AggregatorV3Interface(address(agg)), 18, 18, false, 0);
        vm.expectRevert(ChainlinkSqrtPriceOracle.NegativeOrZeroAnswer.selector);
        oracle.sqrtPriceX96(poolId);
    }

    function test_RevertWhen_FeedResetAttempt() public {
        AggregatorV3Interface first = _feed(1e8, 8);
        AggregatorV3Interface second = _feed(2e8, 8);
        oracle.setFeed(poolId, first, 18, 18, false, 0);
        vm.expectRevert(ChainlinkSqrtPriceOracle.FeedAlreadySet.selector);
        oracle.setFeed(poolId, second, 18, 18, false, 0);
    }

    function test_RevertWhen_NoFeed() public {
        vm.expectRevert(ChainlinkSqrtPriceOracle.FeedNotSet.selector);
        oracle.sqrtPriceX96(PoolId.wrap(bytes32(uint256(999))));
    }
}
