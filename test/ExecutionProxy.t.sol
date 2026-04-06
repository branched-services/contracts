// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";
import { MockDEX } from "./mocks/MockDEX.sol";
import { FeeOnTransferToken, RebasingToken, CallbackToken, FalseReturningToken } from "./mocks/AdversarialTokens.sol";
import { ReentrantReceiver } from "./mocks/ReentrantReceiver.sol";

/// @title MockERC20
/// @notice Minimal ERC20 for testing
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

/// @title MockWETH
/// @notice Minimal WETH for testing
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) { }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        payable(msg.sender).transfer(amount);
        emit Transfer(msg.sender, address(0), amount);
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }
}

/// @title ExecutionProxyTest
/// @notice Tests for the ExecutionProxy contract
contract ExecutionProxyTest is Test {
    ExecutionProxy public proxy;
    MockWETH public weth;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    address public user = makeAddr("user");
    address public receiver = makeAddr("receiver");

    // Fee signer for tests
    uint256 internal feeSignerPk = 0xBEEF;
    address internal feeSignerAddr;

    function setUp() public {
        feeSignerAddr = vm.addr(feeSignerPk);

        weth = new MockWETH();
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenC = new MockERC20("Token C", "TKNC", 6);

        // Deploy proxy (test contract is owner, no fee by default)
        proxy = new ExecutionProxy(address(this), address(0), 0, address(0));

        vm.deal(user, 100 ether);
    }

    // ============================================================
    // Weiroll mint helper: builds commands/state to mint tokens to proxy during execution
    // ============================================================

    function _buildMintProgram(address token, uint256 amount)
        internal
        view
        returns (bytes32[] memory commands, bytes[] memory state)
    {
        state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(proxy)), WeirollTestHelper.encodeUint256(amount)
        );
        commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(token, 0, 1);
    }

    function _buildMintProgramForProxy(ExecutionProxy _proxy, address token, uint256 amount)
        internal
        pure
        returns (bytes32[] memory commands, bytes[] memory state)
    {
        state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(_proxy)), WeirollTestHelper.encodeUint256(amount)
        );
        commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(token, 0, 1);
    }

    // ============================================================
    // Fee signing helpers
    // ============================================================

    function _signFeeOverrideForProxy(
        ExecutionProxy _proxy,
        uint256 signerPk,
        uint256 feeBps,
        uint256 deadline,
        address caller,
        bytes32 executionHash
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(_proxy.FEE_OVERRIDE_TYPEHASH(), feeBps, deadline, caller, executionHash)
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ExecutionProxy")),
                keccak256(bytes("1")),
                block.chainid,
                address(_proxy)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        return abi.encode(feeBps, deadline, signature);
    }

    function _computeExecutionHashSingle(
        bytes32[] memory commands,
        bytes[] memory state,
        address outputToken,
        uint256 minAmountOut,
        address _receiver
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(abi.encode(commands)),
                keccak256(abi.encode(state)),
                keccak256(abi.encode(outputToken, minAmountOut)),
                _receiver
            )
        );
    }

    function _computeExecutionHashMulti(
        bytes32[] memory commands,
        bytes[] memory state,
        ExecutionProxy.OutputSpec[] memory outputs,
        address _receiver
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(abi.encode(commands)), keccak256(abi.encode(state)), keccak256(abi.encode(outputs)), _receiver
            )
        );
    }

    // ============================================================
    // Original Tests (updated for delta-based measurement)
    // ============================================================

    /// @notice Test that proxy deploys correctly
    function test_Deploy() public view {
        assertEq(proxy.NATIVE_ETH(), 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        assertEq(proxy.owner(), address(this));
        assertEq(proxy.feeRecipient(), address(0));
        assertEq(proxy.defaultFeeBps(), 0);
        assertEq(proxy.feeSigner(), address(0));
    }

    /// @notice Test single output verification passes when output >= minimum
    function test_ExecuteSingle_OutputVerificationPasses() public {
        uint256 outputAmount = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), outputAmount);

        uint256 actualAmount =
            proxy.executeSingle(commands, state, address(tokenA), outputAmount - 1, receiver, bytes(""));

        assertEq(actualAmount, outputAmount);
        assertEq(tokenA.balanceOf(receiver), outputAmount);
        assertEq(tokenA.balanceOf(address(proxy)), 0);
    }

    /// @notice Test single output verification fails when output < minimum (slippage exceeded)
    function test_ExecuteSingle_SlippageExceeded() public {
        uint256 outputAmount = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), outputAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionProxy.SlippageExceeded.selector, address(tokenA), outputAmount, outputAmount + 1
            )
        );
        proxy.executeSingle(commands, state, address(tokenA), outputAmount + 1, receiver, bytes(""));
    }

    /// @notice Test multi-output verification passes
    function test_Execute_MultiOutputVerificationPasses() public {
        uint256 amountA = 1000e18;
        uint256 amountB = 500e18;
        uint256 amountC = 250e6;

        // Build Weiroll: mint 3 tokens to proxy
        bytes[] memory state = new bytes[](7);
        state[0] = WeirollTestHelper.encodeAddress(address(proxy));
        state[1] = WeirollTestHelper.encodeUint256(amountA);
        state[2] = WeirollTestHelper.encodeUint256(amountB);
        state[3] = WeirollTestHelper.encodeUint256(amountC);
        // Unused padding for indices
        state[4] = WeirollTestHelper.encodeUint256(0);
        state[5] = WeirollTestHelper.encodeUint256(0);
        state[6] = WeirollTestHelper.encodeUint256(0);

        bytes32[] memory commands = new bytes32[](3);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildMintCommand(address(tokenB), 0, 2);
        commands[2] = WeirollTestHelper.buildMintCommand(address(tokenC), 0, 3);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](3);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: amountA - 1 });
        outputs[1] = ExecutionProxy.OutputSpec({ token: address(tokenB), minAmount: amountB - 1 });
        outputs[2] = ExecutionProxy.OutputSpec({ token: address(tokenC), minAmount: amountC - 1 });

        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));

        assertEq(actualAmounts.length, 3);
        assertEq(actualAmounts[0], amountA);
        assertEq(actualAmounts[1], amountB);
        assertEq(actualAmounts[2], amountC);

        assertEq(tokenA.balanceOf(receiver), amountA);
        assertEq(tokenB.balanceOf(receiver), amountB);
        assertEq(tokenC.balanceOf(receiver), amountC);
    }

    /// @notice Test multi-output verification fails on second output
    function test_Execute_MultiOutputSlippageExceededOnSecond() public {
        uint256 amountA = 1000e18;
        uint256 amountB = 500e18;

        bytes[] memory state = new bytes[](3);
        state[0] = WeirollTestHelper.encodeAddress(address(proxy));
        state[1] = WeirollTestHelper.encodeUint256(amountA);
        state[2] = WeirollTestHelper.encodeUint256(amountB);

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildMintCommand(address(tokenB), 0, 2);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](2);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: amountA });
        outputs[1] = ExecutionProxy.OutputSpec({ token: address(tokenB), minAmount: amountB + 1 });

        vm.expectRevert(
            abi.encodeWithSelector(ExecutionProxy.SlippageExceeded.selector, address(tokenB), amountB, amountB + 1)
        );
        proxy.execute(commands, state, outputs, receiver, bytes(""));
    }

    /// @notice Test that empty outputs array reverts
    function test_Execute_NoOutputsReverts() public {
        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);
        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](0);

        vm.expectRevert(ExecutionProxy.NoOutputsSpecified.selector);
        proxy.execute(commands, state, outputs, receiver, bytes(""));
    }

    /// @notice Test native ETH output transfer via msg.value
    function test_ExecuteSingle_NativeETHOutput() public {
        uint256 ethAmount = 1 ether;

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        uint256 receiverBalanceBefore = receiver.balance;

        // msg.value flows through as delta when Weiroll doesn't consume it
        uint256 actualAmount = proxy.executeSingle{ value: ethAmount }(
            commands, state, proxy.NATIVE_ETH(), ethAmount - 1, receiver, bytes("")
        );

        assertEq(actualAmount, ethAmount);
        assertEq(receiver.balance, receiverBalanceBefore + ethAmount);
        assertEq(address(proxy).balance, 0);
    }

    /// @notice Test native ETH slippage check
    function test_ExecuteSingle_NativeETHSlippageExceeded() public {
        uint256 ethAmount = 1 ether;

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        address nativeEth = proxy.NATIVE_ETH();
        vm.expectRevert(
            abi.encodeWithSelector(ExecutionProxy.SlippageExceeded.selector, nativeEth, ethAmount, ethAmount + 1)
        );
        proxy.executeSingle{ value: ethAmount }(commands, state, nativeEth, ethAmount + 1, receiver, bytes(""));
    }

    /// @notice Test rescue function for stuck tokens
    function test_Rescue() public {
        uint256 amount = 100e18;
        tokenA.mint(address(proxy), amount);

        address rescueTo = makeAddr("rescueTo");
        proxy.rescue(address(tokenA), rescueTo, amount);

        assertEq(tokenA.balanceOf(rescueTo), amount);
        assertEq(tokenA.balanceOf(address(proxy)), 0);
    }

    /// @notice Test rescue function for ETH
    function test_RescueETH() public {
        uint256 amount = 1 ether;
        vm.deal(address(proxy), amount);

        address rescueTo = makeAddr("rescueTo");
        uint256 balanceBefore = rescueTo.balance;

        proxy.rescue(proxy.NATIVE_ETH(), rescueTo, amount);

        assertEq(rescueTo.balance, balanceBefore + amount);
        assertEq(address(proxy).balance, 0);
    }

    /// @notice Test that rescue reverts for non-owner
    function test_Rescue_OnlyOwner() public {
        uint256 amount = 100e18;
        tokenA.mint(address(proxy), amount);

        address attacker = makeAddr("attacker");
        address rescueTo = makeAddr("rescueTo");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        proxy.rescue(address(tokenA), rescueTo, amount);

        assertEq(tokenA.balanceOf(address(proxy)), amount);
    }

    /// @notice Test receive function accepts ETH
    function test_ReceiveETH() public {
        uint256 amount = 1 ether;
        vm.deal(user, amount);

        vm.prank(user);
        (bool success,) = address(proxy).call{ value: amount }("");

        assertTrue(success);
        assertEq(address(proxy).balance, amount);
    }

    /// @notice Test Executed event is emitted correctly
    function test_ExecutedEventEmitted() public {
        uint256 amount = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), amount);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: amount });

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = amount;

        vm.expectEmit(true, true, false, true);
        emit ExecutionProxy.Executed(address(this), receiver, 1, expectedAmounts);

        proxy.execute(commands, state, outputs, receiver, bytes(""));
    }

    /// @notice Fuzz test for single output with varying amounts
    function testFuzz_ExecuteSingle(uint256 outputAmount, uint256 slippageBps) public {
        outputAmount = bound(outputAmount, 1, type(uint128).max);
        slippageBps = bound(slippageBps, 0, 10000);

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), outputAmount);

        uint256 minAmount = outputAmount * (10000 - slippageBps) / 10000;

        uint256 actualAmount = proxy.executeSingle(commands, state, address(tokenA), minAmount, receiver, bytes(""));

        assertEq(actualAmount, outputAmount);
        assertEq(tokenA.balanceOf(receiver), outputAmount);
    }

    // ============================================================
    // Fuzz and Invariant Tests (INF-0392)
    // ============================================================

    /// @notice Fuzz test executeSingle with real Weiroll program (approve + mint)
    function testFuzz_ExecuteSingle_WithWeirollApprove(uint256 amount, uint256 slippageBps) public {
        amount = bound(amount, 1, type(uint128).max);
        slippageBps = bound(slippageBps, 0, 10000);

        // Build Weiroll: mint to proxy, then approve receiver
        bytes[] memory state = WeirollTestHelper.createState3(
            WeirollTestHelper.encodeAddress(address(proxy)),
            WeirollTestHelper.encodeUint256(amount),
            WeirollTestHelper.encodeAddress(receiver)
        );

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildApproveCommand(address(tokenA), 2, 1);

        uint256 minAmount = (amount * (10000 - slippageBps)) / 10000;

        uint256 actualAmount = proxy.executeSingle(commands, state, address(tokenA), minAmount, receiver, bytes(""));

        assertEq(actualAmount, amount);
        assertEq(tokenA.balanceOf(receiver), amount);
        assertEq(tokenA.allowance(address(proxy), receiver), amount);
    }

    /// @notice Fuzz test execute with multiple outputs (1-5 tokens)
    function testFuzz_Execute_MultiOutput(uint256 seed, uint256 numOutputs) public {
        numOutputs = bound(numOutputs, 1, 5);

        MockERC20[] memory tokens = new MockERC20[](numOutputs);
        uint256[] memory amounts = new uint256[](numOutputs);

        for (uint256 i = 0; i < numOutputs; i++) {
            tokens[i] = new MockERC20(string(abi.encodePacked("Token", i)), string(abi.encodePacked("TKN", i)), 18);
            amounts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1e15, 1e24);
        }

        // Build Weiroll: mint each token to proxy
        bytes[] memory state = new bytes[](1 + numOutputs);
        state[0] = WeirollTestHelper.encodeAddress(address(proxy));
        for (uint256 i = 0; i < numOutputs; i++) {
            state[1 + i] = WeirollTestHelper.encodeUint256(amounts[i]);
        }

        bytes32[] memory commands = new bytes32[](numOutputs);
        for (uint256 i = 0; i < numOutputs; i++) {
            commands[i] = WeirollTestHelper.buildMintCommand(address(tokens[i]), 0, uint8(1 + i));
        }

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](numOutputs);
        for (uint256 i = 0; i < numOutputs; i++) {
            uint256 minAmount = (amounts[i] * 9900) / 10000;
            outputs[i] = ExecutionProxy.OutputSpec({ token: address(tokens[i]), minAmount: minAmount });
        }

        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));

        for (uint256 i = 0; i < numOutputs; i++) {
            assertEq(actualAmounts[i], amounts[i]);
            assertEq(tokens[i].balanceOf(receiver), amounts[i]);
            assertEq(tokens[i].balanceOf(address(proxy)), 0);
        }
    }

    /// @notice Fuzz test mixed ETH and token outputs
    function testFuzz_Execute_MixedOutputTypes(uint256 ethAmount, uint256 tokenAmount, bool ethFirst) public {
        ethAmount = bound(ethAmount, 1e15, 100 ether);
        tokenAmount = bound(tokenAmount, 1e15, 1e24);

        // Build Weiroll: mint tokenA to proxy (ETH comes via msg.value)
        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(proxy)), WeirollTestHelper.encodeUint256(tokenAmount)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](2);
        if (ethFirst) {
            outputs[0] = ExecutionProxy.OutputSpec({ token: proxy.NATIVE_ETH(), minAmount: ethAmount });
            outputs[1] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: tokenAmount });
        } else {
            outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: tokenAmount });
            outputs[1] = ExecutionProxy.OutputSpec({ token: proxy.NATIVE_ETH(), minAmount: ethAmount });
        }

        uint256 receiverEthBefore = receiver.balance;
        uint256[] memory actualAmounts =
            proxy.execute{ value: ethAmount }(commands, state, outputs, receiver, bytes(""));

        if (ethFirst) {
            assertEq(actualAmounts[0], ethAmount);
            assertEq(actualAmounts[1], tokenAmount);
        } else {
            assertEq(actualAmounts[0], tokenAmount);
            assertEq(actualAmounts[1], ethAmount);
        }

        assertEq(receiver.balance, receiverEthBefore + ethAmount);
        assertEq(tokenA.balanceOf(receiver), tokenAmount);
        assertEq(address(proxy).balance, 0);
        assertEq(tokenA.balanceOf(address(proxy)), 0);
    }

    /// @notice Fuzz test that proxy balance is always zero after successful execution (no pre-existing balance)
    function testFuzz_Invariant_ProxyBalanceZero(uint256 amount, bool useEth) public {
        amount = bound(amount, 1, type(uint128).max);

        if (useEth) {
            uint256 ethAmount = bound(amount, 1e15, 100 ether);
            bytes32[] memory commands = new bytes32[](0);
            bytes[] memory state = new bytes[](0);

            proxy.executeSingle{ value: ethAmount }(commands, state, proxy.NATIVE_ETH(), ethAmount, receiver, bytes(""));

            assertEq(address(proxy).balance, 0);
        } else {
            (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), amount);

            proxy.executeSingle(commands, state, address(tokenA), amount, receiver, bytes(""));

            assertEq(tokenA.balanceOf(address(proxy)), 0);
        }
    }

    /// @notice Fuzz test that receiver always gets the tokens after successful execution
    function testFuzz_Invariant_ReceiverGetsTokens(uint256 amount, address fuzzReceiver) public {
        amount = bound(amount, 1, type(uint128).max);
        vm.assume(fuzzReceiver != address(0));
        vm.assume(fuzzReceiver != address(proxy));
        vm.assume(fuzzReceiver.code.length == 0);

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), amount);

        uint256 receiverBalBefore = tokenA.balanceOf(fuzzReceiver);

        proxy.executeSingle(commands, state, address(tokenA), amount, fuzzReceiver, bytes(""));

        assertEq(tokenA.balanceOf(fuzzReceiver), receiverBalBefore + amount);
    }

    /// @notice Fuzz test slippage boundaries
    function testFuzz_SlippageBoundary(uint256 produced, uint256 minAmount) public {
        produced = bound(produced, 0, type(uint128).max);
        minAmount = bound(minAmount, 0, type(uint128).max);

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), produced);

        if (produced >= minAmount) {
            uint256 actualAmount = proxy.executeSingle(commands, state, address(tokenA), minAmount, receiver, bytes(""));
            assertEq(actualAmount, produced);
            assertEq(tokenA.balanceOf(receiver), produced);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(ExecutionProxy.SlippageExceeded.selector, address(tokenA), produced, minAmount)
            );
            proxy.executeSingle(commands, state, address(tokenA), minAmount, receiver, bytes(""));
        }
    }

    // ============================================================
    // Real Weiroll Program Tests (INF-0389)
    // ============================================================

    MockDEX public dex;

    function _deployDex() internal {
        if (address(dex) == address(0)) {
            dex = new MockDEX();
        }
    }

    /// @notice Test executeSingle with real approve + transfer Weiroll commands
    function test_ExecuteSingle_WithApproveAndTransfer() public {
        uint256 amount = 1000e18;

        // Build Weiroll: mint to proxy, then approve + transfer to receiver
        bytes[] memory state = WeirollTestHelper.createState3(
            WeirollTestHelper.encodeAddress(address(proxy)),
            WeirollTestHelper.encodeUint256(amount),
            WeirollTestHelper.encodeAddress(receiver)
        );

        bytes32[] memory commands = new bytes32[](3);
        // Mint tokens to proxy (produces delta)
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);
        // Approve receiver for amount
        commands[1] = WeirollTestHelper.buildApproveCommand(address(tokenA), 2, 1);
        // Transfer to receiver (consumes proxy balance, but receiver is same as output receiver)
        commands[2] = WeirollTestHelper.buildTransferCommand(address(tokenA), 2, 1);

        // After Weiroll: tokens moved to receiver via transfer, proxy delta is now negative
        // This will underflow. Let's mint 2x and only transfer 1x via Weiroll.
        // Actually the Weiroll transfer sends tokens away, reducing proxy balance below balanceBefore.
        // Let's restructure: mint 2x, transfer 1x away, delta = 1x.

        // Re-build: mint 2*amount, then transfer amount to receiver
        state = new bytes[](4);
        state[0] = WeirollTestHelper.encodeAddress(address(proxy));
        state[1] = WeirollTestHelper.encodeUint256(amount * 2);
        state[2] = WeirollTestHelper.encodeAddress(receiver);
        state[3] = WeirollTestHelper.encodeUint256(amount);

        commands = new bytes32[](3);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1); // mint 2*amount to proxy
        commands[1] = WeirollTestHelper.buildApproveCommand(address(tokenA), 2, 3); // approve receiver for amount
        commands[2] = WeirollTestHelper.buildTransferCommand(address(tokenA), 2, 3); // transfer amount to receiver

        // After Weiroll: proxy has amount (minted 2x, transferred 1x)
        // balanceBefore = 0, balanceAfter = amount, delta = amount
        uint256 actualAmount = proxy.executeSingle(commands, state, address(tokenA), amount, receiver, bytes(""));

        // Receiver gets: 1x from Weiroll transfer + 1x from output verification
        assertEq(actualAmount, amount);
        assertEq(tokenA.balanceOf(receiver), amount * 2);
        assertEq(tokenA.allowance(address(proxy), receiver), amount);
    }

    /// @notice Test execute with MockDEX swap via real Weiroll commands
    function test_Execute_WithMockDEXSwap() public {
        _deployDex();

        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;

        // Mint tokenA to proxy before execute (it becomes pre-existing for tokenA)
        // But tokenB delta will be the swap output
        tokenA.mint(address(proxy), amountIn);

        bytes[] memory state = WeirollTestHelper.createState5(
            WeirollTestHelper.encodeAddress(address(dex)),
            WeirollTestHelper.encodeUint256(amountIn),
            WeirollTestHelper.encodeAddress(address(tokenA)),
            WeirollTestHelper.encodeAddress(address(tokenB)),
            WeirollTestHelper.encodeUint256(amountOut)
        );

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 2, 3, 1, 4
        );

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenB), minAmount: amountOut });

        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));

        assertEq(actualAmounts[0], amountOut);
        assertEq(tokenB.balanceOf(receiver), amountOut);
        assertEq(tokenA.balanceOf(address(dex)), amountIn);
    }

    /// @notice Test executeSingle with WETH wrap via real Weiroll commands
    function test_ExecuteSingle_WithWETHWrap() public {
        uint256 amount = 1 ether;

        bytes[] memory state = WeirollTestHelper.createState1(WeirollTestHelper.encodeUint256(amount));

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildWethDepositCommand(address(weth), 0);

        uint256 actualAmount =
            proxy.executeSingle{ value: amount }(commands, state, address(weth), amount, receiver, bytes(""));

        assertEq(actualAmount, amount);
        assertEq(weth.balanceOf(receiver), amount);
        assertEq(address(proxy).balance, 0);
    }

    /// @notice Test executeSingle with WETH unwrap via real Weiroll commands
    function test_ExecuteSingle_WithWETHUnwrap() public {
        uint256 amount = 1 ether;

        vm.deal(address(proxy), amount);
        vm.prank(address(proxy));
        weth.deposit{ value: amount }();

        bytes[] memory state = WeirollTestHelper.createState1(WeirollTestHelper.encodeUint256(amount));

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildWethWithdrawCommand(address(weth), 0);

        uint256 receiverBalBefore = receiver.balance;
        uint256 actualAmount = proxy.executeSingle(commands, state, proxy.NATIVE_ETH(), amount, receiver, bytes(""));

        assertEq(actualAmount, amount);
        assertEq(receiver.balance, receiverBalBefore + amount);
        assertEq(weth.balanceOf(address(proxy)), 0);
    }

    /// @notice Test multi-hop swap (A -> B -> C) with real Weiroll commands
    function test_Execute_MultiHopSwap() public {
        _deployDex();

        uint256 amountA = 1000e18;
        uint256 amountB = 500e18;
        uint256 amountC = 250e6;

        tokenA.mint(address(proxy), amountA);

        bytes[] memory state = new bytes[](7);
        state[0] = WeirollTestHelper.encodeAddress(address(dex));
        state[1] = WeirollTestHelper.encodeUint256(amountA);
        state[2] = WeirollTestHelper.encodeAddress(address(tokenA));
        state[3] = WeirollTestHelper.encodeAddress(address(tokenB));
        state[4] = WeirollTestHelper.encodeUint256(amountB);
        state[5] = WeirollTestHelper.encodeAddress(address(tokenC));
        state[6] = WeirollTestHelper.encodeUint256(amountC);

        bytes32[] memory commands = new bytes32[](4);
        bytes4 swapSelector = bytes4(keccak256("swap(address,address,uint256,uint256)"));

        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildCallFourArgs(address(dex), swapSelector, 2, 3, 1, 4);
        commands[2] = WeirollTestHelper.buildApproveCommand(address(tokenB), 0, 4);
        commands[3] = WeirollTestHelper.buildCallFourArgs(address(dex), swapSelector, 3, 5, 4, 6);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenC), minAmount: amountC });

        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));

        assertEq(actualAmounts[0], amountC);
        assertEq(tokenC.balanceOf(receiver), amountC);
        assertEq(tokenA.balanceOf(address(dex)), amountA);
        assertEq(tokenB.balanceOf(address(dex)), amountB);
    }

    // ============================================================
    // Slippage Boundary and Edge Case Tests (INF-0390)
    // ============================================================

    /// @notice Test slippage passes when minAmount = 0 and production = 0
    function test_Slippage_ZeroMinZeroBalance() public {
        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: 0 });

        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));

        assertEq(actualAmounts[0], 0);
        assertEq(tokenA.balanceOf(receiver), 0);
    }

    /// @notice Test slippage passes when balance equals minAmount exactly
    function test_Slippage_ExactMatch() public {
        uint256 amount = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), amount);

        uint256 actualAmount = proxy.executeSingle(commands, state, address(tokenA), amount, receiver, bytes(""));

        assertEq(actualAmount, amount);
        assertEq(tokenA.balanceOf(receiver), amount);
    }

    /// @notice Test slippage fails when production is 1 wei below minAmount
    function test_Slippage_OneWeiBelow() public {
        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), produced);

        vm.expectRevert(
            abi.encodeWithSelector(ExecutionProxy.SlippageExceeded.selector, address(tokenA), produced, produced + 1)
        );
        proxy.executeSingle(commands, state, address(tokenA), produced + 1, receiver, bytes(""));
    }

    /// @notice Test slippage with max uint256 minAmount fails
    function test_Slippage_MaxUint256() public {
        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), produced);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionProxy.SlippageExceeded.selector, address(tokenA), produced, type(uint256).max
            )
        );
        proxy.executeSingle(commands, state, address(tokenA), type(uint256).max, receiver, bytes(""));
    }

    /// @notice Test that duplicate output token reverts (delta already consumed)
    function test_Execute_DuplicateOutputToken() public {
        uint256 amount = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), amount);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](2);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: amount });
        outputs[1] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: 1 });

        // First output transfers the delta. Second: balanceAfter < balanceBefore -> underflow.
        vm.expectRevert();
        proxy.execute(commands, state, outputs, receiver, bytes(""));
    }

    /// @notice Test duplicate output tokens with minAmount=0 on both: second silently gets 0
    function test_Execute_DuplicateOutputToken_ZeroMinBothPass() public {
        uint256 amount = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), amount);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](2);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: 0 });
        outputs[1] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: 0 });

        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));

        // First output gets full delta, second gets 0 (no underflow because balanceAfter == balanceBefore == 0)
        assertEq(actualAmounts[0], amount);
        assertEq(actualAmounts[1], 0);
        assertEq(tokenA.balanceOf(receiver), amount);
        assertEq(tokenA.balanceOf(address(proxy)), 0);
    }

    /// @notice Test mixed ETH and token outputs in same execution
    function test_Execute_MixedETHAndTokenOutputs() public {
        uint256 ethAmount = 1 ether;
        uint256 tokenAmount = 1000e18;

        // Build Weiroll: mint tokenA (ETH comes via msg.value)
        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), tokenAmount);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](2);
        outputs[0] = ExecutionProxy.OutputSpec({ token: proxy.NATIVE_ETH(), minAmount: ethAmount });
        outputs[1] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: tokenAmount });

        uint256 receiverEthBefore = receiver.balance;
        uint256[] memory actualAmounts =
            proxy.execute{ value: ethAmount }(commands, state, outputs, receiver, bytes(""));

        assertEq(actualAmounts[0], ethAmount);
        assertEq(actualAmounts[1], tokenAmount);
        assertEq(receiver.balance, receiverEthBefore + ethAmount);
        assertEq(tokenA.balanceOf(receiver), tokenAmount);
    }

    /// @notice Test ETH transfer fails when receiver rejects
    function test_ExecuteSingle_ReceiverRejectsETH() public {
        ETHRejectingReceiver rejectingReceiver = new ETHRejectingReceiver();

        uint256 ethAmount = 1 ether;

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        address nativeEth = proxy.NATIVE_ETH();

        vm.expectRevert(ExecutionProxy.ETHTransferFailed.selector);
        proxy.executeSingle{ value: ethAmount }(
            commands, state, nativeEth, ethAmount, address(rejectingReceiver), bytes("")
        );
    }

    /// @notice Test rescue with partial amount
    function test_Rescue_PartialAmount() public {
        uint256 totalAmount = 100e18;
        uint256 rescueAmount = 40e18;
        tokenA.mint(address(proxy), totalAmount);

        address rescueTo = makeAddr("rescueTo");
        proxy.rescue(address(tokenA), rescueTo, rescueAmount);

        assertEq(tokenA.balanceOf(rescueTo), rescueAmount);
        assertEq(tokenA.balanceOf(address(proxy)), totalAmount - rescueAmount);
    }

    /// @notice Test rescue to zero address (burns tokens)
    function test_Rescue_ToZeroAddress() public {
        uint256 amount = 100e18;
        tokenA.mint(address(proxy), amount);

        proxy.rescue(address(tokenA), address(0), amount);

        assertEq(tokenA.balanceOf(address(0)), amount);
        assertEq(tokenA.balanceOf(address(proxy)), 0);
    }

    /// @notice Test fallback accepts ETH with data
    function test_Fallback_AcceptsETH() public {
        uint256 amount = 1 ether;
        vm.deal(user, amount);

        vm.prank(user);
        (bool success,) = address(proxy).call{ value: amount }("0x1234");

        assertTrue(success);
        assertEq(address(proxy).balance, amount);
    }

    /// @notice Test receiver is proxy itself (tokens stay, delta=produced, transfer back to self)
    function test_Execute_ReceiverIsProxy() public {
        uint256 amount = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), amount);

        uint256 actualAmount = proxy.executeSingle(commands, state, address(tokenA), amount, address(proxy), bytes(""));

        assertEq(actualAmount, amount);
        assertEq(tokenA.balanceOf(address(proxy)), amount);
    }

    // ============================================================
    // Adversarial Token and Reentrancy Tests (INF-0391)
    // ============================================================

    /// @notice Test fee-on-transfer token: slippage check uses computed amount, not actual received
    function test_Execute_FeeOnTransferToken() public {
        FeeOnTransferToken fotToken = new FeeOnTransferToken();

        uint256 mintAmount = 1000e18;

        // Build Weiroll: mint FOT tokens to proxy during execution
        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(proxy)), WeirollTestHelper.encodeUint256(mintAmount)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(fotToken), 0, 1);

        uint256 expectedAfterFee = (mintAmount * 9900) / 10000;

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(fotToken), minAmount: expectedAfterFee });

        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));

        // Delta is mintAmount (minted during Weiroll)
        assertEq(actualAmounts[0], mintAmount);
        // Receiver gets less due to FOT tax on transfer
        assertEq(fotToken.balanceOf(receiver), expectedAfterFee);
    }

    /// @notice Test fee-on-transfer: slippage check passes against computed delta, not receiver balance
    function test_Execute_FeeOnTransferToken_SlippageTooTight() public {
        FeeOnTransferToken fotToken = new FeeOnTransferToken();

        uint256 mintAmount = 1000e18;

        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(proxy)), WeirollTestHelper.encodeUint256(mintAmount)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(fotToken), 0, 1);

        // minAmount = full delta -- passes because slippage check is on computed amount
        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(fotToken), minAmount: mintAmount });

        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));
        assertEq(actualAmounts[0], mintAmount);
        assertEq(fotToken.balanceOf(receiver), (mintAmount * 9900) / 10000);
    }

    /// @notice Test rebasing token: balance change reflected in slippage check
    function test_Execute_RebasingToken() public {
        RebasingToken rebaseToken = new RebasingToken();

        uint256 mintAmount = 1000e18;

        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(proxy)), WeirollTestHelper.encodeUint256(mintAmount)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(rebaseToken), 0, 1);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(rebaseToken), minAmount: mintAmount });

        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));
        assertEq(actualAmounts[0], mintAmount);
        assertEq(rebaseToken.balanceOf(receiver), mintAmount);
    }

    /// @notice Test rebasing token: pre-existing rebased balance excluded from delta
    function test_Execute_RebasingToken_RebasedDown() public {
        RebasingToken rebaseToken = new RebasingToken();

        uint256 mintAmount = 1000e18;

        // Pre-existing balance, then rebase down 10%
        rebaseToken.mint(address(proxy), mintAmount);
        rebaseToken.rebaseDown(1000);
        uint256 proxyBalance = rebaseToken.balanceOf(address(proxy));
        assertEq(proxyBalance, 900e18);

        // Mint during Weiroll. Due to rebasing token share math, minting 1000e18
        // at 0.9x multiplier produces slightly less than 1000e18 in balanceOf due to rounding.
        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(proxy)), WeirollTestHelper.encodeUint256(mintAmount)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(rebaseToken), 0, 1);

        // balanceBefore = 900e18
        // After mint: balanceAfter = 900e18 + ~1000e18 (may be 1 wei less due to share rounding)
        // Use minAmount slightly lower to account for rebasing token rounding
        uint256 actualAmount =
            proxy.executeSingle(commands, state, address(rebaseToken), mintAmount - 1, receiver, bytes(""));

        // delta >= mintAmount - 1 (accounting for rounding)
        assertGe(actualAmount, mintAmount - 1);
        assertGe(rebaseToken.balanceOf(receiver), mintAmount - 1);
        // Pre-existing (rebased) balance stays in proxy
        assertEq(rebaseToken.balanceOf(address(proxy)), 900e18);
    }

    /// @notice Test callback token: transfer callback doesn't break execution
    function test_Execute_CallbackToken() public {
        CallbackToken cbToken = new CallbackToken();

        uint256 amount = 1000e18;

        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(proxy)), WeirollTestHelper.encodeUint256(amount)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(cbToken), 0, 1);

        CallbackReceiver cbReceiver = new CallbackReceiver();
        cbToken.enableCallback(address(cbReceiver));

        uint256 actualAmount =
            proxy.executeSingle(commands, state, address(cbToken), amount, address(cbReceiver), bytes(""));

        assertEq(actualAmount, amount);
        assertEq(cbToken.balanceOf(address(cbReceiver)), amount);
        assertTrue(cbReceiver.callbackReceived());
    }

    /// @notice Test false-returning token: SafeERC20 reverts on false return
    function test_Execute_FalseReturningToken() public {
        FalseReturningToken falseToken = new FalseReturningToken();

        uint256 amount = 1000e18;

        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(proxy)), WeirollTestHelper.encodeUint256(amount)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(falseToken), 0, 1);

        falseToken.setShouldFail(true);

        vm.expectRevert();
        proxy.executeSingle(commands, state, address(falseToken), amount, receiver, bytes(""));
    }

    /// @notice Test reentrancy via ETH receive is blocked
    function test_ExecuteSingle_ReentrancyViaETH() public {
        ReentrantReceiver attacker = new ReentrantReceiver(address(proxy));

        uint256 ethAmount = 1 ether;

        bytes32[] memory emptyCommands = new bytes32[](0);
        bytes[] memory emptyState = new bytes[](0);

        attacker.setupExecuteSingleAttack(
            emptyCommands, emptyState, proxy.NATIVE_ETH(), 0, address(attacker), bytes("")
        );

        // Send ETH via msg.value (delta = ethAmount since Weiroll doesn't consume it)
        proxy.executeSingle{ value: ethAmount }(
            emptyCommands, emptyState, proxy.NATIVE_ETH(), ethAmount, address(attacker), bytes("")
        );

        assertTrue(attacker.attackAttempted());
        assertFalse(attacker.attackSucceeded());
        assertEq(address(attacker).balance, ethAmount);
    }

    /// @notice Test reentrancy via token callback is blocked
    function test_Execute_ReentrancyViaTokenCallback() public {
        CallbackToken cbToken = new CallbackToken();
        ReentrantReceiver attacker = new ReentrantReceiver(address(proxy));

        uint256 amount = 1000e18;

        cbToken.enableCallback(address(attacker));

        bytes32[] memory emptyCommands = new bytes32[](0);
        bytes[] memory emptyState = new bytes[](0);

        ExecutionProxy.OutputSpec[] memory attackOutputs = new ExecutionProxy.OutputSpec[](1);
        attackOutputs[0] = ExecutionProxy.OutputSpec({ token: address(cbToken), minAmount: 0 });

        attacker.setupExecuteAttack(emptyCommands, emptyState, attackOutputs, address(attacker), bytes(""));

        // Build Weiroll to mint cbToken during execution
        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(proxy)), WeirollTestHelper.encodeUint256(amount)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(cbToken), 0, 1);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(cbToken), minAmount: amount });

        proxy.execute(commands, state, outputs, address(attacker), bytes(""));

        assertTrue(attacker.attackAttempted());
        assertFalse(attacker.attackSucceeded());
        assertEq(cbToken.balanceOf(address(attacker)), amount);
    }

    // ============================================================
    // Balance Delta Tests (Step 5)
    // ============================================================

    /// @notice Test that pre-existing token balance doesn't affect delta measurement
    function test_BalanceDelta_PreExistingTokenBalance() public {
        _deployDex();

        uint256 preExisting = 500e18;
        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;

        // Pre-existing tokenB balance in proxy (dust/airdrop)
        tokenB.mint(address(proxy), preExisting);

        // Mint tokenA for the swap input
        tokenA.mint(address(proxy), amountIn);

        bytes[] memory state = WeirollTestHelper.createState5(
            WeirollTestHelper.encodeAddress(address(dex)),
            WeirollTestHelper.encodeUint256(amountIn),
            WeirollTestHelper.encodeAddress(address(tokenA)),
            WeirollTestHelper.encodeAddress(address(tokenB)),
            WeirollTestHelper.encodeUint256(amountOut)
        );

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 2, 3, 1, 4
        );

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenB), minAmount: amountOut });

        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));

        // Only the delta (amountOut from swap) is transferred, not pre-existing
        assertEq(actualAmounts[0], amountOut);
        assertEq(tokenB.balanceOf(receiver), amountOut);
        // Pre-existing balance stays in proxy
        assertEq(tokenB.balanceOf(address(proxy)), preExisting);
    }

    /// @notice Test that pre-existing ETH balance doesn't affect delta measurement
    function test_BalanceDelta_PreExistingETHBalance() public {
        uint256 preExisting = 2 ether;
        uint256 wethAmount = 1 ether;

        // Pre-existing ETH in proxy
        vm.deal(address(proxy), preExisting);

        // Mint WETH to proxy so Weiroll can unwrap it
        vm.deal(address(this), wethAmount);
        weth.deposit{ value: wethAmount }();
        MockERC20(address(weth)).transfer(address(proxy), wethAmount);

        bytes[] memory state = WeirollTestHelper.createState1(WeirollTestHelper.encodeUint256(wethAmount));

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildWethWithdrawCommand(address(weth), 0);

        uint256 receiverBalBefore = receiver.balance;

        uint256 actualAmount = proxy.executeSingle(commands, state, proxy.NATIVE_ETH(), wethAmount, receiver, bytes(""));

        assertEq(actualAmount, wethAmount);
        assertEq(receiver.balance, receiverBalBefore + wethAmount);
        // Pre-existing ETH stays in proxy
        assertEq(address(proxy).balance, preExisting);
    }

    /// @notice Test that pre-existing balance is recoverable via rescue after execution
    function test_BalanceDelta_PreExistingBalanceRecoverableViaRescue() public {
        _deployDex();

        uint256 preExisting = 500e18;
        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;

        tokenB.mint(address(proxy), preExisting);
        tokenA.mint(address(proxy), amountIn);

        bytes[] memory state = WeirollTestHelper.createState5(
            WeirollTestHelper.encodeAddress(address(dex)),
            WeirollTestHelper.encodeUint256(amountIn),
            WeirollTestHelper.encodeAddress(address(tokenA)),
            WeirollTestHelper.encodeAddress(address(tokenB)),
            WeirollTestHelper.encodeUint256(amountOut)
        );

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 2, 3, 1, 4
        );

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenB), minAmount: amountOut });

        proxy.execute(commands, state, outputs, receiver, bytes(""));

        assertEq(tokenB.balanceOf(address(proxy)), preExisting);

        address rescueTo = makeAddr("rescueTo");
        proxy.rescue(address(tokenB), rescueTo, preExisting);
        assertEq(tokenB.balanceOf(rescueTo), preExisting);
        assertEq(tokenB.balanceOf(address(proxy)), 0);
    }

    /// @notice Test delta measurement with multiple outputs and pre-existing balances
    function test_BalanceDelta_MultiOutput() public {
        _deployDex();

        uint256 preExistingB = 100e18;
        uint256 preExistingC = 50e6;
        uint256 amountA = 1000e18;
        uint256 amountB = 500e18;
        uint256 amountC = 250e6;

        // Pre-existing balances
        tokenB.mint(address(proxy), preExistingB);
        tokenC.mint(address(proxy), preExistingC);

        // Input for swap
        tokenA.mint(address(proxy), amountA);

        // Build multi-hop: A -> B -> C
        bytes[] memory state = new bytes[](7);
        state[0] = WeirollTestHelper.encodeAddress(address(dex));
        state[1] = WeirollTestHelper.encodeUint256(amountA);
        state[2] = WeirollTestHelper.encodeAddress(address(tokenA));
        state[3] = WeirollTestHelper.encodeAddress(address(tokenB));
        state[4] = WeirollTestHelper.encodeUint256(amountB);
        state[5] = WeirollTestHelper.encodeAddress(address(tokenC));
        state[6] = WeirollTestHelper.encodeUint256(amountC);

        bytes32[] memory commands = new bytes32[](4);
        bytes4 swapSelector = bytes4(keccak256("swap(address,address,uint256,uint256)"));
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildCallFourArgs(address(dex), swapSelector, 2, 3, 1, 4);
        commands[2] = WeirollTestHelper.buildApproveCommand(address(tokenB), 0, 4);
        commands[3] = WeirollTestHelper.buildCallFourArgs(address(dex), swapSelector, 3, 5, 4, 6);

        // Output only tokenC -- delta should be amountC
        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenC), minAmount: amountC });

        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));

        assertEq(actualAmounts[0], amountC);
        assertEq(tokenC.balanceOf(receiver), amountC);
        // Pre-existing balances stay in proxy
        assertEq(tokenB.balanceOf(address(proxy)), preExistingB);
        assertEq(tokenC.balanceOf(address(proxy)), preExistingC);
    }

    /// @notice Test delta with mixed ETH and token, pre-existing balances
    function test_BalanceDelta_MixedETHAndToken() public {
        uint256 preExistingETH = 0.5 ether;
        uint256 wethAmount = 1 ether;

        // Pre-existing ETH
        vm.deal(address(proxy), preExistingETH);

        // Mint WETH to proxy for Weiroll to unwrap
        vm.deal(address(this), wethAmount);
        weth.deposit{ value: wethAmount }();
        MockERC20(address(weth)).transfer(address(proxy), wethAmount);

        bytes[] memory state = WeirollTestHelper.createState1(WeirollTestHelper.encodeUint256(wethAmount));

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildWethWithdrawCommand(address(weth), 0);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: proxy.NATIVE_ETH(), minAmount: wethAmount });

        uint256 receiverEthBefore = receiver.balance;
        uint256[] memory actualAmounts = proxy.execute(commands, state, outputs, receiver, bytes(""));

        assertEq(actualAmounts[0], wethAmount);
        assertEq(receiver.balance, receiverEthBefore + wethAmount);
        // Pre-existing ETH stays
        assertEq(address(proxy).balance, preExistingETH);
    }

    /// @notice Test zero production: minAmount=0 passes, minAmount>0 reverts
    function test_BalanceDelta_ZeroProduction() public {
        // Pre-existing balance but Weiroll produces nothing
        tokenA.mint(address(proxy), 1000e18);

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        // delta = 0, minAmount = 0 should pass
        uint256 actualAmount = proxy.executeSingle(commands, state, address(tokenA), 0, receiver, bytes(""));
        assertEq(actualAmount, 0);
        assertEq(tokenA.balanceOf(receiver), 0);

        // delta = 0, minAmount > 0 should revert
        vm.expectRevert(abi.encodeWithSelector(ExecutionProxy.SlippageExceeded.selector, address(tokenA), 0, 1));
        proxy.executeSingle(commands, state, address(tokenA), 1, receiver, bytes(""));
    }

    /// @notice Test that msg.value is included in ETH delta when Weiroll doesn't consume it
    function test_BalanceDelta_MsgValueIncludedInETHDelta() public {
        uint256 msgValue = 1 ether;

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        uint256 receiverBalBefore = receiver.balance;

        uint256 actualAmount = proxy.executeSingle{ value: msgValue }(
            commands, state, proxy.NATIVE_ETH(), msgValue, receiver, bytes("")
        );

        assertEq(actualAmount, msgValue);
        assertEq(receiver.balance, receiverBalBefore + msgValue);
    }

    /// @notice Test that msg.value consumed by Weiroll (WETH wrap) doesn't double-count
    function test_BalanceDelta_MsgValueConsumedByWeiroll() public {
        uint256 amount = 1 ether;

        bytes[] memory state = WeirollTestHelper.createState1(WeirollTestHelper.encodeUint256(amount));

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildWethDepositCommand(address(weth), 0);

        // Output is WETH, not ETH. ETH delta should be 0.
        uint256 actualAmount =
            proxy.executeSingle{ value: amount }(commands, state, address(weth), amount, receiver, bytes(""));

        assertEq(actualAmount, amount);
        assertEq(weth.balanceOf(receiver), amount);
        assertEq(address(proxy).balance, 0);
    }

    /// @notice Test msg.value with ERC20-only output: ETH stays in proxy, recoverable via rescue
    function test_Execute_MsgValueWithERC20OnlyOutput_ETHStaysInProxy() public {
        uint256 ethSent = 1 ether;
        uint256 tokenAmount = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), tokenAmount);

        uint256 actualAmount =
            proxy.executeSingle{ value: ethSent }(commands, state, address(tokenA), tokenAmount, receiver, bytes(""));

        assertEq(actualAmount, tokenAmount);
        assertEq(tokenA.balanceOf(receiver), tokenAmount);
        // ETH stays in proxy -- no NATIVE_ETH output to capture it
        assertEq(address(proxy).balance, ethSent);

        // Verify recoverability via rescue
        address rescueTo = makeAddr("rescueTo");
        proxy.rescue(proxy.NATIVE_ETH(), rescueTo, ethSent);
        assertEq(rescueTo.balance, ethSent);
        assertEq(address(proxy).balance, 0);
    }

    /// @notice Test duplicate output tokens revert with delta-based measurement
    function test_BalanceDelta_DuplicateOutputTokenReverts() public {
        _deployDex();

        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;

        tokenA.mint(address(proxy), amountIn);

        bytes[] memory state = WeirollTestHelper.createState5(
            WeirollTestHelper.encodeAddress(address(dex)),
            WeirollTestHelper.encodeUint256(amountIn),
            WeirollTestHelper.encodeAddress(address(tokenA)),
            WeirollTestHelper.encodeAddress(address(tokenB)),
            WeirollTestHelper.encodeUint256(amountOut)
        );

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 2, 3, 1, 4
        );

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](2);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenB), minAmount: amountOut });
        outputs[1] = ExecutionProxy.OutputSpec({ token: address(tokenB), minAmount: 1 });

        // First output transfers the delta, second sees balanceAfter < balanceBefore -> underflow
        vm.expectRevert();
        proxy.execute(commands, state, outputs, receiver, bytes(""));
    }

    // ============================================================
    // Fee Tests (Step 6)
    // ============================================================

    /// @notice Test default fee is applied correctly
    function test_Fee_DefaultFeeApplied() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, address(0));

        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(feeProxy, address(tokenA), produced);

        // fee = 1000e18 * 500 / 10000 = 50e18, receiverAmount = 950e18
        uint256 actualAmount = feeProxy.executeSingle(commands, state, address(tokenA), 950e18, receiver, bytes(""));

        assertEq(actualAmount, 950e18);
        assertEq(tokenA.balanceOf(receiver), 950e18);
        assertEq(tokenA.balanceOf(feeRecipientAddr), 50e18);
    }

    /// @notice Test zero default fee means no fee charged
    function test_Fee_ZeroDefaultFee() public {
        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), produced);

        uint256 actualAmount = proxy.executeSingle(commands, state, address(tokenA), produced, receiver, bytes(""));

        assertEq(actualAmount, produced);
        assertEq(tokenA.balanceOf(receiver), produced);
    }

    /// @notice Test signed override with lower fee
    function test_Fee_SignedOverride_LowerFee() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, feeSignerAddr);

        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(feeProxy, address(tokenA), produced);

        uint256 overrideFeeBps = 100;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 executionHash = _computeExecutionHashSingle(commands, state, address(tokenA), 990e18, receiver);

        bytes memory feeData =
            _signFeeOverrideForProxy(feeProxy, feeSignerPk, overrideFeeBps, deadline, address(this), executionHash);

        uint256 actualAmount = feeProxy.executeSingle(commands, state, address(tokenA), 990e18, receiver, feeData);

        assertEq(actualAmount, 990e18);
        assertEq(tokenA.balanceOf(receiver), 990e18);
        assertEq(tokenA.balanceOf(feeRecipientAddr), 10e18);
    }

    /// @notice Test signed override with zero fee
    function test_Fee_SignedOverride_ZeroFee() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, feeSignerAddr);

        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(feeProxy, address(tokenA), produced);

        uint256 deadline = block.timestamp + 1 hours;

        bytes32 executionHash = _computeExecutionHashSingle(commands, state, address(tokenA), produced, receiver);

        bytes memory feeData =
            _signFeeOverrideForProxy(feeProxy, feeSignerPk, 0, deadline, address(this), executionHash);

        uint256 actualAmount = feeProxy.executeSingle(commands, state, address(tokenA), produced, receiver, feeData);

        assertEq(actualAmount, produced);
        assertEq(tokenA.balanceOf(receiver), produced);
        assertEq(tokenA.balanceOf(feeRecipientAddr), 0);
    }

    /// @notice Test signed override with multi-output execute()
    function test_Fee_SignedOverride_MultiOutput() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, feeSignerAddr);

        uint256 producedA = 1000e18;
        uint256 producedB = 500e18;

        // Build Weiroll: mint both tokens to feeProxy
        bytes[] memory state = new bytes[](3);
        state[0] = WeirollTestHelper.encodeAddress(address(feeProxy));
        state[1] = WeirollTestHelper.encodeUint256(producedA);
        state[2] = WeirollTestHelper.encodeUint256(producedB);

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildMintCommand(address(tokenB), 0, 2);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](2);
        // Post-fee amounts: 1000 * (1 - 1%) = 990, 500 * (1 - 1%) = 495
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: 990e18 });
        outputs[1] = ExecutionProxy.OutputSpec({ token: address(tokenB), minAmount: 495e18 });

        uint256 overrideFeeBps = 100; // 1% override (down from 5% default)
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 executionHash = _computeExecutionHashMulti(commands, state, outputs, receiver);

        bytes memory feeData =
            _signFeeOverrideForProxy(feeProxy, feeSignerPk, overrideFeeBps, deadline, address(this), executionHash);

        uint256[] memory actualAmounts = feeProxy.execute(commands, state, outputs, receiver, feeData);

        // Fee = 1%: feeA = 10e18, feeB = 5e18
        assertEq(actualAmounts[0], 990e18);
        assertEq(actualAmounts[1], 495e18);
        assertEq(tokenA.balanceOf(receiver), 990e18);
        assertEq(tokenB.balanceOf(receiver), 495e18);
        assertEq(tokenA.balanceOf(feeRecipientAddr), 10e18);
        assertEq(tokenB.balanceOf(feeRecipientAddr), 5e18);
    }

    /// @notice Test invalid signature reverts
    function test_Fee_InvalidSignature_Reverts() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, feeSignerAddr);

        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(feeProxy, address(tokenA), produced);

        uint256 deadline = block.timestamp + 1 hours;

        bytes32 executionHash = _computeExecutionHashSingle(commands, state, address(tokenA), 990e18, receiver);

        uint256 wrongPk = 0xDEAD;
        bytes memory feeData = _signFeeOverrideForProxy(feeProxy, wrongPk, 100, deadline, address(this), executionHash);

        vm.expectRevert(ExecutionProxy.InvalidFeeSignature.selector);
        feeProxy.executeSingle(commands, state, address(tokenA), 990e18, receiver, feeData);
    }

    /// @notice Test expired deadline reverts
    function test_Fee_ExpiredDeadline_Reverts() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, feeSignerAddr);

        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(feeProxy, address(tokenA), produced);

        uint256 deadline = block.timestamp - 1;

        bytes32 executionHash = _computeExecutionHashSingle(commands, state, address(tokenA), 990e18, receiver);

        bytes memory feeData =
            _signFeeOverrideForProxy(feeProxy, feeSignerPk, 100, deadline, address(this), executionHash);

        vm.expectRevert(ExecutionProxy.FeeSignatureExpired.selector);
        feeProxy.executeSingle(commands, state, address(tokenA), 990e18, receiver, feeData);
    }

    /// @notice Test fee exceeds max reverts
    function test_Fee_ExceedsMax_Reverts() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, feeSignerAddr);

        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(feeProxy, address(tokenA), produced);

        uint256 deadline = block.timestamp + 1 hours;

        bytes32 executionHash = _computeExecutionHashSingle(commands, state, address(tokenA), 0, receiver);

        bytes memory feeData =
            _signFeeOverrideForProxy(feeProxy, feeSignerPk, 1001, deadline, address(this), executionHash);

        vm.expectRevert(abi.encodeWithSelector(ExecutionProxy.FeeExceedsMax.selector, 1001));
        feeProxy.executeSingle(commands, state, address(tokenA), 0, receiver, feeData);
    }

    /// @notice Test wrong caller reverts
    function test_Fee_WrongCaller_Reverts() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, feeSignerAddr);

        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(feeProxy, address(tokenA), produced);

        uint256 deadline = block.timestamp + 1 hours;

        bytes32 executionHash = _computeExecutionHashSingle(commands, state, address(tokenA), 990e18, receiver);

        bytes memory feeData =
            _signFeeOverrideForProxy(feeProxy, feeSignerPk, 100, deadline, address(this), executionHash);

        vm.prank(user);
        vm.expectRevert(ExecutionProxy.InvalidFeeSignature.selector);
        feeProxy.executeSingle(commands, state, address(tokenA), 990e18, receiver, feeData);
    }

    /// @notice Test wrong execution hash reverts
    function test_Fee_WrongExecutionHash_Reverts() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, feeSignerAddr);

        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(feeProxy, address(tokenA), produced);

        uint256 deadline = block.timestamp + 1 hours;

        bytes memory feeData =
            _signFeeOverrideForProxy(feeProxy, feeSignerPk, 100, deadline, address(this), bytes32(uint256(0xBAD)));

        vm.expectRevert(ExecutionProxy.InvalidFeeSignature.selector);
        feeProxy.executeSingle(commands, state, address(tokenA), 990e18, receiver, feeData);
    }

    /// @notice Test feeRecipient == address(0) means no fee charged
    function test_Fee_FeeRecipientZero_NoFeeCharged() public {
        ExecutionProxy zeroRecipientProxy = new ExecutionProxy(address(this), address(0), 500, address(0));

        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(zeroRecipientProxy, address(tokenA), produced);

        uint256 actualAmount =
            zeroRecipientProxy.executeSingle(commands, state, address(tokenA), produced, receiver, bytes(""));

        assertEq(actualAmount, produced);
        assertEq(tokenA.balanceOf(receiver), produced);
    }

    /// @notice Test dust amounts round fee to zero
    function test_Fee_DustRoundsToZero() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 1, address(0));

        uint256 produced = 99;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(feeProxy, address(tokenA), produced);

        uint256 actualAmount = feeProxy.executeSingle(commands, state, address(tokenA), produced, receiver, bytes(""));

        assertEq(actualAmount, produced);
        assertEq(tokenA.balanceOf(receiver), produced);
        assertEq(tokenA.balanceOf(feeRecipientAddr), 0);
    }

    /// @notice Test feeSigner == address(0) disables overrides
    function test_Fee_FeeSignerZero_OverridesDisabled() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, address(0));

        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(feeProxy, address(tokenA), produced);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 executionHash = _computeExecutionHashSingle(commands, state, address(tokenA), 990e18, receiver);

        bytes memory feeData =
            _signFeeOverrideForProxy(feeProxy, feeSignerPk, 100, deadline, address(this), executionHash);

        vm.expectRevert(ExecutionProxy.InvalidFeeSignature.selector);
        feeProxy.executeSingle(commands, state, address(tokenA), 990e18, receiver, feeData);
    }

    /// @notice Test receiver == feeRecipient (both transfers go to same address)
    function test_Fee_ReceiverEqualsFeeRecipient() public {
        address combined = makeAddr("combined");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), combined, 500, address(0));

        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) =
            _buildMintProgramForProxy(feeProxy, address(tokenA), produced);

        uint256 actualAmount = feeProxy.executeSingle(commands, state, address(tokenA), 950e18, combined, bytes(""));

        assertEq(actualAmount, 950e18);
        // Combined gets fee + receiver amount
        assertEq(tokenA.balanceOf(combined), produced);
    }

    /// @notice Test re-entrancy via feeRecipient ETH receive is blocked
    function test_Fee_FeeRecipientReentrancy() public {
        // Deploy proxy first, then create attacker targeting it
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), address(1), 500, address(0));
        ReentrantReceiver attacker = new ReentrantReceiver(address(feeProxy));
        feeProxy.setFeeRecipient(address(attacker));

        uint256 ethAmount = 10 ether;

        bytes32[] memory emptyCommands = new bytes32[](0);
        bytes[] memory emptyState = new bytes[](0);

        attacker.setupExecuteSingleAttack(
            emptyCommands, emptyState, feeProxy.NATIVE_ETH(), 0, address(attacker), bytes("")
        );

        // Send ETH via msg.value. Fee goes to attacker which tries re-entry.
        feeProxy.executeSingle{ value: ethAmount }(
            emptyCommands, emptyState, feeProxy.NATIVE_ETH(), 0, receiver, bytes("")
        );

        assertTrue(attacker.attackAttempted());
        assertFalse(attacker.attackSucceeded());
    }

    /// @notice Test fee with ETH output
    function test_Fee_ETHOutput() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, address(0));

        uint256 ethAmount = 10 ether;

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        uint256 receiverBalBefore = receiver.balance;
        uint256 feeRecipientBalBefore = feeRecipientAddr.balance;

        feeProxy.executeSingle{ value: ethAmount }(
            commands, state, feeProxy.NATIVE_ETH(), 9.5 ether, receiver, bytes("")
        );

        assertEq(receiver.balance, receiverBalBefore + 9.5 ether);
        assertEq(feeRecipientAddr.balance, feeRecipientBalBefore + 0.5 ether);
    }

    /// @notice Test fee with fee-on-transfer token (compounding fees)
    function test_Fee_FeeOnTransferToken() public {
        FeeOnTransferToken fotToken = new FeeOnTransferToken();
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, address(0));

        uint256 produced = 1000e18;

        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(feeProxy)), WeirollTestHelper.encodeUint256(produced)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(fotToken), 0, 1);

        // Protocol fee: 1000e18 * 500 / 10000 = 50e18
        // receiverAmount = 950e18
        // FOT token takes 1% on transfer:
        // feeRecipient receives: 50e18 * 99% = 49.5e18
        // receiver receives: 950e18 * 99% = 940.5e18
        uint256 actualAmount = feeProxy.executeSingle(commands, state, address(fotToken), 950e18, receiver, bytes(""));

        assertEq(actualAmount, 950e18);
        assertEq(fotToken.balanceOf(receiver), (950e18 * 9900) / 10000);
        assertEq(fotToken.balanceOf(feeRecipientAddr), (50e18 * 9900) / 10000);
    }

    /// @notice Test setDefaultFeeBps only callable by owner
    function test_SetDefaultFeeBps_OnlyOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        proxy.setDefaultFeeBps(100);
    }

    /// @notice Test setDefaultFeeBps rejects values exceeding max
    function test_SetDefaultFeeBps_ExceedsMax() public {
        vm.expectRevert(abi.encodeWithSelector(ExecutionProxy.FeeExceedsMax.selector, 1001));
        proxy.setDefaultFeeBps(1001);
    }

    /// @notice Test setFeeRecipient only callable by owner
    function test_SetFeeRecipient_OnlyOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        proxy.setFeeRecipient(attacker);
    }

    /// @notice Test setFeeSigner only callable by owner
    function test_SetFeeSigner_OnlyOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        proxy.setFeeSigner(attacker);
    }

    /// @notice Test setDefaultFeeBps emits event
    function test_SetDefaultFeeBps_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ExecutionProxy.DefaultFeeBpsUpdated(0, 100);
        proxy.setDefaultFeeBps(100);
    }

    /// @notice Test setFeeRecipient emits event
    function test_SetFeeRecipient_EmitsEvent() public {
        address newRecipient = makeAddr("newRecipient");
        vm.expectEmit(true, true, true, true);
        emit ExecutionProxy.FeeRecipientUpdated(address(0), newRecipient);
        proxy.setFeeRecipient(newRecipient);
    }

    /// @notice Test setFeeSigner emits event
    function test_SetFeeSigner_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ExecutionProxy.FeeSignerUpdated(address(0), feeSignerAddr);
        proxy.setFeeSigner(feeSignerAddr);
    }

    /// @notice Test event emits post-fee amounts
    function test_Fee_EventEmitsPostFeeAmounts() public {
        address feeRecipientAddr = makeAddr("feeRecipient");
        ExecutionProxy feeProxy = new ExecutionProxy(address(this), feeRecipientAddr, 500, address(0));

        uint256 produced = 1000e18;

        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(feeProxy)), WeirollTestHelper.encodeUint256(produced)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);

        ExecutionProxy.OutputSpec[] memory outputs = new ExecutionProxy.OutputSpec[](1);
        outputs[0] = ExecutionProxy.OutputSpec({ token: address(tokenA), minAmount: 950e18 });

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 950e18;

        vm.expectEmit(true, true, false, true);
        emit ExecutionProxy.Executed(address(this), receiver, 1, expectedAmounts);

        feeProxy.execute(commands, state, outputs, receiver, bytes(""));
    }

    /// @notice Gas baseline: no fee overhead
    function test_Gas_NoFeeOverhead() public {
        uint256 produced = 1000e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintProgram(address(tokenA), produced);

        uint256 gasBefore = gasleft();
        proxy.executeSingle(commands, state, address(tokenA), produced, receiver, bytes(""));
        uint256 gasUsed = gasBefore - gasleft();

        assertGt(gasUsed, 0);
    }
}

/// @title ETHRejectingReceiver
/// @notice Contract that rejects ETH transfers
contract ETHRejectingReceiver {
    receive() external payable {
        revert("ETHRejectingReceiver: rejecting ETH");
    }

    fallback() external payable {
        revert("ETHRejectingReceiver: rejecting ETH");
    }
}

/// @title CallbackReceiver
/// @notice Contract that receives token callbacks without reentrancy
contract CallbackReceiver {
    bool public callbackReceived;

    function onTokenTransfer(address, address, uint256) external {
        callbackReceived = true;
    }

    receive() external payable { }
}
