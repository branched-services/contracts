// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2023 Tokemak Foundation. All rights reserved.
pragma solidity ^0.8.24;

interface IInteger {
    error NotGreaterThan(uint256 a, uint256 b);
    error NotGreaterThanOrEqualTo(uint256 a, uint256 b);
    error NotLessThan(uint256 a, uint256 b);
    error NotLessThanOrEqualTo(uint256 a, uint256 b);
    error NotEqualTo(uint256 a, uint256 b);

    /**
     * @notice Checks if a given unsigned integer 'a' is greater than another unsigned integer 'b'.
     * @param a The first unsigned integer.
     * @param b The second unsigned integer.
     */
    function isGt(uint256 a, uint256 b) external pure;

    /**
     * @notice Checks if a given unsigned integer 'a' is greater than or equal to another unsigned integer 'b'.
     * @param a The first unsigned integer.
     * @param b The second unsigned integer.
     */
    function isGte(uint256 a, uint256 b) external pure;

    /**
     * @notice Checks if a given unsigned integer 'a' is less than another unsigned integer 'b'.
     * @param a The first unsigned integer.
     * @param b The second unsigned integer.
     */
    function isLt(uint256 a, uint256 b) external pure;

    /**
     * @notice Checks if a given unsigned integer 'a' is less than or equal to another unsigned integer 'b'.
     * @param a The first unsigned integer.
     * @param b The second unsigned integer.
     */
    function isLte(uint256 a, uint256 b) external pure;

    /**
     * @notice Checks if a given unsigned integer 'a' is equal to another unsigned integer 'b'.
     * @param a The first unsigned integer.
     * @param b The second unsigned integer.
     */
    function isEqual(uint256 a, uint256 b) external pure;
}

contract Integer is IInteger {
    function isGt(uint256 a, uint256 b) public pure {
        if (a <= b) {
            revert NotGreaterThan(a, b);
        }
    }

    function isGte(uint256 a, uint256 b) public pure {
        if (a < b) {
            revert NotGreaterThanOrEqualTo(a, b);
        }
    }

    function isLt(uint256 a, uint256 b) public pure {
        if (a >= b) {
            revert NotLessThan(a, b);
        }
    }

    function isLte(uint256 a, uint256 b) public pure {
        if (a > b) {
            revert NotLessThanOrEqualTo(a, b);
        }
    }

    function isEqual(uint256 a, uint256 b) public pure {
        if (a != b) {
            revert NotEqualTo(a, b);
        }
    }
}