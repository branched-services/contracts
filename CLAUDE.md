# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrared Contracts -- Solidity contracts for the Infrared execution layer. The core `ExecutionProxy` contract executes Weiroll VM programs atomically with slippage verification. Includes helper contracts (`Tupler`, `Integer`, `Bytes32`, `BlockchainInfo`, `ArraysConverter`) that provide Weiroll-compatible utilities.

License: BUSL-1.1

## Build Commands

```bash
forge build                        # Compile
forge test                         # Run all tests
forge test -vvv                    # Verbose test output
forge test --match-test testName   # Run single test
forge test --match-contract Name   # Run tests in one contract
forge fmt                          # Format code
forge fmt --check                  # Check formatting (CI uses this)
forge soldeer install              # Install dependencies
```

## Deployment

Uses CREATE3 for deterministic cross-chain addresses. Factory: `0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf`.

```bash
./deploy.sh preview <chain-id>    # Preview addresses
./deploy.sh dry-run <chain-id>    # Simulate deployment
./deploy.sh deploy <chain-id>     # Deploy + generate registry
./deploy.sh verify <chain-id>     # Verify on explorer
./deploy.sh list-chains           # Show supported chains
```

Signs with a Foundry-encrypted keystore (`~/.foundry/keystores/<name>`). Create one via `./setup-deployer-wallet.sh <name>`. Config via `.env` (see `.env.example`). Key env vars: `KEYSTORE_ACCOUNT`, `DEPLOYER_ADDRESS`, `SAFE_ADDRESS`, `ROUTER_LIQUIDATOR`, `<CHAIN>_RPC_URL`.

Supported chains: Ethereum (1), Base (8453), Sepolia (11155111), Base Sepolia (84532).

## Architecture

- **Solidity 0.8.24**, optimizer at 200 runs
- **Dependencies** managed via Soldeer (stored in `dependencies/`)
- **Import remappings**: `forge-std/`, `@openzeppelin/contracts/`, `@weiroll/`, `solmate/`

### Core Contract

`src/ExecutionProxy.sol` inherits from Weiroll `VM`, OpenZeppelin `ReentrancyGuard` + `Ownable`, uses `SafeERC20`. Two entry points:
- `execute()` -- multi-output with array of `OutputSpec` structs
- `executeSingle()` -- gas-optimized single-output variant

Both run the Weiroll program first, then verify slippage and transfer tokens. Native ETH is represented by sentinel address `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`.

### Weiroll Helpers

`src/weiroll-helpers/` -- stateless utility contracts designed for use as Weiroll command targets (comparison ops, type conversion, block data access, array manipulation, tuple extraction).

### Test Structure

- `test/ExecutionProxy.t.sol` -- main test suite
- `test/WeirollTestHelper.t.sol` -- helper utility tests
- `test/helpers/WeirollTestHelper.sol` -- library for encoding Weiroll commands and building state arrays in tests
- `test/mocks/` -- MockDEX, adversarial tokens (fee-on-transfer, rebasing, callback, false-returning), reentrancy attacker

## CI Pipeline

GitHub Actions runs: `forge build`, `forge test -vvv`, `forge fmt --check`, Slither static analysis, and deployment dry-runs.
