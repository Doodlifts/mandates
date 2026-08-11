// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {MandateBook} from "../src/MandateBook.sol";
import {MandateGuardHook} from "../src/MandateGuardHook.sol";
import {ChronoHook} from "../src/ChronoHook.sol";
import {ChainlinkSqrtPriceOracle} from "../src/oracle/ChainlinkSqrtPriceOracle.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// Deploys the Mandates stack:
///   MandateBook -> MandateGuardHook (mined, beforeSwap|afterSwap)
///   ChronoHook (mined, afterSwap) -> ChainlinkSqrtPriceOracle
///
/// Env:
///   POOL_MANAGER — canonical v4 PoolManager for the target chain.
///                  Unset = deploy a fresh one (local/dev chains only!).
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url $RPC --private-key $PK --broadcast
///
/// Hook addresses must encode their permission flags in the low 14 bits, so
/// both hooks are deployed via the deterministic CREATE2 deployer proxy with
/// mined salts (forge routes `new C{salt: ...}` through it when broadcasting).
contract Deploy is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address managerAddr = vm.envOr("POOL_MANAGER", address(0));

        vm.startBroadcast();

        if (managerAddr == address(0)) {
            managerAddr = address(new PoolManager(msg.sender));
            console2.log("PoolManager (FRESH - dev only):", managerAddr);
        }
        IPoolManager manager = IPoolManager(managerAddr);

        MandateBook book = new MandateBook(manager);

        // --- MandateGuardHook at a flag-valid address ---
        uint160 mgFlags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        (address mgAddr, bytes32 mgSalt) = HookMiner.find(
            CREATE2_DEPLOYER, mgFlags, type(MandateGuardHook).creationCode, abi.encode(managerAddr, address(book))
        );
        MandateGuardHook mandateGuardHook = new MandateGuardHook{salt: mgSalt}(manager, book);
        require(address(mandateGuardHook) == mgAddr, "MandateGuardHook: mined address mismatch");
        book.setHook(address(mandateGuardHook));

        // --- ChronoHook at a flag-valid address ---
        (address chronoAddr, bytes32 chronoSalt) = HookMiner.find(
            CREATE2_DEPLOYER, uint160(Hooks.AFTER_SWAP_FLAG), type(ChronoHook).creationCode, abi.encode(managerAddr)
        );
        ChronoHook chronoHook = new ChronoHook{salt: chronoSalt}(manager);
        require(address(chronoHook) == chronoAddr, "ChronoHook: mined address mismatch");

        ChainlinkSqrtPriceOracle oracle = new ChainlinkSqrtPriceOracle();

        vm.stopBroadcast();

        console2.log("MandateBook:        ", address(book));
        console2.log("MandateGuardHook:   ", address(mandateGuardHook));
        console2.log("ChronoHook:         ", address(chronoHook));
        console2.log("ChainlinkOracle:    ", address(oracle));
        console2.log("Next: setFeed + setGuard per pool, initialize pools with the hook.");
    }
}
