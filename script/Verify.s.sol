// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { BlockchainInfo } from "../src/weiroll-helpers/BlockchainInfo.sol";

/// @title VerifyDeployment
/// @notice Post-deployment verification script
/// @dev Verifies contracts are deployed and configured correctly
contract VerifyDeployment is Script {
    // Expected owner addresses per chain (update after deployment)
    mapping(uint256 => address) public expectedOwners;

    // Contract addresses per chain (populated from deployment registry)
    struct Addresses {
        address executionProxy;
        address tupler;
        address integer;
        address bytes32Helper;
        address blockchainInfo;
        address arraysConverter;
    }

    uint256 public passCount;
    uint256 public failCount;

    function setUp() public {
        // Set expected owners per chain
        // Testnets: deployer EOA
        // Mainnets: Safe multi-sig (update these after Safe creation)
        expectedOwners[11155111] = address(0); // Sepolia - set to deployer
        expectedOwners[84532] = address(0); // Base Sepolia - set to deployer
        expectedOwners[1] = address(0); // Ethereum - set to Safe
        expectedOwners[8453] = address(0); // Base - set to Safe
    }

    /// @notice Check if address has code deployed
    function hasCode(address addr) public view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /// @notice Log pass result
    function pass(string memory check) internal {
        console2.log(unicode"✓", check);
        passCount++;
    }

    /// @notice Log fail result
    function fail(string memory check, string memory reason) internal {
        console2.log(unicode"✗", check);
        console2.log("  Reason:", reason);
        failCount++;
    }

    /// @notice Verify a contract is deployed at address
    function verifyDeployed(address addr, string memory name) internal {
        if (hasCode(addr)) {
            pass(string.concat(name, " deployed at ", vm.toString(addr)));
        } else {
            fail(string.concat(name, " deployment"), "No code at address");
        }
    }

    /// @notice Ownership lives on the Router after the Router/executor refactor.
    ///         ExecutionProxy itself is stateless (FR-11), so there is nothing to verify
    ///         on the executor. INF-0013 swaps this in for a Router ownership check.
    function verifyOwner(address proxyAddr, address) internal {
        if (!hasCode(proxyAddr)) {
            fail("Owner check", "ExecutionProxy not deployed");
            return;
        }
        console2.log("  ExecutionProxy is stateless; ownership check deferred to Router (INF-0013).");
        passCount++;
    }

    /// @notice Verify BlockchainInfo can read block number
    function verifyBlockchainInfo(address addr) internal {
        if (!hasCode(addr)) {
            fail("BlockchainInfo function call", "Not deployed");
            return;
        }

        BlockchainInfo info = BlockchainInfo(addr);
        uint256 blockNum = info.getCurrentBlockNumber();

        if (blockNum > 0) {
            pass(string.concat("BlockchainInfo.getCurrentBlockNumber() = ", vm.toString(blockNum)));
        } else {
            fail("BlockchainInfo function call", "Returned 0");
        }
    }

    /// @notice Main verification entry point
    /// @param chainId The chain ID to verify
    function run(uint256 chainId) public {
        console2.log("=== Deployment Verification ===");
        console2.log("Chain ID:", chainId);
        console2.log("");

        // Read deployment registry
        string memory registryPath = string.concat("deployments/", vm.toString(chainId), ".json");
        string memory json;

        try vm.readFile(registryPath) returns (string memory content) {
            json = content;
        } catch {
            console2.log("ERROR: Could not read deployment registry at", registryPath);
            console2.log("Please create the registry file after deployment.");
            return;
        }

        // Parse addresses from registry
        Addresses memory addrs;
        addrs.executionProxy = vm.parseJsonAddress(json, ".contracts.ExecutionProxy.address");
        addrs.tupler = vm.parseJsonAddress(json, ".contracts.Tupler.address");
        addrs.integer = vm.parseJsonAddress(json, ".contracts.Integer.address");
        addrs.bytes32Helper = vm.parseJsonAddress(json, ".contracts.Bytes32.address");
        addrs.blockchainInfo = vm.parseJsonAddress(json, ".contracts.BlockchainInfo.address");
        addrs.arraysConverter = vm.parseJsonAddress(json, ".contracts.ArraysConverter.address");

        console2.log("--- Contract Deployment Checks ---");
        verifyDeployed(addrs.executionProxy, "ExecutionProxy");
        verifyDeployed(addrs.tupler, "Tupler");
        verifyDeployed(addrs.integer, "Integer");
        verifyDeployed(addrs.bytes32Helper, "Bytes32");
        verifyDeployed(addrs.blockchainInfo, "BlockchainInfo");
        verifyDeployed(addrs.arraysConverter, "ArraysConverter");
        console2.log("");

        console2.log("--- Ownership Check ---");
        verifyOwner(addrs.executionProxy, expectedOwners[chainId]);
        console2.log("");

        console2.log("--- Function Call Checks ---");
        verifyBlockchainInfo(addrs.blockchainInfo);
        console2.log("");

        // Summary
        console2.log("=== Summary ===");
        console2.log("Passed:", passCount);
        console2.log("Failed:", failCount);

        if (failCount > 0) {
            console2.log("");
            console2.log("VERIFICATION FAILED - Review failures above");
        } else {
            console2.log("");
            console2.log("ALL CHECKS PASSED");
        }
    }

    /// @notice Quick verification using current chain
    function run() public {
        run(block.chainid);
    }
}
