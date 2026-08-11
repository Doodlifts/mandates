// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {MandateBook} from "../src/MandateBook.sol";
import {MandateGuardHook} from "../src/MandateGuardHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// Stands up a complete demo world on a local anvil chain:
/// PoolManager, MandateBook + mined MandateGuardHook, two demo tokens,
/// a funded 1:1 pool, Alice's vault deposit, and a mandate for Bob:
/// 100 dTOK0 per day, sell-only, 30 days, revocable.
///
/// Run by demo.sh — see TESTING.md.
contract DemoSetup is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    function run() external {
        // anvil account #1 — the "agent" the mandate is issued to
        address bob = vm.envOr("BOB", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));

        vm.startBroadcast();

        PoolManager manager = new PoolManager(msg.sender);
        MandateBook book = new MandateBook(manager);

        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG),
            type(MandateGuardHook).creationCode,
            abi.encode(address(manager), address(book))
        );
        MandateGuardHook hook = new MandateGuardHook{salt: salt}(manager, book);
        require(address(hook) == hookAddr, "mined address mismatch");
        book.setHook(address(hook));

        MockERC20 tokA = new MockERC20("Demo Dollar", "dUSD", 18);
        MockERC20 tokB = new MockERC20("Demo Ether", "dETH", 18);
        (MockERC20 t0, MockERC20 t1) = address(tokA) < address(tokB) ? (tokA, tokB) : (tokB, tokA);
        t0.mint(msg.sender, 1_000_000e18);
        t1.mint(msg.sender, 1_000_000e18);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_1_1);

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        t0.approve(address(lp), type(uint256).max);
        t1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: 10_000e18,
                salt: 0
            }),
            ""
        );

        // Alice's custody: 1000 dTOK0 to trade, a little dTOK1 so the
        // wrong-direction rejection demonstrates the DIRECTION rule
        // (not just an empty balance).
        t0.approve(address(book), type(uint256).max);
        t1.approve(address(book), type(uint256).max);
        book.deposit(Currency.wrap(address(t0)), 1_000e18);
        book.deposit(Currency.wrap(address(t1)), 100e18);

        uint256 mandateId = book.createMandate(
            key,
            bob,
            100e18, // budget: 100 dTOK0
            1 days, // per day
            uint40(block.timestamp),
            uint40(block.timestamp + 30 days),
            MandateBook.Direction.OnlyZeroForOne // sell dTOK0 only
        );

        vm.stopBroadcast();

        // Parsed by demo.sh — keep the KEY=VALUE shape.
        console2.log("BOOK=%s", address(book));
        console2.log("HOOK=%s", address(hook));
        console2.log("TOKEN0=%s", address(t0));
        console2.log("TOKEN1=%s", address(t1));
        console2.log("MANDATE_ID=%s", mandateId);
    }
}
