// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Vendored from Uniswap/v4-periphery (test/shared/HookMiner.sol), MIT.
// Kept local so the project depends on v4-core only.

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookMiner — find CREATE2 salts producing flag-valid hook addresses
library HookMiner {
    uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK; // bottom 14 bits

    /// Bounded search; ~160k candidates is ample for 2-3 flag bits.
    uint256 constant MAX_LOOP = 160_444;

    /// @param deployer In `forge script` broadcasts, the CREATE2 deployer
    /// proxy 0x4e59b44847b379578588920cA78FbF26c0B4956C; in tests, the
    /// pranking/deploying address.
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address, bytes32)
    {
        flags = flags & FLAG_MASK;
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);

        address hookAddress;
        for (uint256 salt; salt < MAX_LOOP; salt++) {
            hookAddress = computeAddress(deployer, salt, creationCodeWithArgs);
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(salt));
            }
        }
        revert("HookMiner: could not find salt");
    }

    function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)))))
        );
    }
}
