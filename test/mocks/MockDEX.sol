// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IMintableERC20
/// @notice Interface for tokens that support minting (for test mocks)
interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title MockDEX
/// @notice Simulates a DEX swap for testing Weiroll programs
/// @dev Takes tokenIn from caller, mints tokenOut to caller (or specified recipient)
contract MockDEX {
    /// @notice Emitted when a swap occurs
    event Swap(
        address indexed tokenIn, address indexed tokenOut, address indexed recipient, uint256 amountIn, uint256 amountOut
    );

    /// @notice Execute a swap - takes tokenIn, mints tokenOut
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address (must be mintable)
    /// @param amountIn The amount of tokenIn to take
    /// @param amountOut The amount of tokenOut to mint
    /// @return actualOut The actual amount of tokenOut minted
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        external
        returns (uint256 actualOut)
    {
        // Transfer tokenIn from caller
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Mint tokenOut to caller
        IMintableERC20(tokenOut).mint(msg.sender, amountOut);

        emit Swap(tokenIn, tokenOut, msg.sender, amountIn, amountOut);
        return amountOut;
    }

    /// @notice Execute a swap with explicit recipient
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address (must be mintable)
    /// @param amountIn The amount of tokenIn to take
    /// @param amountOut The amount of tokenOut to mint
    /// @param recipient The address to receive tokenOut
    /// @return actualOut The actual amount of tokenOut minted
    function swapTo(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient)
        external
        returns (uint256 actualOut)
    {
        // Transfer tokenIn from caller
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Mint tokenOut to recipient
        IMintableERC20(tokenOut).mint(recipient, amountOut);

        emit Swap(tokenIn, tokenOut, recipient, amountIn, amountOut);
        return amountOut;
    }

    /// @notice Execute a swap taking tokens from this contract (for Weiroll delegatecall patterns)
    /// @dev Assumes tokens are already in this contract
    /// @param tokenIn The input token address (tokens must already be in this contract)
    /// @param tokenOut The output token address (must be mintable)
    /// @param amountIn The amount of tokenIn to consume (must be <= balance)
    /// @param amountOut The amount of tokenOut to mint to this contract
    /// @return actualOut The actual amount of tokenOut minted
    function swapFromBalance(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        external
        returns (uint256 actualOut)
    {
        // Verify we have the tokens (they stay in this contract, simulating consumption)
        require(IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "MockDEX: insufficient tokenIn balance");

        // Mint tokenOut to this contract
        IMintableERC20(tokenOut).mint(address(this), amountOut);

        emit Swap(tokenIn, tokenOut, address(this), amountIn, amountOut);
        return amountOut;
    }
}
