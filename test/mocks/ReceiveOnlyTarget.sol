// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ReceiveOnlyTarget
/// @notice Test fixture for FLAG_DATA: accepts plain value transfers via receive() and
///         has no fallback(). Used to prove that a Weiroll value-call with FLAG_DATA
///         and an empty bytes calldata slot can invoke receive() rather than reverting
///         on a missing fallback.
contract ReceiveOnlyTarget {
    uint256 public calls;
    uint256 public totalReceived;

    receive() external payable {
        unchecked {
            calls += 1;
            totalReceived += msg.value;
        }
    }
}
