// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IExecutor } from "src/interfaces/IExecutor.sol";

// -------------------------------------------------------------------------
// Router errors
//
// The eighteen errors below are declared at file scope and used directly by
// the Router. A single error (`Paused`) lives in the `RouterErrors` library
// below instead, because it shares its name with the `Paused(address)` event
// inherited from OpenZeppelin's `Pausable` — Solidity rejects reusing an
// identifier across kinds (event vs. error) within the same contract scope
// and resolves an unqualified `Paused()` to the inherited event, which would
// shadow a file-level error declaration at the revert site. Qualifying the
// pause revert as `RouterErrors.Paused()` keeps the spec-named error without
// renaming the OZ event.
// -------------------------------------------------------------------------

error ZeroInputAmount();
error ZeroOutputQuote();
error ZeroOutputMin();
error InvalidSlippageBounds();
error SelfSwap();
error ProtocolFeeExceedsCap(uint256 bps);
error PartnerFeeExceedsCap(uint256 bps);
error InvalidPartnerRecipient();
error ETHValueMismatch();
error SlippageExceeded(address token, uint256 got, uint256 min);
error ETHTransferFailed();
error DuplicateToken(address token);
error InputOutputIntersection(address token);
error Unauthorized();
error NotImplemented();
error ExecutorNotSet();
error ZeroAddress();
error ArrayLengthMismatch();

/// @notice Library carrying errors that would collide with identifiers inherited by Router.
library RouterErrors {
    error Paused();
}

/**
 * @title Router
 * @notice User-facing entry point for the Infrared execution layer. The Router holds user ERC20
 *         approvals and native ETH, applies the protocol fee (on input), the partner fee
 *         (input- or output-denominated), and captures positive slippage between the backend-
 *         supplied `outputQuote` and the executor-produced amount. All economic logic lives
 *         here; the executor is a pure Weiroll VM invoked via `IExecutor.executePath`.
 * @dev This file freezes the Router ABI (events, errors, entry-point signatures, admin surface,
 *      sweep surface) so downstream tasks can land in parallel. Real implementations for
 *      `swap`, `swapMulti`, and `swapRouterFunds` land in INF-0005 and INF-0006 without
 *      changing any signature declared here.
 */
contract Router is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Sentinel address used to represent native ETH in input/output positions.
    ///         Shared with the executor and Weiroll helper programs.
    address public constant NATIVE_ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Hard cap on the caller-supplied `protocolFeeBps`. Immutable guarantee that
    ///         the protocol fee taken from user input never exceeds 2.00%.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 200;

    /// @notice Hard cap on the caller-supplied `partnerFeeBps`. Immutable guarantee that
    ///         the partner fee never exceeds 2.00%. Caps are applied independently of the
    ///         protocol fee; the theoretical combined worst case on input is 4.00%.
    uint256 public constant MAX_PARTNER_FEE_BPS = 200;

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice Parameters for a single-input, single-output swap. Assembled by the backend
    ///         quoting engine and passed verbatim to `swap`.
    struct SwapParams {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 outputQuote;
        uint256 outputMin;
        address recipient;
        uint16 protocolFeeBps;
        uint16 partnerFeeBps;
        address partnerRecipient;
        bool partnerFeeOnOutput;
        bool passPositiveSlippageToUser;
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    /// @notice Parameters for an atomic multi-input, multi-output swap.
    struct MultiSwapParams {
        address[] inputTokens;
        uint256[] inputAmounts;
        address[] outputTokens;
        uint256[] outputQuotes;
        uint256[] outputMins;
        address recipient;
        uint16 protocolFeeBps;
        uint16 partnerFeeBps;
        address partnerRecipient;
        bool partnerFeeOnOutput;
        bool passPositiveSlippageToUser;
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted once per swap (single or multi). The ten fields are sufficient to
    ///         reconstruct full fee attribution off-chain per FR-17.
    event Swap(
        address indexed sender,
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 amountOut,
        uint256 amountToUser,
        uint256 protocolFee,
        uint256 partnerFee,
        uint256 positiveSlippageCaptured,
        address partnerRecipient
    );

    /// @notice Emitted when the owner updates the liquidator address.
    event LiquidatorUpdated(address previousLiquidator, address newLiquidator);

    /// @notice Emitted when the owner proposes a new executor. Completion requires
    ///         a subsequent `acceptExecutor` call.
    event PendingExecutorSet(address pendingExecutor);

    /// @notice Emitted when the pending executor is promoted to the active executor.
    event ExecutorUpdated(address previousExecutor, address newExecutor);

    /// @notice Emitted when accrued fees or retained slippage are swept via `transferRouterFunds`.
    event FundsTransferred(address[] tokens, uint256[] amounts, address dest);

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Active executor. Router forwards remaining input tokens here and invokes
    ///         `IExecutor.executePath` on this address.
    address public executor;

    /// @notice Executor proposed by the owner but not yet accepted. Cleared on accept.
    address public pendingExecutor;

    /// @notice Hot-wallet address authorized alongside the owner to call sweep functions.
    ///         Separated from the owner so routine sweeps do not require multisig signatures.
    address public liquidator;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Gates the sweep functions. Reverts with the spec-named `Unauthorized` error
    ///      rather than the OZ `OwnableUnauthorizedAccount` since a non-owner liquidator
    ///      is also allowed.
    modifier onlyOwnerOrLiquidator() {
        if (msg.sender != owner() && msg.sender != liquidator) {
            revert Unauthorized();
        }
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param _owner Initial owner (expected to be a multisig). Must be non-zero.
     * @param _liquidator Initial liquidator. Must be non-zero at construction; may later be
     *        set to `address(0)` via `setLiquidator` to disable the role.
     */
    constructor(address _owner, address _liquidator) Ownable(_owner) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_liquidator == address(0)) revert ZeroAddress();
        liquidator = _liquidator;
        emit LiquidatorUpdated(address(0), _liquidator);
    }

    // -------------------------------------------------------------------------
    // Pausable override
    // -------------------------------------------------------------------------

    /// @dev Override OZ's default so the `whenNotPaused` modifier reverts with the
    ///      spec-named `Paused` error rather than `EnforcedPause`. The error lives in
    ///      `RouterErrors` to avoid a name collision with OZ's `Paused(address)` event.
    function _requireNotPaused() internal view virtual override {
        if (paused()) revert RouterErrors.Paused();
    }

    // -------------------------------------------------------------------------
    // Admin surface
    // -------------------------------------------------------------------------

    /// @notice Propose a new executor. Effect is deferred until `acceptExecutor` is called.
    function setPendingExecutor(address newPendingExecutor) external onlyOwner {
        pendingExecutor = newPendingExecutor;
        emit PendingExecutorSet(newPendingExecutor);
    }

    /// @notice Promote the pending executor to the active executor. Owner-driven per the spec.
    function acceptExecutor() external onlyOwner {
        address newExecutor = pendingExecutor;
        if (newExecutor == address(0)) revert ExecutorNotSet();
        address previousExecutor = executor;
        executor = newExecutor;
        pendingExecutor = address(0);
        emit ExecutorUpdated(previousExecutor, newExecutor);
    }

    /// @notice Update the liquidator address. Zero address is permitted and disables the role.
    function setLiquidator(address newLiquidator) external onlyOwner {
        address previousLiquidator = liquidator;
        liquidator = newLiquidator;
        emit LiquidatorUpdated(previousLiquidator, newLiquidator);
    }

    /// @notice Emergency stop. All swap entry points revert with `Paused` while active.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Lift the emergency stop.
    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Internal swap helpers
    // -------------------------------------------------------------------------

    /// @dev Validation common to both user-initiated `swap` and liquidator-initiated
    ///      `swapRouterFunds`. Mirrors the Error Handling table in the spec; the only
    ///      check left out is the msg.value / native-input reconciliation, which is
    ///      applied in `_validateSwap` for the user-facing path but skipped for the
    ///      Router-funded path (Router already holds the input balance).
    function _validateSwapCommon(SwapParams calldata p) internal view {
        if (executor == address(0)) revert ExecutorNotSet();
        if (p.inputAmount == 0) revert ZeroInputAmount();
        if (p.outputQuote == 0) revert ZeroOutputQuote();
        if (p.outputMin == 0) revert ZeroOutputMin();
        if (p.outputMin > p.outputQuote) revert InvalidSlippageBounds();
        if (p.inputToken == p.outputToken) revert SelfSwap();
        if (p.protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeExceedsCap(p.protocolFeeBps);
        if (p.partnerFeeBps > MAX_PARTNER_FEE_BPS) revert PartnerFeeExceedsCap(p.partnerFeeBps);
        if (p.partnerFeeBps > 0 && p.partnerRecipient == address(0)) revert InvalidPartnerRecipient();
    }

    /// @dev Full validation for the user-facing `swap` entry point: common checks plus the
    ///      msg.value reconciliation (exactly `inputAmount` for native input, exactly 0 for ERC20).
    function _validateSwap(SwapParams calldata p) internal view {
        _validateSwapCommon(p);
        if (p.inputToken == NATIVE_ETH_SENTINEL) {
            if (msg.value != p.inputAmount) revert ETHValueMismatch();
        } else if (msg.value != 0) {
            revert ETHValueMismatch();
        }
    }

    /// @dev Router-balance accessor that handles the native ETH sentinel uniformly with ERC20s.
    function _balanceOf(address token) internal view returns (uint256) {
        if (token == NATIVE_ETH_SENTINEL) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    /// @dev Pull `amount` of `token` from the caller into the Router and return the balance delta
    ///      actually received. For native ETH the caller has already forwarded the amount via
    ///      `msg.value` (validated in `_validateSwap`), so `amount` is returned unchanged. For
    ///      ERC20s the before/after measurement lets fee-on-transfer tokens flow through the rest
    ///      of the swap using their post-fee amount (FR-15).
    function _pullInput(address token, uint256 amount) internal returns (uint256 pulled) {
        if (token == NATIVE_ETH_SENTINEL) {
            return amount;
        }
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        return IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Pay `amount` of `token` out to `to`. No-ops on zero amount (useful when partner or
    ///      positive-slippage paths are inactive). Native ETH uses `.call{value}` with full gas
    ///      forwarding so multisig receivers work; failure reverts `ETHTransferFailed`.
    function _transferOut(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == NATIVE_ETH_SENTINEL) {
            (bool ok,) = to.call{ value: amount }("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Forward the remaining input to the executor and invoke `executePath`. ERC20 paths use
    ///      a standard `safeTransfer` followed by a direct interface call (natural revert bubble).
    ///      Native ETH paths encode the call via `abi.encodeCall` and pass `value` through the
    ///      low-level call; a revert inside the executor is rethrown with its original returndata.
    function _forwardToExecutor(address token, uint256 amount, bytes32[] calldata commands, bytes[] calldata state)
        internal
    {
        address exec = executor;
        if (token == NATIVE_ETH_SENTINEL) {
            (bool ok,) = exec.call{ value: amount }(abi.encodeCall(IExecutor.executePath, (commands, state)));
            if (!ok) {
                assembly {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
        } else {
            IERC20(token).safeTransfer(exec, amount);
            IExecutor(exec).executePath(commands, state);
        }
    }

    /// @dev Core swap sequence shared by `swap` and `swapRouterFunds`. Implements steps (c)..(m)
    ///      of the Behavior Specification verbatim: fee accounting, balance-diff measurement,
    ///      positive-slippage cap, output-denominated partner fee, slippage floor, payout, event.
    function _executeSwap(SwapParams calldata params, uint256 pulled) internal returns (uint256 amountOut) {
        uint256 protocolFee = (pulled * params.protocolFeeBps) / 10_000;
        uint256 inputPartnerFee = params.partnerFeeOnOutput ? 0 : (pulled * params.partnerFeeBps) / 10_000;
        if (inputPartnerFee > 0) {
            _transferOut(params.inputToken, params.partnerRecipient, inputPartnerFee);
        }

        uint256 outputBefore = _balanceOf(params.outputToken);
        _forwardToExecutor(
            params.inputToken, pulled - protocolFee - inputPartnerFee, params.weirollCommands, params.weirollState
        );
        amountOut = _balanceOf(params.outputToken) - outputBefore;

        uint256 positiveSlippage;
        if (!params.passPositiveSlippageToUser && amountOut > params.outputQuote) {
            positiveSlippage = amountOut - params.outputQuote;
            amountOut = params.outputQuote;
        }

        uint256 outputPartnerFee;
        if (params.partnerFeeOnOutput && params.partnerFeeBps > 0) {
            outputPartnerFee = (amountOut * params.partnerFeeBps) / 10_000;
            amountOut -= outputPartnerFee;
            _transferOut(params.outputToken, params.partnerRecipient, outputPartnerFee);
        }

        if (amountOut < params.outputMin) {
            revert SlippageExceeded(params.outputToken, amountOut, params.outputMin);
        }

        _transferOut(params.outputToken, params.recipient, amountOut);

        _emitSwap(
            params, amountOut, outputPartnerFee, protocolFee, inputPartnerFee + outputPartnerFee, positiveSlippage
        );
    }

    /// @dev Extracted to keep `_executeSwap`'s stack under the EVM's 16-slot limit. The event's
    ///      `amountOut` field is the raw executor-produced amount, reconstructed here as
    ///      `amountToUser + outputPartnerFee + positiveSlippage` so off-chain consumers can
    ///      tie fee attribution back to the pulled input (invariant used by INF-0012).
    function _emitSwap(
        SwapParams calldata params,
        uint256 amountToUser,
        uint256 outputPartnerFee,
        uint256 protocolFee,
        uint256 partnerFee,
        uint256 positiveSlippage
    ) internal {
        emit Swap(
            msg.sender,
            params.inputToken,
            params.inputAmount,
            params.outputToken,
            amountToUser + outputPartnerFee + positiveSlippage,
            amountToUser,
            protocolFee,
            partnerFee,
            positiveSlippage,
            params.partnerRecipient
        );
    }

    // -------------------------------------------------------------------------
    // Swap entry points
    // -------------------------------------------------------------------------

    /// @notice Single-input, single-output swap. Pulls input from `msg.sender` (or accepts it as
    ///         native ETH via `msg.value`), deducts protocol and optional partner fees, forwards
    ///         the remainder to the executor, measures output via balance-diff, optionally caps
    ///         positive slippage, applies output-denominated partner fee, and pays the user.
    function swap(SwapParams calldata params) external payable nonReentrant whenNotPaused returns (uint256 amountOut) {
        _validateSwap(params);
        uint256 pulled = _pullInput(params.inputToken, params.inputAmount);
        amountOut = _executeSwap(params, pulled);
    }

    /// @notice Multi-input, multi-output swap. Body lands in INF-0006.
    function swapMulti(
        MultiSwapParams calldata /* params */
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (
            uint256[] memory /* amountsOut */
        )
    {
        revert NotImplemented();
    }

    // -------------------------------------------------------------------------
    // Sweep surface
    // -------------------------------------------------------------------------

    /**
     * @notice Sweep accrued ERC20 and/or native ETH balances to `dest`. Callable only by
     *         the owner or the liquidator. Zero-length arrays are accepted as a no-op
     *         (still emits `FundsTransferred`).
     * @param tokens Token addresses to sweep; use `NATIVE_ETH_SENTINEL` for native ETH.
     * @param amounts Amounts to sweep (parallel to `tokens`).
     * @param dest Recipient of the swept funds.
     */
    function transferRouterFunds(address[] calldata tokens, uint256[] calldata amounts, address dest)
        external
        onlyOwnerOrLiquidator
    {
        if (tokens.length != amounts.length) revert ArrayLengthMismatch();
        if (dest == address(0)) revert ZeroAddress();

        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            if (token == NATIVE_ETH_SENTINEL) {
                (bool ok,) = dest.call{ value: amount }("");
                if (!ok) revert ETHTransferFailed();
            } else {
                IERC20(token).safeTransfer(dest, amount);
            }
        }

        emit FundsTransferred(tokens, amounts, dest);
    }

    /**
     * @notice Sweep accrued balances by routing them through a Weiroll path rather than paying
     *         them out directly. Runs the same fee/slippage pipeline as `swap` but starts from
     *         Router-held funds: no `transferFrom`, no `msg.value`. Used to convert accumulated
     *         fee dust into a canonical token. Owner- or liquidator-gated.
     */
    function swapRouterFunds(SwapParams calldata params) external onlyOwnerOrLiquidator returns (uint256 amountOut) {
        _validateSwapCommon(params);
        if (params.recipient == address(0)) revert ZeroAddress();
        uint256 pulled = params.inputAmount;
        require(_balanceOf(params.inputToken) >= pulled, "Router: insufficient balance");
        amountOut = _executeSwap(params, pulled);
    }

    // -------------------------------------------------------------------------
    // Native ETH receive
    // -------------------------------------------------------------------------

    /// @notice Allow the Router to hold native ETH (protocol fees, retained positive slippage,
    ///         or direct sends from the executor during a swap).
    receive() external payable { }
}
