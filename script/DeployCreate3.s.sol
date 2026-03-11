// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { Tupler } from "../src/weiroll-helpers/Tupler.sol";
import { Integer } from "../src/weiroll-helpers/Integer.sol";
import { Bytes32 } from "../src/weiroll-helpers/Bytes32.sol";
import { BlockchainInfo } from "../src/weiroll-helpers/BlockchainInfo.sol";
import { ArraysConverter } from "../src/weiroll-helpers/ArraysConverter.sol";

/// @notice Interface for ZeframLou's CREATE3 Factory
/// @dev Deployed at 0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf on all supported chains
interface ICREATE3Factory {
    /// @notice Deploys a contract using CREATE3
    /// @param salt The deployer-specific salt for determining the deployed contract's address
    /// @param creationCode The creation code of the contract to deploy
    /// @return deployed The address of the deployed contract
    function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address deployed);

    /// @notice Predicts the address of a deployed contract
    /// @param deployer The deployer account that will call deploy()
    /// @param salt The deployer-specific salt for determining the deployed contract's address
    /// @return deployed The address of the contract that will be deployed
    function getDeployed(address deployer, bytes32 salt) external view returns (address deployed);
}

/// @title DeployCreate3
/// @notice Idempotent deployment script using CREATE3 for deterministic addresses
/// @dev Uses ZeframLou's CREATE3 factory for consistent addresses across chains
contract DeployCreate3 is Script {
    // CREATE3 Factory - same address on all supported chains
    address public constant CREATE3_FACTORY = 0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf;

    // Default salt version (can be overridden via SALT_VERSION env var)
    string public constant DEFAULT_SALT_VERSION = "v1";

    // Contract names for salt generation
    string public constant EXECUTION_PROXY = "ExecutionProxy";
    string public constant TUPLER = "Tupler";
    string public constant INTEGER = "Integer";
    string public constant BYTES32 = "Bytes32";
    string public constant BLOCKCHAIN_INFO = "BlockchainInfo";
    string public constant ARRAYS_CONVERTER = "ArraysConverter";

    // Deployment results
    struct DeploymentResult {
        address executionProxy;
        address tupler;
        address integer;
        address bytes32Helper;
        address blockchainInfo;
        address arraysConverter;
        bool[] deployed; // true if newly deployed, false if already existed
    }

    /// @notice Gets the salt version from env var or returns default
    /// @return The salt version string (e.g., "v1", "v2")
    function getSaltVersion() public view returns (string memory) {
        try vm.envString("SALT_VERSION") returns (string memory version) {
            return version;
        } catch {
            return DEFAULT_SALT_VERSION;
        }
    }

    /// @notice Gets the owner address from env var or returns msg.sender
    /// @return The owner address for ExecutionProxy
    function getOwnerAddress() public view returns (address) {
        try vm.envAddress("OWNER_ADDRESS") returns (address owner) {
            return owner;
        } catch {
            return msg.sender;
        }
    }

    /// @notice Generates a deterministic salt for a contract
    /// @param contractName The name of the contract
    /// @return The salt to use for CREATE3 deployment
    function getSalt(string memory contractName) public view returns (bytes32) {
        string memory version = getSaltVersion();
        string memory prefix = string.concat("infrared.contracts.", version);
        return keccak256(abi.encodePacked(prefix, contractName));
    }

    /// @notice Predicts the deployment address for a contract
    /// @param deployer The deployer address
    /// @param contractName The name of the contract
    /// @return The predicted deployment address
    function predictAddress(address deployer, string memory contractName) public view returns (address) {
        bytes32 salt = getSalt(contractName);
        return ICREATE3Factory(CREATE3_FACTORY).getDeployed(deployer, salt);
    }

    /// @notice Checks if a contract is already deployed at an address
    /// @param addr The address to check
    /// @return True if code exists at the address
    function isDeployed(address addr) public view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /// @notice Deploys a contract using CREATE3 if not already deployed
    /// @param salt The salt for deployment
    /// @param creationCode The creation code
    /// @param contractName The name for logging
    /// @return deployed The deployed address
    /// @return wasDeployed True if newly deployed
    function deployIfNeeded(bytes32 salt, bytes memory creationCode, string memory contractName)
        internal
        returns (address deployed, bool wasDeployed)
    {
        deployed = ICREATE3Factory(CREATE3_FACTORY).getDeployed(msg.sender, salt);

        if (isDeployed(deployed)) {
            console2.log(string.concat(contractName, " already deployed at:"), deployed);
            return (deployed, false);
        }

        deployed = ICREATE3Factory(CREATE3_FACTORY).deploy(salt, creationCode);
        console2.log(string.concat(contractName, " deployed at:"), deployed);
        return (deployed, true);
    }

    /// @notice Main deployment function
    function run() public returns (DeploymentResult memory result) {
        // Verify CREATE3 factory exists
        require(isDeployed(CREATE3_FACTORY), "CREATE3 factory not found at expected address");

        uint256 chainId = block.chainid;
        address deployer = msg.sender;
        address owner = getOwnerAddress();
        string memory saltVersion = getSaltVersion();

        console2.log("Deploying contracts...");
        console2.log("Chain ID:", chainId);
        console2.log("Deployer:", deployer);
        console2.log("Owner:", owner);
        if (owner != deployer) {
            console2.log("  (ownership will be transferred to Safe)");
        }
        console2.log("Salt version:", saltVersion);
        console2.log("CREATE3 Factory:", CREATE3_FACTORY);
        console2.log("");

        result.deployed = new bool[](6);

        vm.startBroadcast();

        // Deploy ExecutionProxy (has constructor arg: owner)
        // If already deployed and owner differs, we'll transfer ownership after
        address predictedProxy = ICREATE3Factory(CREATE3_FACTORY).getDeployed(deployer, getSalt(EXECUTION_PROXY));
        bool proxyAlreadyDeployed = isDeployed(predictedProxy);

        bytes memory executionProxyCode = abi.encodePacked(type(ExecutionProxy).creationCode, abi.encode(owner));
        (result.executionProxy, result.deployed[0]) =
            deployIfNeeded(getSalt(EXECUTION_PROXY), executionProxyCode, EXECUTION_PROXY);

        // If proxy was already deployed and current owner is not target owner, transfer ownership
        if (proxyAlreadyDeployed && owner != deployer) {
            ExecutionProxy proxy = ExecutionProxy(payable(result.executionProxy));
            address currentOwner = proxy.owner();
            if (currentOwner == deployer) {
                console2.log("Transferring ExecutionProxy ownership to:", owner);
                proxy.transferOwnership(owner);
                console2.log("Ownership transferred successfully");
            } else if (currentOwner == owner) {
                console2.log("ExecutionProxy already owned by target:", owner);
            } else {
                console2.log("Warning: ExecutionProxy owned by different address:", currentOwner);
            }
        }

        // Deploy stateless helpers (no constructor args)
        (result.tupler, result.deployed[1]) = deployIfNeeded(getSalt(TUPLER), type(Tupler).creationCode, TUPLER);

        (result.integer, result.deployed[2]) = deployIfNeeded(getSalt(INTEGER), type(Integer).creationCode, INTEGER);

        (result.bytes32Helper, result.deployed[3]) =
            deployIfNeeded(getSalt(BYTES32), type(Bytes32).creationCode, BYTES32);

        (result.blockchainInfo, result.deployed[4]) =
            deployIfNeeded(getSalt(BLOCKCHAIN_INFO), type(BlockchainInfo).creationCode, BLOCKCHAIN_INFO);

        (result.arraysConverter, result.deployed[5]) =
            deployIfNeeded(getSalt(ARRAYS_CONVERTER), type(ArraysConverter).creationCode, ARRAYS_CONVERTER);

        vm.stopBroadcast();

        // Summary
        console2.log("");
        console2.log("=== Deployment Summary ===");
        uint256 newlyDeployed = 0;
        for (uint256 i = 0; i < 6; i++) {
            if (result.deployed[i]) newlyDeployed++;
        }
        console2.log("Newly deployed:", newlyDeployed);
        console2.log("Already deployed:", 6 - newlyDeployed);
        console2.log("Final owner:", owner);

        return result;
    }

    /// @notice Preview deployment addresses without deploying
    function preview() public view {
        address deployer = msg.sender;
        address owner = getOwnerAddress();
        string memory saltVersion = getSaltVersion();

        console2.log("=== Predicted Addresses ===");
        console2.log("Deployer:", deployer);
        console2.log("Target owner:", owner);
        if (owner != deployer) {
            console2.log("  (ownership will be transferred to Safe)");
        }
        console2.log("Salt version:", saltVersion);
        console2.log("CREATE3 Factory:", CREATE3_FACTORY, isDeployed(CREATE3_FACTORY) ? "(deployed)" : "(NOT DEPLOYED)");
        console2.log("");

        address execProxy = predictAddress(deployer, EXECUTION_PROXY);
        console2.log("ExecutionProxy:", execProxy, isDeployed(execProxy) ? "(deployed)" : "(not deployed)");

        address tupler = predictAddress(deployer, TUPLER);
        console2.log("Tupler:", tupler, isDeployed(tupler) ? "(deployed)" : "(not deployed)");

        address integer = predictAddress(deployer, INTEGER);
        console2.log("Integer:", integer, isDeployed(integer) ? "(deployed)" : "(not deployed)");

        address bytes32Helper = predictAddress(deployer, BYTES32);
        console2.log("Bytes32:", bytes32Helper, isDeployed(bytes32Helper) ? "(deployed)" : "(not deployed)");

        address blockchainInfo = predictAddress(deployer, BLOCKCHAIN_INFO);
        console2.log("BlockchainInfo:", blockchainInfo, isDeployed(blockchainInfo) ? "(deployed)" : "(not deployed)");

        address arraysConverter = predictAddress(deployer, ARRAYS_CONVERTER);
        console2.log("ArraysConverter:", arraysConverter, isDeployed(arraysConverter) ? "(deployed)" : "(not deployed)");
    }
}
