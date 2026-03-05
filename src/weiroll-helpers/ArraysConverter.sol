// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2023 Tokemak Foundation. All rights reserved.
pragma solidity ^0.8.24;

contract ArraysConverter {
    /**
     * @notice Converts two uint256 values into a uint256 array
     * @param a The first uint256 value
     * @param b The second uint256 value
     * @return values The array containing the two uint256 inputs
     */
    function toArray(uint256 a, uint256 b) public pure returns (uint256[] memory) {
        uint256[] memory values = new uint256[](2);
        values[0] = a;
        values[1] = b;
        return values;
    }

    function toArray(uint256 a, uint256 b, uint256 c) public pure returns (uint256[] memory) {
        uint256[] memory values = new uint256[](3);
        values[0] = a;
        values[1] = b;
        values[2] = c;
        return values;
    }

    function toArray(uint256 a, uint256 b, uint256 c, uint256 d) public pure returns (uint256[] memory) {
        uint256[] memory values = new uint256[](4);
        values[0] = a;
        values[1] = b;
        values[2] = c;
        values[3] = d;
        return values;
    }

    /**
     * @notice Extracts the last element from a uint256 array
     * @dev Useful for extracting output amount from Uniswap V2 swapExactTokensForTokens
     * @param amounts The input array
     * @return The last element of the array
     */
    function extractLastElement(uint256[] memory amounts) public pure returns (uint256) {
        require(amounts.length > 0, "Empty array");
        return amounts[amounts.length - 1];
    }

    /**
     * @notice Extracts an element at a specific index from a uint256 array
     * @param amounts The input array
     * @param index The index to extract (0-based)
     * @return The element at the given index
     */
    function extractElement(uint256[] memory amounts, uint256 index) public pure returns (uint256) {
        require(index < amounts.length, "Index out of bounds");
        return amounts[index];
    }

    /**
     * @notice Extracts an element from a fixed-size uint256[2] array
     * @dev Used for Curve pools with 2 tokens
     * @param arr The fixed-size array
     * @param index The index to extract (0 or 1)
     * @return The element at the given index
     */
    function extractFrom2(uint256[2] memory arr, uint256 index) public pure returns (uint256) {
        require(index < 2, "Index out of bounds");
        return arr[index];
    }

    /**
     * @notice Extracts an element from a fixed-size uint256[3] array
     * @dev Used for Curve pools with 3 tokens
     * @param arr The fixed-size array
     * @param index The index to extract (0, 1, or 2)
     * @return The element at the given index
     */
    function extractFrom3(uint256[3] memory arr, uint256 index) public pure returns (uint256) {
        require(index < 3, "Index out of bounds");
        return arr[index];
    }

    /**
     * @notice Extracts an element from a fixed-size uint256[4] array
     * @dev Used for Curve pools with 4 tokens
     * @param arr The fixed-size array
     * @param index The index to extract (0, 1, 2, or 3)
     * @return The element at the given index
     */
    function extractFrom4(uint256[4] memory arr, uint256 index) public pure returns (uint256) {
        require(index < 4, "Index out of bounds");
        return arr[index];
    }
}
