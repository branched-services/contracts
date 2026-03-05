// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ExecutionProxy } from "../../src/ExecutionProxy.sol";
import { ITransferCallback } from "./AdversarialTokens.sol";

/// @title ReentrantReceiver
/// @notice Contract that attempts to re-enter ExecutionProxy on ETH receive
/// @dev Used to test that ReentrancyGuard properly blocks re-entry attacks
contract ReentrantReceiver is ITransferCallback {
    ExecutionProxy public target;
    bool public attackEnabled;
    bool public attackViaExecute; // true = execute(), false = executeSingle()
    uint256 public attackCount;
    uint256 public maxAttacks = 1;

    // Storage for attack parameters
    bytes32[] public attackCommands;
    bytes[] public attackState;
    ExecutionProxy.OutputSpec[] public attackOutputs;
    address public attackOutputToken;
    uint256 public attackMinAmount;
    address public attackReceiver;

    // Track if attack was attempted
    bool public attackAttempted;
    bool public attackSucceeded;

    constructor(address _target) {
        target = ExecutionProxy(payable(_target));
    }

    /// @notice Configure for execute() re-entry attack
    function setupExecuteAttack(
        bytes32[] calldata commands,
        bytes[] calldata state,
        ExecutionProxy.OutputSpec[] calldata outputs,
        address receiver
    ) external {
        delete attackCommands;
        delete attackState;
        delete attackOutputs;

        for (uint256 i = 0; i < commands.length; i++) {
            attackCommands.push(commands[i]);
        }
        for (uint256 i = 0; i < state.length; i++) {
            attackState.push(state[i]);
        }
        for (uint256 i = 0; i < outputs.length; i++) {
            attackOutputs.push(outputs[i]);
        }
        attackReceiver = receiver;
        attackViaExecute = true;
        attackEnabled = true;
    }

    /// @notice Configure for executeSingle() re-entry attack
    function setupExecuteSingleAttack(
        bytes32[] calldata commands,
        bytes[] calldata state,
        address outputToken,
        uint256 minAmount,
        address receiver
    ) external {
        delete attackCommands;
        delete attackState;

        for (uint256 i = 0; i < commands.length; i++) {
            attackCommands.push(commands[i]);
        }
        for (uint256 i = 0; i < state.length; i++) {
            attackState.push(state[i]);
        }
        attackOutputToken = outputToken;
        attackMinAmount = minAmount;
        attackReceiver = receiver;
        attackViaExecute = false;
        attackEnabled = true;
    }

    /// @notice Disable the attack
    function disableAttack() external {
        attackEnabled = false;
    }

    /// @notice Set maximum number of re-entry attempts
    function setMaxAttacks(uint256 _maxAttacks) external {
        maxAttacks = _maxAttacks;
    }

    /// @notice Reset attack state
    function resetAttackState() external {
        attackAttempted = false;
        attackSucceeded = false;
        attackCount = 0;
    }

    /// @notice Called when ETH is received - attempts re-entry if enabled
    receive() external payable {
        if (attackEnabled && attackCount < maxAttacks) {
            attackCount++;
            attackAttempted = true;

            // Attempt re-entry
            try this._executeAttack() {
                attackSucceeded = true;
            } catch {
                // Attack was blocked (expected behavior)
                attackSucceeded = false;
            }
        }
    }

    /// @notice External function to execute attack (allows try/catch)
    function _executeAttack() external {
        require(msg.sender == address(this), "Only self");

        if (attackViaExecute) {
            target.execute(attackCommands, attackState, attackOutputs, attackReceiver);
        } else {
            target.executeSingle(attackCommands, attackState, attackOutputToken, attackMinAmount, attackReceiver);
        }
    }

    /// @notice Implement ITransferCallback for token callback re-entry tests
    function onTokenTransfer(address, address, uint256) external override {
        if (attackEnabled && attackCount < maxAttacks) {
            attackCount++;
            attackAttempted = true;

            // Attempt re-entry via token callback
            try this._executeAttack() {
                attackSucceeded = true;
            } catch {
                attackSucceeded = false;
            }
        }
    }
}

/// @title ETHRejectingReceiver
/// @notice Contract that rejects ETH transfers
/// @dev Used to test ETHTransferFailed error handling
contract ETHRejectingReceiver {
    bool public rejectETH = true;

    function setRejectETH(bool _reject) external {
        rejectETH = _reject;
    }

    receive() external payable {
        if (rejectETH) {
            revert("ETHRejectingReceiver: rejecting ETH");
        }
    }

    fallback() external payable {
        if (rejectETH) {
            revert("ETHRejectingReceiver: rejecting ETH");
        }
    }
}
