// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2023 Tokemak Foundation. All rights reserved.
pragma solidity ^0.8.24;

//slither-disable-start assembly
contract Tupler {
    /**
     * @notice Extracts an element from a byte tuple at a given index.
     * @param tuple The input byte tuple from which to extract the element.
     * @param index The index of the element to be extracted (0-based).
     * @return The extracted bytes32 element.
     */
    function extractElement(bytes memory tuple, uint256 index) public pure returns (bytes32) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            return(add(tuple, mul(add(index, 1), 32)), 32)
        }
    }
}
//slither-disable-end assembly