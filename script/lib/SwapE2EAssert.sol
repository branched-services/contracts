// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";

import { Router } from "../../src/Router.sol";

/// @title SwapE2EAssert
/// @notice Helpers for `script/SwapTestnetE2E.s.sol`: scans Forge-recorded logs for the
///         Router's `Swap` event, asserts the post-swap event fields against the params
///         used at the call site, and produces the Permit2 EIP-712 single-token digest.
///         Mirrors the typehash + signing shape from `test/Router.Permit2.t.sol` so the
///         Permit2 verifier sees an identical structHash regardless of test/script context.
library SwapE2EAssert {
    address internal constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant SWAP_TOPIC0 =
        keccak256("Swap(address,address,uint256,address,uint256,uint256,uint256,uint256,uint256,address)");

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 internal constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    /// @notice Decoded Router `Swap` event. Field order matches `Router.sol`'s emit-site
    ///         declaration (`src/Router.sol:148-159`).
    struct SwapEvent {
        address sender;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 amountOut;
        uint256 amountToUser;
        uint256 protocolFee;
        uint256 partnerFee;
        uint256 positiveSlippageCaptured;
        address partnerRecipient;
    }

    /// @notice Linear scan of the recorded log buffer for the first `Swap` emitted by
    ///         `routerAddr`. Reverts if no match is found so the broadcast errors out.
    function findSwap(Vm.Log[] memory logs, address routerAddr) internal pure returns (SwapEvent memory ev) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != routerAddr || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != SWAP_TOPIC0) continue;
            ev.sender = address(uint160(uint256(logs[i].topics[1])));
            (
                ev.inputToken,
                ev.inputAmount,
                ev.outputToken,
                ev.amountOut,
                ev.amountToUser,
                ev.protocolFee,
                ev.partnerFee,
                ev.positiveSlippageCaptured,
                ev.partnerRecipient
            ) =
                abi.decode(
                    logs[i].data, (address, uint256, address, uint256, uint256, uint256, uint256, uint256, address)
                );
            return ev;
        }
        revert("Swap event not found in receipt");
    }

    /// @notice Common assertions every leg shares: slippage floor and exact protocol/partner
    ///         fee match. Slippage-leg-specific positive-slippage check stays at the call site.
    function baseAssert(SwapEvent memory ev, Router.SwapParams memory p) internal pure {
        require(ev.amountToUser >= p.outputMin, "amountToUser < outputMin");
        uint256 expectedProtocol = (p.inputAmount * p.protocolFeeBps) / 10_000;
        uint256 expectedInputPartner = p.partnerFeeOnOutput ? 0 : (p.inputAmount * p.partnerFeeBps) / 10_000;
        require(ev.protocolFee == expectedProtocol, "protocolFee mismatch");
        require(ev.partnerFee == expectedInputPartner, "partnerFee mismatch");
    }

    /// @notice console2-tagged dump of decoded Swap event fields. Operator pastes these
    ///         lines into the evidence file alongside the broadcast tx hash.
    function logEvent(string memory tag, SwapEvent memory ev) internal pure {
        console2.log(tag, "amountToUser", ev.amountToUser);
        console2.log(tag, "amountOut", ev.amountOut);
        console2.log(tag, "protocolFee", ev.protocolFee);
        console2.log(tag, "partnerFee", ev.partnerFee);
        console2.log(tag, "positiveSlippageCaptured", ev.positiveSlippageCaptured);
    }

    /// @notice EIP-712 digest for `ISignatureTransfer.PermitTransferFrom` over a single
    ///         token. Spender is the Router (which calls Permit2 in `swapPermit2`).
    function permit2SingleDigest(address token, uint256 amount, uint256 nonce, uint256 deadline, address spender)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = ISignatureTransfer(PERMIT2_ADDR).DOMAIN_SEPARATOR();
        bytes32 tokenPerm = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, token, amount));
        bytes32 structHash = keccak256(abi.encode(PERMIT_TRANSFER_FROM_TYPEHASH, tokenPerm, spender, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }
}
