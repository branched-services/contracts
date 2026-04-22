// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";

contract DeployScript is Script {
    function run() public {
        uint256 chainId = block.chainid;

        vm.startBroadcast();

        // ExecutionProxy is now a stateless pure-VM executor (no constructor args).
        // Router deployment and Router<->executor wiring are handled in INF-0013.
        ExecutionProxy proxy = new ExecutionProxy();
        console2.log("ExecutionProxy deployed at:", address(proxy));
        console2.log("Chain ID:", chainId);

        vm.stopBroadcast();
    }
}
