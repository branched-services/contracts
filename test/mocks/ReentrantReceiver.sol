// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITransferCallback } from "./AdversarialTokens.sol";

/// @title ReentrantReceiver
/// @notice Base reentrancy attacker used by Router adversarial tests (INF-0011).
///         Records that a re-entry attempt happened via ETH `receive` or ERC20 transfer
///         callback, but does not itself target a specific contract: downstream tests
///         extend this (or wrap it) to invoke the Router's swap entry points inside
///         the callback and assert the `nonReentrant` guard reverts the re-entry.
/// @dev Intentionally target-agnostic after the Router refactor. The previous version
///      called `ExecutionProxy.execute` / `executeSingle` directly; those entry points
///      are gone under FR-11 (ExecutionProxy is a pure VM). Re-entrancy is now the
///      Router's concern and is covered in `test/Router.Adversarial.t.sol`.
contract ReentrantReceiver is ITransferCallback {
    bool public attackEnabled;
    uint256 public attackCount;
    uint256 public maxAttacks = 1;

    bool public attackAttempted;
    bool public attackSucceeded;

    /// @notice Enable/disable the re-entry attempt. Off by default so accidental
    ///         ETH transfers in setup do not count as attacks.
    function setAttackEnabled(bool enabled) external {
        attackEnabled = enabled;
    }

    /// @notice Cap the number of re-entry attempts so a bounded attack plays out in tests.
    function setMaxAttacks(uint256 _maxAttacks) external {
        maxAttacks = _maxAttacks;
    }

    /// @notice Reset the attack ledger between test cases.
    function resetAttackState() external {
        attackAttempted = false;
        attackSucceeded = false;
        attackCount = 0;
    }

    receive() external payable {
        _recordAttempt();
    }

    /// @inheritdoc ITransferCallback
    function onTokenTransfer(address, address, uint256) external override {
        _recordAttempt();
    }

    function _recordAttempt() internal {
        if (attackEnabled && attackCount < maxAttacks) {
            attackCount++;
            attackAttempted = true;
        }
    }
}
