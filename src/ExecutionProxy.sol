// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { VM } from "@weiroll/VM.sol";

/**
 * @title ExecutionProxy
 * @notice Proxy contract for executing Weiroll programs with output verification
 * @dev Receives Weiroll programs from the Infrared Engine, executes them atomically,
 *      verifies output amounts meet slippage requirements, and transfers outputs to receiver.
 *      Uses delta-based balance measurement and supports EIP-712 signed fee overrides.
 */
contract ExecutionProxy is VM, ReentrancyGuard, Ownable, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice Specification for expected output tokens and minimum amounts
    struct OutputSpec {
        address token;
        uint256 minAmount;
    }

    /// @notice Emitted when a swap execution completes successfully
    event Executed(address indexed sender, address indexed receiver, uint256 outputCount, uint256[] actualAmounts);

    /// @notice Emitted when default fee basis points are updated
    event DefaultFeeBpsUpdated(uint96 oldFeeBps, uint96 newFeeBps);

    /// @notice Emitted when fee recipient is updated
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    /// @notice Emitted when fee signer is updated
    event FeeSignerUpdated(address oldSigner, address newSigner);

    /// @notice Error thrown when output amount is below minimum
    error SlippageExceeded(address token, uint256 actual, uint256 minimum);

    /// @notice Error thrown when ETH transfer fails
    error ETHTransferFailed();

    /// @notice Error thrown when output array is empty
    error NoOutputsSpecified();

    /// @notice Error thrown when fee signature is invalid
    error InvalidFeeSignature();

    /// @notice Error thrown when fee exceeds maximum
    error FeeExceedsMax(uint256 feeBps);

    /// @notice Error thrown when fee signature has expired
    error FeeSignatureExpired();

    /// @notice Native ETH sentinel address
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Fee recipient address (packed with defaultFeeBps in 1 slot)
    /// @dev Owner-set trusted address. A reverting feeRecipient will block all ETH-output
    ///      executions with non-zero fees. No gas limit on the ETH call to support multisig
    ///      and contract recipients.
    address public feeRecipient;

    /// @notice Default fee in basis points
    uint96 public defaultFeeBps;

    /// @notice Address authorized to sign fee overrides
    address public feeSigner;

    /// @notice Maximum allowed fee in basis points (10%)
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice EIP-712 typehash for fee override signatures
    bytes32 public constant FEE_OVERRIDE_TYPEHASH =
        keccak256("FeeOverride(uint256 feeBps,uint256 deadline,address caller,bytes32 executionHash)");

    constructor(address _owner, address _feeRecipient, uint96 _defaultFeeBps, address _feeSigner)
        Ownable(_owner)
        EIP712("ExecutionProxy", "1")
    {
        if (_defaultFeeBps > MAX_FEE_BPS) revert FeeExceedsMax(_defaultFeeBps);
        feeRecipient = _feeRecipient;
        defaultFeeBps = _defaultFeeBps;
        feeSigner = _feeSigner;
    }

    /**
     * @notice Execute a Weiroll program with multi-output verification
     * @param commands The Weiroll command sequence
     * @param state The initial state array for Weiroll execution
     * @param outputs Array of output specifications (token + minimum amount)
     * @param receiver Address to receive the output tokens
     * @param feeData Empty for default fee, or encoded (feeBps, deadline, signature) for signed override
     * @return actualAmounts Array of actual amounts transferred for each output
     */
    function execute(
        bytes32[] calldata commands,
        bytes[] calldata state,
        OutputSpec[] calldata outputs,
        address receiver,
        bytes calldata feeData
    ) external payable nonReentrant returns (uint256[] memory actualAmounts) {
        if (outputs.length == 0) {
            revert NoOutputsSpecified();
        }

        // Cache feeRecipient from storage (packed with defaultFeeBps, 1 SLOAD)
        address _feeRecipient = feeRecipient;

        // Resolve fee
        uint256 feeBps;
        if (feeData.length == 0) {
            feeBps = defaultFeeBps;
        } else {
            bytes32 executionHash = keccak256(
                abi.encode(
                    keccak256(abi.encode(commands)),
                    keccak256(abi.encode(state)),
                    keccak256(abi.encode(outputs)),
                    receiver
                )
            );
            feeBps = _resolveFeeBps(feeData, executionHash);
        }

        // Snapshot balances before Weiroll execution
        uint256[] memory balancesBefore = new uint256[](outputs.length);
        for (uint256 i = 0; i < outputs.length; i++) {
            balancesBefore[i] = _getBalanceBefore(outputs[i].token);
        }

        // Execute the Weiroll program
        _execute(commands, state);

        // Compute deltas and transfer outputs
        actualAmounts = new uint256[](outputs.length);

        for (uint256 i = 0; i < outputs.length; i++) {
            address token = outputs[i].token;
            uint256 balanceAfter = _getBalance(token);
            uint256 produced = balanceAfter - balancesBefore[i];

            actualAmounts[i] = _transferOutput(token, produced, outputs[i].minAmount, feeBps, receiver, _feeRecipient);
        }

        emit Executed(msg.sender, receiver, outputs.length, actualAmounts);
    }

    /**
     * @notice Execute a Weiroll program with a single output verification (gas optimized)
     * @param commands The Weiroll command sequence
     * @param state The initial state array for Weiroll execution
     * @param outputToken The expected output token address
     * @param minAmountOut Minimum acceptable output amount
     * @param receiver Address to receive the output token
     * @param feeData Empty for default fee, or encoded (feeBps, deadline, signature) for signed override
     * @return actualAmount The actual amount transferred
     */
    function executeSingle(
        bytes32[] calldata commands,
        bytes[] calldata state,
        address outputToken,
        uint256 minAmountOut,
        address receiver,
        bytes calldata feeData
    ) external payable nonReentrant returns (uint256 actualAmount) {
        // Cache feeRecipient from storage (packed with defaultFeeBps, 1 SLOAD)
        address _feeRecipient = feeRecipient;

        // Resolve fee
        uint256 feeBps;
        if (feeData.length == 0) {
            feeBps = defaultFeeBps;
        } else {
            bytes32 executionHash = keccak256(
                abi.encode(
                    keccak256(abi.encode(commands)),
                    keccak256(abi.encode(state)),
                    keccak256(abi.encode(outputToken, minAmountOut)),
                    receiver
                )
            );
            feeBps = _resolveFeeBps(feeData, executionHash);
        }

        // Snapshot balance before Weiroll execution
        uint256 balanceBefore = _getBalanceBefore(outputToken);

        // Execute the Weiroll program
        _execute(commands, state);

        // Compute delta and transfer
        uint256 balanceAfter = _getBalance(outputToken);
        uint256 produced = balanceAfter - balanceBefore;

        actualAmount = _transferOutput(outputToken, produced, minAmountOut, feeBps, receiver, _feeRecipient);

        // Emit with single output
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = actualAmount;
        emit Executed(msg.sender, receiver, 1, amounts);
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract
     * @dev Only callable by owner when contract has leftover tokens
     * @param token The token to rescue (use NATIVE_ETH for ETH)
     * @param to The address to send rescued tokens to
     * @param amount The amount to rescue
     */
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (token == NATIVE_ETH) {
            (bool success,) = to.call{ value: amount }("");
            if (!success) {
                revert ETHTransferFailed();
            }
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @notice Set the default fee in basis points
     * @param _feeBps The new default fee (must be <= MAX_FEE_BPS)
     */
    function setDefaultFeeBps(uint96 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeExceedsMax(_feeBps);
        uint96 old = defaultFeeBps;
        defaultFeeBps = _feeBps;
        emit DefaultFeeBpsUpdated(old, _feeBps);
    }

    /**
     * @notice Set the fee recipient address
     * @param _feeRecipient The new fee recipient (address(0) disables fee collection)
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        address old = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(old, _feeRecipient);
    }

    /**
     * @notice Set the fee signer address
     * @param _feeSigner The new fee signer (address(0) disables signed overrides)
     */
    function setFeeSigner(address _feeSigner) external onlyOwner {
        address old = feeSigner;
        feeSigner = _feeSigner;
        emit FeeSignerUpdated(old, _feeSigner);
    }

    /**
     * @notice Receive ETH for wrap/unwrap operations
     */
    receive() external payable { }

    /**
     * @notice Fallback to receive ETH
     */
    fallback() external payable { }

    // ============================================================
    // Internal Helpers
    // ============================================================

    /// @notice Get the current balance of a token held by this contract
    function _getBalance(address token) internal view returns (uint256) {
        if (token == NATIVE_ETH) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }

    /// @notice Get the balance before Weiroll execution, excluding msg.value for ETH
    function _getBalanceBefore(address token) internal view returns (uint256) {
        if (token == NATIVE_ETH) {
            return address(this).balance - msg.value;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }

    /// @notice Resolve the fee basis points from feeData
    function _resolveFeeBps(bytes calldata feeData, bytes32 executionHash) internal view returns (uint256) {
        (uint256 feeBps, uint256 deadline, bytes memory signature) = abi.decode(feeData, (uint256, uint256, bytes));

        if (block.timestamp > deadline) revert FeeSignatureExpired();
        if (feeBps > MAX_FEE_BPS) revert FeeExceedsMax(feeBps);

        bytes32 structHash = keccak256(abi.encode(FEE_OVERRIDE_TYPEHASH, feeBps, deadline, msg.sender, executionHash));
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, signature);

        if (recovered != feeSigner || recovered == address(0)) revert InvalidFeeSignature();

        return feeBps;
    }

    /// @notice Transfer output to receiver with fee deduction
    function _transferOutput(
        address token,
        uint256 produced,
        uint256 minAmount,
        uint256 feeBps,
        address receiver,
        address _feeRecipient
    ) internal returns (uint256 receiverAmount) {
        uint256 feeAmount;
        if (_feeRecipient != address(0) && feeBps > 0) {
            feeAmount = (produced * feeBps) / 10000;
        }
        receiverAmount = produced - feeAmount;

        // Slippage check (post-fee)
        if (receiverAmount < minAmount) revert SlippageExceeded(token, receiverAmount, minAmount);

        // Transfer fee first (trusted feeRecipient), then receiver
        if (feeAmount > 0) {
            if (token == NATIVE_ETH) {
                (bool success,) = _feeRecipient.call{ value: feeAmount }("");
                if (!success) revert ETHTransferFailed();
            } else {
                IERC20(token).safeTransfer(_feeRecipient, feeAmount);
            }
        }

        // Transfer to receiver
        if (receiverAmount > 0) {
            if (token == NATIVE_ETH) {
                (bool success,) = receiver.call{ value: receiverAmount }("");
                if (!success) revert ETHTransferFailed();
            } else {
                IERC20(token).safeTransfer(receiver, receiverAmount);
            }
        }
    }
}
