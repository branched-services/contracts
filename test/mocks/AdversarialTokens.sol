// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FeeOnTransferToken
/// @notice ERC20 that takes a 1% fee on every transfer
contract FeeOnTransferToken is IERC20 {
    string public constant name = "Fee On Transfer Token";
    string public constant symbol = "FOT";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public constant FEE_BPS = 100; // 1% fee
    address public feeCollector;

    constructor() {
        feeCollector = msg.sender;
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
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "FeeOnTransferToken: insufficient allowance");
            allowance[from][msg.sender] = currentAllowance - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "FeeOnTransferToken: insufficient balance");

        uint256 fee = (amount * FEE_BPS) / 10000;
        uint256 amountAfterFee = amount - fee;

        balanceOf[from] -= amount;
        balanceOf[to] += amountAfterFee;
        if (fee > 0) {
            balanceOf[feeCollector] += fee;
            emit Transfer(from, feeCollector, fee);
        }
        emit Transfer(from, to, amountAfterFee);
        return true;
    }
}

/// @title RebasingToken
/// @notice ERC20 with adjustable supply multiplier (simulates rebasing)
contract RebasingToken is IERC20 {
    string public constant name = "Rebasing Token";
    string public constant symbol = "REBASE";
    uint8 public constant decimals = 18;

    uint256 internal _totalShares;
    mapping(address => uint256) internal _shares;
    mapping(address => mapping(address => uint256)) public allowance;

    // Rebase factor: balanceOf = shares * rebaseMultiplier / REBASE_PRECISION
    uint256 public rebaseMultiplier = 1e18;
    uint256 public constant REBASE_PRECISION = 1e18;

    function mint(address to, uint256 amount) external {
        uint256 shares = (amount * REBASE_PRECISION) / rebaseMultiplier;
        _shares[to] += shares;
        _totalShares += shares;
        emit Transfer(address(0), to, amount);
    }

    function totalSupply() external view returns (uint256) {
        return (_totalShares * rebaseMultiplier) / REBASE_PRECISION;
    }

    function balanceOf(address account) external view returns (uint256) {
        return (_shares[account] * rebaseMultiplier) / REBASE_PRECISION;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "RebasingToken: insufficient allowance");
            allowance[from][msg.sender] = currentAllowance - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        uint256 shares = (amount * REBASE_PRECISION) / rebaseMultiplier;
        require(_shares[from] >= shares, "RebasingToken: insufficient balance");
        _shares[from] -= shares;
        _shares[to] += shares;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice Adjust the rebase multiplier (for testing)
    /// @param newMultiplier The new multiplier (1e18 = 100%)
    function setRebaseMultiplier(uint256 newMultiplier) external {
        rebaseMultiplier = newMultiplier;
    }

    /// @notice Rebase down by a percentage (simulates negative rebase)
    /// @param decreaseBps Basis points to decrease (e.g., 500 = 5% decrease)
    function rebaseDown(uint256 decreaseBps) external {
        rebaseMultiplier = (rebaseMultiplier * (10000 - decreaseBps)) / 10000;
    }

    /// @notice Rebase up by a percentage
    /// @param increaseBps Basis points to increase
    function rebaseUp(uint256 increaseBps) external {
        rebaseMultiplier = (rebaseMultiplier * (10000 + increaseBps)) / 10000;
    }
}

/// @title ITransferCallback
/// @notice Interface for contracts that want to receive transfer callbacks
interface ITransferCallback {
    function onTokenTransfer(address from, address to, uint256 amount) external;
}

/// @title CallbackToken
/// @notice ERC20 that calls a callback on the recipient during transfer (ERC777-style)
contract CallbackToken is IERC20 {
    string public constant name = "Callback Token";
    string public constant symbol = "CALLBACK";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Track which addresses should receive callbacks
    mapping(address => bool) public callbackEnabled;

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
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "CallbackToken: insufficient allowance");
            allowance[from][msg.sender] = currentAllowance - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "CallbackToken: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);

        // Call callback if enabled for recipient
        if (callbackEnabled[to] && _isContract(to)) {
            ITransferCallback(to).onTokenTransfer(from, to, amount);
        }
        return true;
    }

    /// @notice Enable callbacks for an address
    function enableCallback(address account) external {
        callbackEnabled[account] = true;
    }

    /// @notice Disable callbacks for an address
    function disableCallback(address account) external {
        callbackEnabled[account] = false;
    }

    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}

/// @title FalseReturningToken
/// @notice ERC20 that returns false on failure instead of reverting
/// @dev Tests that SafeERC20 properly handles non-reverting failures
contract FalseReturningToken is IERC20 {
    string public constant name = "False Returning Token";
    string public constant symbol = "FALSE";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Flag to force failures
    bool public shouldFail;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (shouldFail) return false;
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (shouldFail) return false;
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (shouldFail) return false;
        if (allowance[from][msg.sender] < amount) return false;
        if (balanceOf[from] < amount) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice Set whether operations should fail
    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }
}

/// @title NoReturnToken
/// @notice ERC20 that doesn't return a value on transfer (like USDT)
/// @dev Tests that SafeERC20 handles missing return values
contract NoReturnToken {
    string public constant name = "No Return Token";
    string public constant symbol = "NORET";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        // Note: no return value
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "NoReturnToken: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        // Note: no return value
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount, "NoReturnToken: insufficient allowance");
        require(balanceOf[from] >= amount, "NoReturnToken: insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        // Note: no return value
    }
}
