// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";
import { MockDEX } from "./mocks/MockDEX.sol";

/// @title MockERC20ForHelper
/// @notice Minimal ERC20 for helper tests
contract MockERC20ForHelper {
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

/// @title MockWETHForHelper
/// @notice Minimal WETH for helper tests
contract MockWETHForHelper is MockERC20ForHelper {
    constructor() MockERC20ForHelper("Wrapped Ether", "WETH", 18) { }

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

/// @title WeirollTestHelperTest
/// @notice Tests that WeirollTestHelper builds valid commands
contract WeirollTestHelperTest is Test {
    ExecutionProxy public proxy;
    MockWETHForHelper public weth;
    MockERC20ForHelper public tokenA;
    MockERC20ForHelper public tokenB;
    MockDEX public dex;

    address public receiver = makeAddr("receiver");

    function setUp() public {
        weth = new MockWETHForHelper();
        tokenA = new MockERC20ForHelper("Token A", "TKNA", 18);
        tokenB = new MockERC20ForHelper("Token B", "TKNB", 18);
        dex = new MockDEX();

        proxy = new ExecutionProxy(address(this));

        vm.deal(address(this), 100 ether);
    }

    /// @notice Test buildApproveCommand generates valid command
    function test_BuildApproveCommand() public {
        // Mint tokens to proxy
        uint256 amount = 1000e18;
        tokenA.mint(address(proxy), amount);

        // Build approve command: approve(dex, amount)
        // State: [0] = dex address, [1] = amount
        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(dex)), WeirollTestHelper.encodeUint256(amount)
        );

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 0, 1);

        // Execute via proxy - the proxy will call approve on tokenA
        // We need to verify the approval was set
        proxy.executeSingle(commands, state, address(tokenA), amount, receiver);

        // Check that approval was set (proxy approved dex)
        assertEq(tokenA.allowance(address(proxy), address(dex)), amount);
    }

    /// @notice Test buildTransferCommand generates valid command
    function test_BuildTransferCommand() public {
        // Mint tokens to proxy
        uint256 amount = 1000e18;
        tokenA.mint(address(proxy), amount);

        // Build transfer command: transfer(receiver, amount)
        // State: [0] = receiver address, [1] = amount
        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(receiver), WeirollTestHelper.encodeUint256(amount)
        );

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildTransferCommand(address(tokenA), 0, 1);

        // The transfer happens in the Weiroll execution, then output verification transfers to receiver
        // Since transfer already sent to receiver, proxy balance is 0
        // But we're testing the command works - let's mint extra to proxy for the output check
        tokenA.mint(address(proxy), amount);

        proxy.executeSingle(commands, state, address(tokenA), amount, receiver);

        // Receiver should have 2x amount (one from Weiroll transfer, one from output transfer)
        assertEq(tokenA.balanceOf(receiver), amount * 2);
    }

    /// @notice Test buildWETHDepositCommand with value call
    function test_BuildWETHDepositCommand() public {
        uint256 amount = 1 ether;

        // Build WETH deposit command
        // State: [0] = amount (value to send)
        bytes[] memory state = WeirollTestHelper.createState1(WeirollTestHelper.encodeUint256(amount));

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildWethDepositCommand(address(weth), 0);

        // Execute with ETH value
        proxy.executeSingle{ value: amount }(commands, state, address(weth), amount, receiver);

        // Receiver should have WETH
        assertEq(weth.balanceOf(receiver), amount);
    }

    /// @notice Test buildWETHWithdrawCommand
    function test_BuildWETHWithdrawCommand() public {
        uint256 amount = 1 ether;

        // First mint WETH to proxy
        vm.deal(address(proxy), amount);
        vm.prank(address(proxy));
        weth.deposit{ value: amount }();

        // Build WETH withdraw command
        // State: [0] = amount
        bytes[] memory state = WeirollTestHelper.createState1(WeirollTestHelper.encodeUint256(amount));

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildWethWithdrawCommand(address(weth), 0);

        // Execute - outputs native ETH
        uint256 receiverBalBefore = receiver.balance;
        proxy.executeSingle(commands, state, proxy.NATIVE_ETH(), amount, receiver);

        // Receiver should have ETH
        assertEq(receiver.balance, receiverBalBefore + amount);
    }

    /// @notice Test MockDEX swap via Weiroll
    function test_MockDEXSwapViaWeiroll() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;

        // Mint tokenA to proxy
        tokenA.mint(address(proxy), amountIn);

        // Build commands:
        // 1. Approve DEX to spend tokenA
        // 2. Call DEX.swap(tokenA, tokenB, amountIn, amountOut)

        // State: [0]=dex, [1]=amountIn, [2]=tokenA, [3]=tokenB, [4]=amountOut
        bytes[] memory state = WeirollTestHelper.createState5(
            WeirollTestHelper.encodeAddress(address(dex)),
            WeirollTestHelper.encodeUint256(amountIn),
            WeirollTestHelper.encodeAddress(address(tokenA)),
            WeirollTestHelper.encodeAddress(address(tokenB)),
            WeirollTestHelper.encodeUint256(amountOut)
        );

        bytes32[] memory commands = new bytes32[](2);
        // approve(dex, amountIn)
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 0, 1);
        // swap(tokenIn, tokenOut, amountIn, amountOut) - need 4 args
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex),
            bytes4(keccak256("swap(address,address,uint256,uint256)")),
            2, // tokenA
            3, // tokenB
            1, // amountIn
            4 // amountOut
        );

        // Execute - output is tokenB
        proxy.executeSingle(commands, state, address(tokenB), amountOut, receiver);

        // Verify swap occurred
        assertEq(tokenB.balanceOf(receiver), amountOut);
        assertEq(tokenA.balanceOf(address(dex)), amountIn); // DEX received tokenA
    }
}
