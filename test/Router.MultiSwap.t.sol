// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { Router } from "../src/Router.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";
import { MockDEX } from "./mocks/MockDEX.sol";

/// @title MockERC20
/// @notice Minimal ERC20 for testing. Duplicated from Router.t.sol/Router.Fees.t.sol to keep
///         this file self-contained (task step 1 explicitly permits duplicating minimal setUp).
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @title RouterMultiSwapTest
/// @notice Covers FR-2 and the multi-swap rows of the spec's Error Handling and Edge Cases
///         tables: N-to-M happy path, native ETH as one of multiple inputs, pairwise duplicate
///         detection, input/output intersection, array-length parity, zero-amount checks,
///         pro-rata protocol fee distribution, per-output partner fee on outputs, and per-output
///         slippage enforcement (one of M outputs below its outputMin reverts the entire tx).
contract RouterMultiSwapTest is Test {
    ExecutionProxy public executor;
    Router public router;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockERC20 public tokenD;
    MockDEX public dex;

    address public user = makeAddr("user");
    address public receiver = makeAddr("receiver");
    address public alice = makeAddr("alice"); // partner recipient
    address public liquidator = makeAddr("liquidator");

    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Mirror of Router's `Swap` event so `vm.expectEmit` can compare structurally.
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

    function setUp() public {
        executor = new ExecutionProxy();
        router = new Router(address(this), liquidator);
        router.setPendingExecutor(address(executor));
        router.acceptExecutor();

        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenC = new MockERC20("Token C", "TKNC", 18);
        tokenD = new MockERC20("Token D", "TKND", 18);
        dex = new MockDEX();

        vm.deal(user, 100 ether);
    }

    // ------------------------------------------------------------------
    // Weiroll program builders
    // ------------------------------------------------------------------

    /// @dev Build a Weiroll program that runs two MockDEX swaps back-to-back: tokenIn0 -> tokenOut0
    ///      and tokenIn1 -> tokenOut1, then transfers each output from the executor to the Router so
    ///      the multi-swap balance-diff picks both outputs up. `forward0`/`forward1` are the
    ///      executor's actual received input amounts (i.e. `inputAmount - protocolFee - inputPartnerFee`).
    function _build2In2OutSwapProgram(
        address tokenIn0,
        address tokenIn1,
        uint256 forward0,
        uint256 forward1,
        address tokenOut0,
        address tokenOut1,
        uint256 amtOut0,
        uint256 amtOut1
    ) internal view returns (bytes32[] memory commands, bytes[] memory state) {
        // State (10 slots):
        // 0: router (transfer destination)
        // 1: dex
        // 2: tokenIn0   3: tokenIn1
        // 4: tokenOut0  5: tokenOut1
        // 6: forward0   7: forward1
        // 8: amtOut0    9: amtOut1
        state = new bytes[](10);
        state[0] = WeirollTestHelper.encodeAddress(address(router));
        state[1] = WeirollTestHelper.encodeAddress(address(dex));
        state[2] = WeirollTestHelper.encodeAddress(tokenIn0);
        state[3] = WeirollTestHelper.encodeAddress(tokenIn1);
        state[4] = WeirollTestHelper.encodeAddress(tokenOut0);
        state[5] = WeirollTestHelper.encodeAddress(tokenOut1);
        state[6] = WeirollTestHelper.encodeUint256(forward0);
        state[7] = WeirollTestHelper.encodeUint256(forward1);
        state[8] = WeirollTestHelper.encodeUint256(amtOut0);
        state[9] = WeirollTestHelper.encodeUint256(amtOut1);

        bytes4 swapSel = bytes4(keccak256("swap(address,address,uint256,uint256)"));
        commands = new bytes32[](6);
        commands[0] = WeirollTestHelper.buildApproveCommand(tokenIn0, 1, 6);
        commands[1] = WeirollTestHelper.buildCallFourArgs(address(dex), swapSel, 2, 4, 6, 8);
        commands[2] = WeirollTestHelper.buildApproveCommand(tokenIn1, 1, 7);
        commands[3] = WeirollTestHelper.buildCallFourArgs(address(dex), swapSel, 3, 5, 7, 9);
        commands[4] = WeirollTestHelper.buildTransferCommand(tokenOut0, 0, 8);
        commands[5] = WeirollTestHelper.buildTransferCommand(tokenOut1, 0, 9);
    }

    /// @dev Build a Weiroll program that mints `amt0` of `out0` and `amt1` of `out1` directly to
    ///      the Router. Used for tests where we only care about the multi-swap output settlement
    ///      logic (per-output slippage, native-ETH input forwarding) and not the executor's
    ///      consumption of the input tokens.
    function _buildMultiMintProgram(address out0, address out1, uint256 amt0, uint256 amt1)
        internal
        view
        returns (bytes32[] memory commands, bytes[] memory state)
    {
        state = new bytes[](5);
        state[0] = WeirollTestHelper.encodeAddress(address(router));
        state[1] = WeirollTestHelper.encodeAddress(out0);
        state[2] = WeirollTestHelper.encodeAddress(out1);
        state[3] = WeirollTestHelper.encodeUint256(amt0);
        state[4] = WeirollTestHelper.encodeUint256(amt1);

        commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildMintCommand(out0, 0, 3);
        commands[1] = WeirollTestHelper.buildMintCommand(out1, 0, 4);
    }

    /// @dev Default-filled MultiSwapParams builder. All test-only fields default to zero/false;
    ///      callers override the specific field under test.
    function _mkParams(
        address[] memory inputTokens,
        uint256[] memory inputAmounts,
        address[] memory outputTokens,
        uint256[] memory outputQuotes,
        uint256[] memory outputMins,
        bytes32[] memory commands,
        bytes[] memory state
    ) internal view returns (Router.MultiSwapParams memory p) {
        p = Router.MultiSwapParams({
            inputTokens: inputTokens,
            inputAmounts: inputAmounts,
            outputTokens: outputTokens,
            outputQuotes: outputQuotes,
            outputMins: outputMins,
            recipient: receiver,
            protocolFeeBps: 0,
            partnerFeeBps: 0,
            partnerRecipient: address(0),
            partnerFeeOnOutput: false,
            passPositiveSlippageToUser: false,
            weirollCommands: commands,
            weirollState: state
        });
    }

    // ==================================================================
    // Happy paths (FR-2)
    // ==================================================================

    /// @notice Two-input, two-output atomic swap with no fees. Asserts each output lands at the
    ///         recipient, the Router holds zero residual of each token, and one Swap event is
    ///         emitted per output (FR-17 shape preserved).
    function test_MultiSwap_TwoInTwoOut() public {
        uint256 amtA = 1000e18;
        uint256 amtB = 500e18;
        uint256 outC = 1000e18;
        uint256 outD = 500e18;

        tokenA.mint(user, amtA);
        tokenB.mint(user, amtB);
        vm.startPrank(user);
        tokenA.approve(address(router), amtA);
        tokenB.approve(address(router), amtB);
        vm.stopPrank();

        address[] memory inputs = new address[](2);
        inputs[0] = address(tokenA);
        inputs[1] = address(tokenB);
        uint256[] memory inAmts = new uint256[](2);
        inAmts[0] = amtA;
        inAmts[1] = amtB;
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenC);
        outputs[1] = address(tokenD);
        uint256[] memory quotes = new uint256[](2);
        quotes[0] = outC;
        quotes[1] = outD;
        uint256[] memory mins = new uint256[](2);
        mins[0] = 900e18;
        mins[1] = 400e18;

        (bytes32[] memory commands, bytes[] memory state) = _build2In2OutSwapProgram(
            address(tokenA), address(tokenB), amtA, amtB, address(tokenC), address(tokenD), outC, outD
        );

        Router.MultiSwapParams memory p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);

        // Two Swap events expected, in output index order. effectiveInputToken=inputs[0]=A,
        // inputAmountSum = sum(inputAmounts) = 1500e18. No fees, no slippage.
        vm.expectEmit(true, false, false, true, address(router));
        emit Swap(user, address(tokenA), 1500e18, address(tokenC), outC, outC, 0, 0, 0, address(0));
        vm.expectEmit(true, false, false, true, address(router));
        emit Swap(user, address(tokenA), 1500e18, address(tokenD), outD, outD, 0, 0, 0, address(0));

        vm.prank(user);
        uint256[] memory amountsOut = router.swapMulti(p);

        assertEq(amountsOut.length, 2, "amountsOut length");
        assertEq(amountsOut[0], outC, "amountsOut[0]");
        assertEq(amountsOut[1], outD, "amountsOut[1]");
        assertEq(tokenC.balanceOf(receiver), outC, "receiver C");
        assertEq(tokenD.balanceOf(receiver), outD, "receiver D");
        assertEq(tokenA.balanceOf(address(router)), 0, "router 0 A");
        assertEq(tokenB.balanceOf(address(router)), 0, "router 0 B");
        assertEq(tokenC.balanceOf(address(router)), 0, "router 0 C");
        assertEq(tokenD.balanceOf(address(router)), 0, "router 0 D");
    }

    /// @notice Native ETH as one of two inputs. Asserts msg.value is forwarded to the executor on
    ///         the unified executePath call (executor's ETH balance increases by the forwarded
    ///         amount) and at least one output is produced and delivered to the recipient.
    function test_MultiSwap_WithNativeETH_AsOneInput() public {
        uint256 ethAmt = 1 ether;
        uint256 amtA = 1000e18;
        uint256 outC = 1000e18;
        uint256 outD = 500e18;

        tokenA.mint(user, amtA);
        vm.prank(user);
        tokenA.approve(address(router), amtA);

        Router.MultiSwapParams memory p = _buildNativeEthMultiParams(ethAmt, amtA, outC, outD);

        uint256 executorEthBefore = address(executor).balance;
        uint256 executorTokenABefore = tokenA.balanceOf(address(executor));

        vm.prank(user);
        uint256[] memory amountsOut = router.swapMulti{ value: ethAmt }(p);

        assertEq(amountsOut[0], outC, "amountsOut C");
        assertEq(amountsOut[1], outD, "amountsOut D");
        assertEq(tokenC.balanceOf(receiver), outC, "receiver C");
        assertEq(tokenD.balanceOf(receiver), outD, "receiver D");
        // msg.value was forwarded (program did not consume ETH; executor balance reflects forward).
        assertEq(address(executor).balance - executorEthBefore, ethAmt, "executor received msg.value");
        // ERC20 input was forwarded via safeTransfer to executor on the same call.
        assertEq(tokenA.balanceOf(address(executor)) - executorTokenABefore, amtA, "executor received tokenA");
        // Router holds no ETH residual after forwarding.
        assertEq(address(router).balance, 0, "router 0 ETH");
    }

    /// @dev Extracted to keep the native-ETH-input multi-swap test body under the EVM stack limit.
    function _buildNativeEthMultiParams(uint256 ethAmt, uint256 amtA, uint256 outC, uint256 outD)
        internal
        view
        returns (Router.MultiSwapParams memory p)
    {
        address[] memory inputs = new address[](2);
        inputs[0] = NATIVE_ETH;
        inputs[1] = address(tokenA);
        uint256[] memory inAmts = new uint256[](2);
        inAmts[0] = ethAmt;
        inAmts[1] = amtA;
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenC);
        outputs[1] = address(tokenD);
        uint256[] memory quotes = new uint256[](2);
        quotes[0] = outC;
        quotes[1] = outD;
        uint256[] memory mins = new uint256[](2);
        mins[0] = 900e18;
        mins[1] = 400e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMultiMintProgram(address(tokenC), address(tokenD), outC, outD);

        p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);
    }

    // ==================================================================
    // Duplicate / intersection rejection (FR-8)
    // ==================================================================

    /// @notice Duplicate token in the inputs array reverts DuplicateToken with the offending token.
    function test_MultiSwap_DuplicateInput_Reverts() public {
        address[] memory inputs = new address[](2);
        inputs[0] = address(tokenA);
        inputs[1] = address(tokenA);
        uint256[] memory inAmts = new uint256[](2);
        inAmts[0] = 1000e18;
        inAmts[1] = 1000e18;
        address[] memory outputs = new address[](1);
        outputs[0] = address(tokenC);
        uint256[] memory quotes = new uint256[](1);
        quotes[0] = 900e18;
        uint256[] memory mins = new uint256[](1);
        mins[0] = 800e18;

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        Router.MultiSwapParams memory p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Router.DuplicateToken.selector, address(tokenA)));
        router.swapMulti(p);
    }

    /// @notice Duplicate token in the outputs array reverts DuplicateToken with the offending token.
    function test_MultiSwap_DuplicateOutput_Reverts() public {
        address[] memory inputs = new address[](1);
        inputs[0] = address(tokenA);
        uint256[] memory inAmts = new uint256[](1);
        inAmts[0] = 1000e18;
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenC);
        outputs[1] = address(tokenC);
        uint256[] memory quotes = new uint256[](2);
        quotes[0] = 900e18;
        quotes[1] = 900e18;
        uint256[] memory mins = new uint256[](2);
        mins[0] = 800e18;
        mins[1] = 800e18;

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        Router.MultiSwapParams memory p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Router.DuplicateToken.selector, address(tokenC)));
        router.swapMulti(p);
    }

    /// @notice Same token appearing in both inputs and outputs reverts InputOutputIntersection
    ///         with the offending token.
    function test_MultiSwap_InputOutputIntersection_Reverts() public {
        address[] memory inputs = new address[](1);
        inputs[0] = address(tokenA);
        uint256[] memory inAmts = new uint256[](1);
        inAmts[0] = 1000e18;
        address[] memory outputs = new address[](1);
        outputs[0] = address(tokenA);
        uint256[] memory quotes = new uint256[](1);
        quotes[0] = 900e18;
        uint256[] memory mins = new uint256[](1);
        mins[0] = 800e18;

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        Router.MultiSwapParams memory p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Router.InputOutputIntersection.selector, address(tokenA)));
        router.swapMulti(p);
    }

    // ==================================================================
    // Array length + zero validation
    // ==================================================================

    /// @notice inputAmounts.length != inputTokens.length reverts ArrayLengthMismatch.
    function test_MultiSwap_ArrayLengthMismatch_Reverts() public {
        address[] memory inputs = new address[](1);
        inputs[0] = address(tokenA);
        uint256[] memory inAmts = new uint256[](2);
        inAmts[0] = 1000e18;
        inAmts[1] = 500e18;
        address[] memory outputs = new address[](1);
        outputs[0] = address(tokenC);
        uint256[] memory quotes = new uint256[](1);
        quotes[0] = 900e18;
        uint256[] memory mins = new uint256[](1);
        mins[0] = 800e18;

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        Router.MultiSwapParams memory p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);

        vm.prank(user);
        vm.expectRevert(Router.ArrayLengthMismatch.selector);
        router.swapMulti(p);
    }

    /// @notice Empty inputs array reverts ZeroInputAmount per the spec's Error Handling table.
    function test_MultiSwap_EmptyInputs_Reverts() public {
        address[] memory inputs = new address[](0);
        uint256[] memory inAmts = new uint256[](0);
        address[] memory outputs = new address[](1);
        outputs[0] = address(tokenC);
        uint256[] memory quotes = new uint256[](1);
        quotes[0] = 900e18;
        uint256[] memory mins = new uint256[](1);
        mins[0] = 800e18;

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        Router.MultiSwapParams memory p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);

        vm.prank(user);
        vm.expectRevert(Router.ZeroInputAmount.selector);
        router.swapMulti(p);
    }

    /// @notice Empty outputs array reverts ZeroOutputQuote per the spec's Error Handling table.
    function test_MultiSwap_EmptyOutputs_Reverts() public {
        address[] memory inputs = new address[](1);
        inputs[0] = address(tokenA);
        uint256[] memory inAmts = new uint256[](1);
        inAmts[0] = 1000e18;
        address[] memory outputs = new address[](0);
        uint256[] memory quotes = new uint256[](0);
        uint256[] memory mins = new uint256[](0);

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        Router.MultiSwapParams memory p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);

        vm.prank(user);
        vm.expectRevert(Router.ZeroOutputQuote.selector);
        router.swapMulti(p);
    }

    /// @notice Any zero entry in the inputAmounts array reverts ZeroInputAmount.
    function test_MultiSwap_ZeroAmountInput_Reverts() public {
        address[] memory inputs = new address[](2);
        inputs[0] = address(tokenA);
        inputs[1] = address(tokenB);
        uint256[] memory inAmts = new uint256[](2);
        inAmts[0] = 1000e18;
        inAmts[1] = 0; // zero amount
        address[] memory outputs = new address[](1);
        outputs[0] = address(tokenC);
        uint256[] memory quotes = new uint256[](1);
        quotes[0] = 900e18;
        uint256[] memory mins = new uint256[](1);
        mins[0] = 800e18;

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        Router.MultiSwapParams memory p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);

        vm.prank(user);
        vm.expectRevert(Router.ZeroInputAmount.selector);
        router.swapMulti(p);
    }

    // ==================================================================
    // Pro-rata fee tests (FR-3 / FR-4 / FR-5 in multi-swap form)
    // ==================================================================

    /// @notice 200 bps protocol fee on two equal-size inputs. Each input contributes its own
    ///         proportional fee retained on the Router in its own token (per-token retention,
    ///         no token mixing). Exercises the multi-swap pro-rata accumulation in `_pullInputs`.
    function test_MultiSwap_ProRataProtocolFee() public {
        uint256 amtIn = 1000e18;
        uint256 forward = 980e18; // 1000 - 2%
        uint256 outC = 900e18;
        uint256 outD = 900e18;

        tokenA.mint(user, amtIn);
        tokenB.mint(user, amtIn);
        vm.startPrank(user);
        tokenA.approve(address(router), amtIn);
        tokenB.approve(address(router), amtIn);
        vm.stopPrank();

        address[] memory inputs = new address[](2);
        inputs[0] = address(tokenA);
        inputs[1] = address(tokenB);
        uint256[] memory inAmts = new uint256[](2);
        inAmts[0] = amtIn;
        inAmts[1] = amtIn;
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenC);
        outputs[1] = address(tokenD);
        uint256[] memory quotes = new uint256[](2);
        quotes[0] = 1000e18;
        quotes[1] = 1000e18;
        uint256[] memory mins = new uint256[](2);
        mins[0] = 800e18;
        mins[1] = 800e18;

        (bytes32[] memory commands, bytes[] memory state) = _build2In2OutSwapProgram(
            address(tokenA), address(tokenB), forward, forward, address(tokenC), address(tokenD), outC, outD
        );

        Router.MultiSwapParams memory p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);
        p.protocolFeeBps = 200;

        vm.prank(user);
        router.swapMulti(p);

        // Each input's protocol-fee share retained per-token in its own balance slot: 20e18 each.
        assertEq(tokenA.balanceOf(address(router)), 20e18, "router retains 2% of A");
        assertEq(tokenB.balanceOf(address(router)), 20e18, "router retains 2% of B");
        // Receiver gets each output in full.
        assertEq(tokenC.balanceOf(receiver), outC, "receiver C");
        assertEq(tokenD.balanceOf(receiver), outD, "receiver D");
        // Executor holds nothing (consumed by MockDEX swap calls).
        assertEq(tokenA.balanceOf(address(executor)), 0, "executor 0 A");
        assertEq(tokenB.balanceOf(address(executor)), 0, "executor 0 B");
    }

    /// @notice Output-side partner fee with two outputs of different sizes. Per-output attribution:
    ///         outputs [1000e18, 500e18] with 100 bps -> partner receives 10e18 of C and 5e18 of D.
    ///         Exercises the per-output partner-fee branch in `_settleOutputs`.
    function test_MultiSwap_ProRataPartnerFee_OnOutput() public {
        uint256 amtA = 1000e18;
        uint256 amtB = 500e18;
        uint256 outC = 1000e18;
        uint256 outD = 500e18;

        tokenA.mint(user, amtA);
        tokenB.mint(user, amtB);
        vm.startPrank(user);
        tokenA.approve(address(router), amtA);
        tokenB.approve(address(router), amtB);
        vm.stopPrank();

        address[] memory inputs = new address[](2);
        inputs[0] = address(tokenA);
        inputs[1] = address(tokenB);
        uint256[] memory inAmts = new uint256[](2);
        inAmts[0] = amtA;
        inAmts[1] = amtB;
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenC);
        outputs[1] = address(tokenD);
        uint256[] memory quotes = new uint256[](2);
        quotes[0] = outC;
        quotes[1] = outD;
        uint256[] memory mins = new uint256[](2);
        mins[0] = 900e18;
        mins[1] = 400e18;

        (bytes32[] memory commands, bytes[] memory state) = _build2In2OutSwapProgram(
            address(tokenA), address(tokenB), amtA, amtB, address(tokenC), address(tokenD), outC, outD
        );

        Router.MultiSwapParams memory p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);
        p.partnerFeeBps = 100;
        p.partnerFeeOnOutput = true;
        p.partnerRecipient = alice;

        vm.prank(user);
        router.swapMulti(p);

        // Partner's per-output share: 1% of each post-cap amountOut, in each output's own token.
        assertEq(tokenC.balanceOf(alice), 10e18, "partner C");
        assertEq(tokenD.balanceOf(alice), 5e18, "partner D");
        // Receiver gets outputs net of partner fees.
        assertEq(tokenC.balanceOf(receiver), 990e18, "receiver C net");
        assertEq(tokenD.balanceOf(receiver), 495e18, "receiver D net");
    }

    /// @notice One of M outputs falls below its outputMin -> entire tx reverts SlippageExceeded
    ///         with the offending output token, the produced amount, and the per-output min.
    ///         Atomicity: even though output[0] would have passed its own min, the whole swap is
    ///         rolled back because output[1] failed.
    function test_MultiSwap_PerOutputSlippage() public {
        uint256 amtA = 1000e18;
        tokenA.mint(user, amtA);
        vm.prank(user);
        tokenA.approve(address(router), amtA);

        address[] memory inputs = new address[](1);
        inputs[0] = address(tokenA);
        uint256[] memory inAmts = new uint256[](1);
        inAmts[0] = amtA;
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenC);
        outputs[1] = address(tokenD);
        uint256[] memory quotes = new uint256[](2);
        quotes[0] = 1000e18;
        quotes[1] = 1000e18;
        uint256[] memory mins = new uint256[](2);
        mins[0] = 800e18; // C produces 900e18 -> passes
        mins[1] = 800e18; // D produces 700e18 -> fails

        // Multi-mint program: 900e18 of C (passes its min), 700e18 of D (below its min).
        (bytes32[] memory commands, bytes[] memory state) =
            _buildMultiMintProgram(address(tokenC), address(tokenD), 900e18, 700e18);

        Router.MultiSwapParams memory p = _mkParams(inputs, inAmts, outputs, quotes, mins, commands, state);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(Router.SlippageExceeded.selector, address(tokenD), uint256(700e18), uint256(800e18))
        );
        router.swapMulti(p);
    }
}
