// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { VM } from "@weiroll/VM.sol";

/**
 * @title ExecutionProxy
 * @notice Proxy contract for executing Weiroll programs with output verification
 * @dev Receives Weiroll programs from the Infrared Engine, executes them atomically,
 *      verifies output amounts meet slippage requirements, and transfers outputs to receiver
 */
contract ExecutionProxy is VM, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Specification for expected output tokens and minimum amounts
    struct OutputSpec {
        address token;
        uint256 minAmount;
    }

    /// @notice Emitted when a swap execution completes successfully
    event Executed(address indexed sender, address indexed receiver, uint256 outputCount, uint256[] actualAmounts);

    /// @notice Error thrown when output amount is below minimum
    error SlippageExceeded(address token, uint256 actual, uint256 minimum);

    /// @notice Error thrown when ETH transfer fails
    error ETHTransferFailed();

    /// @notice Error thrown when output array is empty
    error NoOutputsSpecified();

    /// @notice Native ETH sentinel address
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    constructor(address _owner) Ownable(_owner) { }

    /**
     * @notice Execute a Weiroll program with multi-output verification
     * @param commands The Weiroll command sequence
     * @param state The initial state array for Weiroll execution
     * @param outputs Array of output specifications (token + minimum amount)
     * @param receiver Address to receive the output tokens
     * @return actualAmounts Array of actual amounts transferred for each output
     */
    function execute(
        bytes32[] calldata commands,
        bytes[] calldata state,
        OutputSpec[] calldata outputs,
        address receiver
    ) external payable nonReentrant returns (uint256[] memory actualAmounts) {
        if (outputs.length == 0) {
            revert NoOutputsSpecified();
        }

        // 1. Execute the Weiroll program
        _execute(commands, state);

        // 2. Verify all outputs and transfer to receiver
        actualAmounts = new uint256[](outputs.length);

        for (uint256 i = 0; i < outputs.length; i++) {
            address token = outputs[i].token;
            uint256 minAmount = outputs[i].minAmount;

            // Get balance of this contract for the output token
            uint256 balance;
            if (token == NATIVE_ETH) {
                balance = address(this).balance;
            } else {
                balance = IERC20(token).balanceOf(address(this));
            }

            // Verify slippage
            if (balance < minAmount) {
                revert SlippageExceeded(token, balance, minAmount);
            }

            actualAmounts[i] = balance;

            // Transfer to receiver
            if (token == NATIVE_ETH) {
                (bool success,) = receiver.call{ value: balance }("");
                if (!success) {
                    revert ETHTransferFailed();
                }
            } else {
                IERC20(token).safeTransfer(receiver, balance);
            }
        }

        emit Executed(msg.sender, receiver, outputs.length, actualAmounts);
    }

    /**
     * @notice Execute a Weiroll program with a single output verification (gas optimized)
     * @param commands The Weiroll command sequence
     * @param state The initial state array for Weiroll execution
     * @param outputToken The expected output token address
     * @param minAmountOut Minimum acceptable output amount
     * @param receiver Address to receive the output token
     * @return actualAmount The actual amount transferred
     */
    function executeSingle(
        bytes32[] calldata commands,
        bytes[] calldata state,
        address outputToken,
        uint256 minAmountOut,
        address receiver
    ) external payable nonReentrant returns (uint256 actualAmount) {
        // 1. Execute the Weiroll program
        _execute(commands, state);

        // 2. Verify output and transfer
        if (outputToken == NATIVE_ETH) {
            actualAmount = address(this).balance;
            if (actualAmount < minAmountOut) {
                revert SlippageExceeded(outputToken, actualAmount, minAmountOut);
            }
            (bool success,) = receiver.call{ value: actualAmount }("");
            if (!success) {
                revert ETHTransferFailed();
            }
        } else {
            actualAmount = IERC20(outputToken).balanceOf(address(this));
            if (actualAmount < minAmountOut) {
                revert SlippageExceeded(outputToken, actualAmount, minAmountOut);
            }
            IERC20(outputToken).safeTransfer(receiver, actualAmount);
        }

        // Emit with single output
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = actualAmount;
        emit Executed(msg.sender, receiver, 1, amounts);
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract
     * @dev Only callable by owner when contract has leftover tokens
     * @param token The token to rescue (use NATIVE_ETH for ETH)
     * @param to The address to send rescued tokens to
     * @param amount The amount to rescue
     */
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (token == NATIVE_ETH) {
            (bool success,) = to.call{ value: amount }("");
            if (!success) {
                revert ETHTransferFailed();
            }
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @notice Receive ETH for wrap/unwrap operations
     */
    receive() external payable { }

    /**
     * @notice Fallback to receive ETH
     */
    fallback() external payable { }
}
