// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title WeirollTestHelper
/// @notice Library to build Weiroll commands and state arrays for testing
/// @dev Weiroll command format (bytes32):
///      - bytes 0-3: function selector (4 bytes)
///      - byte 4: flags (call type in bits 0-1, extended command at bit 7, tuple return at bit 6)
///      - bytes 5-10: input indices (6 bytes, each byte is state index, 0xff = end of args)
///      - byte 11: output index (where to store return value, 0xff = discard)
///      - bytes 12-31: target address (20 bytes)
library WeirollTestHelper {
    // Call type flags (lower 2 bits of flags byte)
    uint8 internal constant FLAG_CT_DELEGATECALL = 0x00;
    uint8 internal constant FLAG_CT_CALL = 0x01;
    uint8 internal constant FLAG_CT_STATICCALL = 0x02;
    uint8 internal constant FLAG_CT_VALUECALL = 0x03;

    // Special indices
    uint8 internal constant IDX_END_OF_ARGS = 0xff;
    uint8 internal constant IDX_VARIABLE_LENGTH = 0x80;

    /// @notice Encode a Weiroll command
    /// @param selector Function selector (4 bytes)
    /// @param flags Call type flags
    /// @param indices Input indices (6 bytes, padded with 0xff)
    /// @param outputIndex Output state index (0xff to discard)
    /// @param target Target contract address
    function encodeCommand(bytes4 selector, uint8 flags, bytes6 indices, uint8 outputIndex, address target)
        internal
        pure
        returns (bytes32)
    {
        // Layout: selector(4) | flags(1) | indices(6) | outputIndex(1) | target(20)
        return bytes32(selector) // bytes 0-3
            | bytes32(uint256(flags) << 216) // byte 4 (shift right 27 bytes = 216 bits from right)
            | bytes32(uint256(uint48(indices)) << 168) // bytes 5-10 (shift right 21 bytes = 168 bits)
            | bytes32(uint256(outputIndex) << 160) // byte 11 (shift right 20 bytes = 160 bits)
            | bytes32(uint256(uint160(target))); // bytes 12-31
    }

    /// @notice Build indices bytes with 0 args
    function indices0() internal pure returns (bytes6) {
        return bytes6(0xffffffffffff);
    }

    /// @notice Build indices bytes with 1 arg
    function indices1(uint8 arg0) internal pure returns (bytes6) {
        return bytes6(uint48(arg0) << 40 | 0xffffffffff);
    }

    /// @notice Build indices bytes with 2 args
    function indices2(uint8 arg0, uint8 arg1) internal pure returns (bytes6) {
        return bytes6(uint48(arg0) << 40 | uint48(arg1) << 32 | 0xffffffff);
    }

    /// @notice Build indices bytes with 3 args
    function indices3(uint8 arg0, uint8 arg1, uint8 arg2) internal pure returns (bytes6) {
        return bytes6(uint48(arg0) << 40 | uint48(arg1) << 32 | uint48(arg2) << 24 | 0xffffff);
    }

    /// @notice Build indices bytes with 4 args
    function indices4(uint8 arg0, uint8 arg1, uint8 arg2, uint8 arg3) internal pure returns (bytes6) {
        return bytes6(uint48(arg0) << 40 | uint48(arg1) << 32 | uint48(arg2) << 24 | uint48(arg3) << 16 | 0xffff);
    }

    /// @notice Build indices bytes with 5 args
    function indices5(uint8 arg0, uint8 arg1, uint8 arg2, uint8 arg3, uint8 arg4) internal pure returns (bytes6) {
        return bytes6(
            uint48(arg0) << 40 | uint48(arg1) << 32 | uint48(arg2) << 24 | uint48(arg3) << 16 | uint48(arg4) << 8 | 0xff
        );
    }

    /// @notice Build a Weiroll CALL command with no arguments, discarding return
    function buildCallNoArgs(address target, bytes4 selector) internal pure returns (bytes32) {
        return encodeCommand(selector, FLAG_CT_CALL, indices0(), IDX_END_OF_ARGS, target);
    }

    /// @notice Build a Weiroll CALL command with one argument, discarding return
    function buildCallOneArg(address target, bytes4 selector, uint8 arg0) internal pure returns (bytes32) {
        return encodeCommand(selector, FLAG_CT_CALL, indices1(arg0), IDX_END_OF_ARGS, target);
    }

    /// @notice Build a Weiroll CALL command with one argument, storing return
    function buildCallOneArgWithReturn(address target, bytes4 selector, uint8 arg0, uint8 outIdx)
        internal
        pure
        returns (bytes32)
    {
        return encodeCommand(selector, FLAG_CT_CALL, indices1(arg0), outIdx, target);
    }

    /// @notice Build a Weiroll CALL command with two arguments, discarding return
    function buildCallTwoArgs(address target, bytes4 selector, uint8 arg0, uint8 arg1) internal pure returns (bytes32) {
        return encodeCommand(selector, FLAG_CT_CALL, indices2(arg0, arg1), IDX_END_OF_ARGS, target);
    }

    /// @notice Build a Weiroll CALL command with three arguments, discarding return
    function buildCallThreeArgs(address target, bytes4 selector, uint8 arg0, uint8 arg1, uint8 arg2)
        internal
        pure
        returns (bytes32)
    {
        return encodeCommand(selector, FLAG_CT_CALL, indices3(arg0, arg1, arg2), IDX_END_OF_ARGS, target);
    }

    /// @notice Build a Weiroll CALL command with four arguments, discarding return
    function buildCallFourArgs(address target, bytes4 selector, uint8 arg0, uint8 arg1, uint8 arg2, uint8 arg3)
        internal
        pure
        returns (bytes32)
    {
        return encodeCommand(selector, FLAG_CT_CALL, indices4(arg0, arg1, arg2, arg3), IDX_END_OF_ARGS, target);
    }

    /// @notice Build a Weiroll VALUECALL command (call with ETH value)
    /// @dev For VALUECALL, first index is the ETH value, remaining are function args
    function buildValueCallNoArgs(address target, bytes4 selector, uint8 valueIdx) internal pure returns (bytes32) {
        return encodeCommand(selector, FLAG_CT_VALUECALL, indices1(valueIdx), IDX_END_OF_ARGS, target);
    }

    /// @notice Build a Weiroll STATICCALL command with one argument, storing return
    function buildStaticCallOneArg(address target, bytes4 selector, uint8 arg0, uint8 outIdx)
        internal
        pure
        returns (bytes32)
    {
        return encodeCommand(selector, FLAG_CT_STATICCALL, indices1(arg0), outIdx, target);
    }

    /// @notice Build a MockERC20.mint(to, amount) command
    function buildMintCommand(address token, uint8 toIdx, uint8 amountIdx) internal pure returns (bytes32) {
        // mint(address,uint256) selector = 0x40c10f19
        return buildCallTwoArgs(token, bytes4(0x40c10f19), toIdx, amountIdx);
    }

    /// @notice Build an ERC20.approve(spender, amount) command
    function buildApproveCommand(address token, uint8 spenderIdx, uint8 amountIdx) internal pure returns (bytes32) {
        // approve(address,uint256) selector = 0x095ea7b3
        return buildCallTwoArgs(token, bytes4(0x095ea7b3), spenderIdx, amountIdx);
    }

    /// @notice Build an ERC20.transfer(to, amount) command
    function buildTransferCommand(address token, uint8 toIdx, uint8 amountIdx) internal pure returns (bytes32) {
        // transfer(address,uint256) selector = 0xa9059cbb
        return buildCallTwoArgs(token, bytes4(0xa9059cbb), toIdx, amountIdx);
    }

    /// @notice Build an ERC20.transferFrom(from, to, amount) command
    function buildTransferFromCommand(address token, uint8 fromIdx, uint8 toIdx, uint8 amountIdx)
        internal
        pure
        returns (bytes32)
    {
        // transferFrom(address,address,uint256) selector = 0x23b872dd
        return buildCallThreeArgs(token, bytes4(0x23b872dd), fromIdx, toIdx, amountIdx);
    }

    /// @notice Build a WETH.deposit() command with value
    function buildWethDepositCommand(address weth, uint8 valueIdx) internal pure returns (bytes32) {
        // deposit() selector = 0xd0e30db0
        return buildValueCallNoArgs(weth, bytes4(0xd0e30db0), valueIdx);
    }

    /// @notice Build a WETH.withdraw(amount) command
    function buildWethWithdrawCommand(address weth, uint8 amountIdx) internal pure returns (bytes32) {
        // withdraw(uint256) selector = 0x2e1a7d4d
        return buildCallOneArg(weth, bytes4(0x2e1a7d4d), amountIdx);
    }

    /// @notice Encode a uint256 value as state array element
    function encodeUint256(uint256 value) internal pure returns (bytes memory) {
        return abi.encode(value);
    }

    /// @notice Encode an address as state array element
    function encodeAddress(address addr) internal pure returns (bytes memory) {
        return abi.encode(addr);
    }

    /// @notice Create a state array with one element
    function createState1(bytes memory elem0) internal pure returns (bytes[] memory state) {
        state = new bytes[](1);
        state[0] = elem0;
    }

    /// @notice Create a state array with two elements
    function createState2(bytes memory elem0, bytes memory elem1) internal pure returns (bytes[] memory state) {
        state = new bytes[](2);
        state[0] = elem0;
        state[1] = elem1;
    }

    /// @notice Create a state array with three elements
    function createState3(bytes memory elem0, bytes memory elem1, bytes memory elem2)
        internal
        pure
        returns (bytes[] memory state)
    {
        state = new bytes[](3);
        state[0] = elem0;
        state[1] = elem1;
        state[2] = elem2;
    }

    /// @notice Create a state array with four elements
    function createState4(bytes memory elem0, bytes memory elem1, bytes memory elem2, bytes memory elem3)
        internal
        pure
        returns (bytes[] memory state)
    {
        state = new bytes[](4);
        state[0] = elem0;
        state[1] = elem1;
        state[2] = elem2;
        state[3] = elem3;
    }

    /// @notice Create a state array with five elements
    function createState5(
        bytes memory elem0,
        bytes memory elem1,
        bytes memory elem2,
        bytes memory elem3,
        bytes memory elem4
    ) internal pure returns (bytes[] memory state) {
        state = new bytes[](5);
        state[0] = elem0;
        state[1] = elem1;
        state[2] = elem2;
        state[3] = elem3;
        state[4] = elem4;
    }

    /// @notice Create a state array with six elements
    function createState6(
        bytes memory elem0,
        bytes memory elem1,
        bytes memory elem2,
        bytes memory elem3,
        bytes memory elem4,
        bytes memory elem5
    ) internal pure returns (bytes[] memory state) {
        state = new bytes[](6);
        state[0] = elem0;
        state[1] = elem1;
        state[2] = elem2;
        state[3] = elem3;
        state[4] = elem4;
        state[5] = elem5;
    }
}
