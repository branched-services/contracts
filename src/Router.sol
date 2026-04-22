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
    // Swap entry points (scaffold)
    // -------------------------------------------------------------------------

    /// @notice Single-input, single-output swap. Body lands in INF-0005.
    function swap(
        SwapParams calldata /* params */
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (
            uint256 /* amountOut */
        )
    {
        revert NotImplemented();
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
     * @notice Sweep accrued balances by routing them through a user-supplied Weiroll path
     *         rather than transferring them directly. Real implementation lands with INF-0005
     *         once `swap` has a body to reuse.
     */
    function swapRouterFunds(
        SwapParams calldata /* params */
    )
        external
        onlyOwnerOrLiquidator
        returns (uint256)
    {
        revert NotImplemented();
    }

    // -------------------------------------------------------------------------
    // Native ETH receive
    // -------------------------------------------------------------------------

    /// @notice Allow the Router to hold native ETH (protocol fees, retained positive slippage,
    ///         or direct sends from the executor during a swap).
    receive() external payable { }
}
