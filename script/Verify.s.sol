// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { Router } from "../src/Router.sol";
import { BlockchainInfo } from "../src/weiroll-helpers/BlockchainInfo.sol";

/// @title VerifyDeployment
/// @notice Post-deployment verification script. Asserts that Router is wired correctly
///         (owner, executor, liquidator, not paused, no pending executor) and that all
///         helper contracts have code at their expected addresses.
contract VerifyDeployment is Script {
    struct Addresses {
        address router;
        address executionProxy;
        address tupler;
        address integer;
        address bytes32Helper;
        address blockchainInfo;
        address arraysConverter;
    }

    uint256 public passCount;
    uint256 public failCount;

    /// @notice Check if address has code deployed
    function hasCode(address addr) public view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    function pass(string memory check) internal {
        console2.log(unicode"  [PASS]", check);
        passCount++;
    }

    function fail(string memory check, string memory reason) internal {
        console2.log(unicode"  [FAIL]", check);
        console2.log("    Reason:", reason);
        failCount++;
    }

    function verifyDeployed(address addr, string memory name) internal {
        if (hasCode(addr)) {
            pass(string.concat(name, " deployed at ", vm.toString(addr)));
        } else {
            fail(string.concat(name, " deployment"), "No code at address");
        }
    }

    /// @notice Resolve the expected Router owner from env. Required for verification — no fallback.
    function expectedRouterOwner() internal view returns (address) {
        try vm.envAddress("ROUTER_OWNER") returns (address a) {
            return a;
        } catch {
            try vm.envAddress("OWNER_ADDRESS") returns (address a) {
                return a;
            } catch {
                return address(0);
            }
        }
    }

    /// @notice Resolve the expected Router liquidator from env. Optional — if unset, only
    ///         non-zero is asserted.
    function expectedRouterLiquidator() internal view returns (address) {
        try vm.envAddress("ROUTER_LIQUIDATOR") returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    /// @notice Verify the Router is fully wired and ready to serve swaps.
    ///         Asserts: code present; owner == expected; executor == executionProxy;
    ///         liquidator == expected (if env-provided) or non-zero; not paused;
    ///         pendingExecutor cleared (so `acceptExecutor` was called).
    function verifyRouter(address routerAddr, address executionProxyAddr) internal {
        if (!hasCode(routerAddr)) {
            fail("Router code", "No code at Router address");
            return;
        }

        Router router = Router(payable(routerAddr));

        // Owner check (Ownable2Step)
        address expectedOwner = expectedRouterOwner();
        address actualOwner = router.owner();
        if (expectedOwner == address(0)) {
            fail("Router owner", "ROUTER_OWNER env not set; cannot verify");
        } else if (actualOwner == expectedOwner) {
            pass(string.concat("Router.owner() = ", vm.toString(actualOwner)));
        } else {
            fail(
                "Router owner mismatch",
                string.concat("expected ", vm.toString(expectedOwner), " got ", vm.toString(actualOwner))
            );
        }

        // Executor wiring (the whole point of this script post-deploy)
        address actualExecutor = router.executor();
        if (actualExecutor == executionProxyAddr) {
            pass(string.concat("Router.executor() = ExecutionProxy ", vm.toString(actualExecutor)));
        } else {
            fail(
                "Router executor mismatch",
                string.concat("expected ", vm.toString(executionProxyAddr), " got ", vm.toString(actualExecutor))
            );
        }

        // pendingExecutor must be cleared after acceptExecutor()
        address actualPending = router.pendingExecutor();
        if (actualPending == address(0)) {
            pass("Router.pendingExecutor() cleared (acceptExecutor was called)");
        } else {
            fail(
                "Router pendingExecutor not cleared",
                string.concat("acceptExecutor() likely not called; pending=", vm.toString(actualPending))
            );
        }

        // Liquidator
        address expectedLiquidator = expectedRouterLiquidator();
        address actualLiquidator = router.liquidator();
        if (expectedLiquidator != address(0)) {
            if (actualLiquidator == expectedLiquidator) {
                pass(string.concat("Router.liquidator() = ", vm.toString(actualLiquidator)));
            } else {
                fail(
                    "Router liquidator mismatch",
                    string.concat("expected ", vm.toString(expectedLiquidator), " got ", vm.toString(actualLiquidator))
                );
            }
        } else if (actualLiquidator != address(0)) {
            pass(
                string.concat(
                    "Router.liquidator() = ", vm.toString(actualLiquidator), " (env unset, asserting non-zero)"
                )
            );
        } else {
            fail("Router liquidator", "Liquidator is zero and ROUTER_LIQUIDATOR env unset");
        }

        // Not paused on first deploy
        if (!router.paused()) {
            pass("Router.paused() == false");
        } else {
            fail("Router paused state", "Router is paused on first verification");
        }
    }

    /// @notice Verify BlockchainInfo can read block number
    function verifyBlockchainInfo(address addr) internal {
        if (!hasCode(addr)) {
            fail("BlockchainInfo function call", "Not deployed");
            return;
        }
        uint256 blockNum = BlockchainInfo(addr).getCurrentBlockNumber();
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

        Addresses memory addrs;
        addrs.router = vm.parseJsonAddress(json, ".contracts.Router.address");
        addrs.executionProxy = vm.parseJsonAddress(json, ".contracts.ExecutionProxy.address");
        addrs.tupler = vm.parseJsonAddress(json, ".contracts.Tupler.address");
        addrs.integer = vm.parseJsonAddress(json, ".contracts.Integer.address");
        addrs.bytes32Helper = vm.parseJsonAddress(json, ".contracts.Bytes32.address");
        addrs.blockchainInfo = vm.parseJsonAddress(json, ".contracts.BlockchainInfo.address");
        addrs.arraysConverter = vm.parseJsonAddress(json, ".contracts.ArraysConverter.address");

        console2.log("--- Code presence checks ---");
        verifyDeployed(addrs.router, "Router");
        verifyDeployed(addrs.executionProxy, "ExecutionProxy");
        verifyDeployed(addrs.tupler, "Tupler");
        verifyDeployed(addrs.integer, "Integer");
        verifyDeployed(addrs.bytes32Helper, "Bytes32");
        verifyDeployed(addrs.blockchainInfo, "BlockchainInfo");
        verifyDeployed(addrs.arraysConverter, "ArraysConverter");
        console2.log("");

        console2.log("--- Router state checks ---");
        verifyRouter(addrs.router, addrs.executionProxy);
        console2.log("");

        console2.log("--- Helper sanity check ---");
        verifyBlockchainInfo(addrs.blockchainInfo);
        console2.log("");

        console2.log("=== Summary ===");
        console2.log("Passed:", passCount);
        console2.log("Failed:", failCount);

        if (failCount > 0) {
            console2.log("");
            console2.log("VERIFICATION FAILED - review failures above before serving traffic.");
            revert("Verification failed");
        }
        console2.log("");
        console2.log("ALL CHECKS PASSED");
    }

    /// @notice Quick verification using current chain
    function run() public {
        run(block.chainid);
    }
}
