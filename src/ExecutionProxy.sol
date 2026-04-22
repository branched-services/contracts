// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { VM } from "@weiroll/VM.sol";
import { IExecutor } from "src/interfaces/IExecutor.sol";

/**
 * @title ExecutionProxy
 * @notice Pure Weiroll VM executor invoked by the Router. Holds no user approvals,
 *         no fee state, and no economic logic: the Router owns pulls, fees, slippage,
 *         and recipient transfers and calls `executePath` to run a Weiroll program.
 * @dev Intentionally stateless and permissionless. No owner, no reentrancy guard
 *      (the Router enforces the `nonReentrant` boundary, and balance-diff accounting
 *      at the Router is the defense-in-depth), no typed-data signatures, no storage
 *      variables, no constructor, no admin functions. Minimizes the audit surface
 *      of the arbitrary-execution piece per FR-11.
 *
 *      `receive()` and `fallback()` remain payable so the Router can forward
 *      native ETH via `executor.call{value: ...}(...)` or direct transfers
 *      produced by Weiroll sub-calls (e.g., WETH unwraps).
 */
contract ExecutionProxy is VM, IExecutor {
    /// @notice Native ETH sentinel address shared with the Router and Weiroll helper
    ///         programs that branch on native vs. ERC20 tokens.
    /// @dev Declared without an explicit visibility modifier so it is a pure
    ///      compile-time constant with no storage slot and does not introduce any
    ///      state-variable-like declaration on this audit-minimized surface.
    address constant NATIVE_ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @inheritdoc IExecutor
    function executePath(bytes32[] calldata commands, bytes[] calldata state) external payable override {
        _execute(commands, state);
    }

    /// @notice Accept native ETH forwarded by the Router or returned by Weiroll sub-calls.
    receive() external payable { }

    /// @notice Accept native ETH via fallback for callers that do not target `receive()`.
    fallback() external payable { }
}
