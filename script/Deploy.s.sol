// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";

contract DeployScript is Script {
    function run() public {
        uint256 chainId = block.chainid;

        vm.startBroadcast();

        // msg.sender becomes the owner
        ExecutionProxy proxy = new ExecutionProxy(msg.sender);
        console2.log("ExecutionProxy deployed at:", address(proxy));
        console2.log("Owner:", msg.sender);
        console2.log("Chain ID:", chainId);

        vm.stopBroadcast();
    }
}
