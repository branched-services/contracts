// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title UniV3SwapHelper
/// @notice Single-purpose helper invoked by ExecutionProxy via Weiroll DELEGATECALL during the
///         testnet end-to-end swap script. Bridges Weiroll's 6-arg short-command form to
///         Uniswap V3 SwapRouter02's 7-field `exactInputSingle` struct: hardcodes `fee = 3000`
///         and `sqrtPriceLimitX96 = 0`, derives the recipient from `msg.sender` (which under
///         delegatecall is the Router that called `executePath`), and encodes the
///         `exactInputSingle` calldata in-line. Also approves `tokenIn` to the Uniswap router
///         in the same delegatecall so the swap pulls funds from the ExecutionProxy that ran
///         the Weiroll program.
/// @dev    Deployed once per chain inside the broadcast run; not part of the production set.
contract UniV3SwapHelper {
    /// @notice `exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))`
    bytes4 internal constant EXACT_INPUT_SINGLE_SELECTOR = 0x04e45aaf;

    /// @notice 0.30% pool tier: the standard WETH/USDC pool tier on testnet deployments.
    uint24 internal constant POOL_FEE = 3000;

    /// @notice DELEGATECALL target. Approves `tokenIn` to `uniRouter` and runs
    ///         `uniRouter.exactInputSingle` with `recipient = msg.sender`. Under delegatecall
    ///         msg.sender is the caller of `ExecutionProxy.executePath` (i.e., the Router),
    ///         so output flows back to the Router for balance-diff measurement.
    /// @dev    Marked `payable` because delegatecall preserves the caller frame's
    ///         `msg.value`. On the native-input leg, `Router.swap{value}` →
    ///         `ExecutionProxy.executePath{value}` → `delegatecall(helper.swap)` inherits
    ///         that value; without `payable` Solidity 0.8+ auto-reverts the entry guard
    ///         even though the inherited ETH is already consumed by the prior `weth.deposit`
    ///         command in the same Weiroll program.
    function swap(address uniRouter, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin)
        external
        payable
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).approve(uniRouter, amountIn);
        (bool ok, bytes memory ret) = uniRouter.call(
            abi.encodeWithSelector(
                EXACT_INPUT_SINGLE_SELECTOR, tokenIn, tokenOut, POOL_FEE, msg.sender, amountIn, amountOutMin, uint160(0)
            )
        );
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return abi.decode(ret, (uint256));
    }
}
