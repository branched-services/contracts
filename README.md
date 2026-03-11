# Infrared Contracts

Solidity contracts for the Infrared execution layer. The `ExecutionProxy` executes Weiroll programs atomically with slippage verification.

## Contracts

| Contract          | Description                                           |
| ----------------- | ----------------------------------------------------- |
| `ExecutionProxy`  | Weiroll VM executor with multi-output slippage checks |
| `Tupler`          | Byte tuple extraction helper                          |
| `Integer`         | Comparison utilities                                  |
| `Bytes32`         | Type conversion                                       |
| `BlockchainInfo`  | Block data reader                                     |
| `ArraysConverter` | Array manipulation                                    |

## Getting Started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation). Run the init script to install dependencies, build, and test:

```bash
./init.sh
```

Or manually:

```bash
forge soldeer install
forge build
forge test
```

## Build

```bash
forge build
forge test
forge fmt --check
```

## Deployment

Uses CREATE3 for deterministic addresses across chains.

```bash
./deploy.sh preview <chain-id>     # Preview addresses
./deploy.sh dry-run <chain-id>     # Simulate deployment
./deploy.sh deploy <chain-id>      # Deploy + generate registry
./deploy.sh verify <chain-id>      # Verify on block explorer
./deploy.sh list-chains            # Show supported chains
```

Supports Trezor, Ledger, and private key signing. Copy `.env.example` to `.env` and configure:

- `WALLET_TYPE` -- `trezor`, `ledger`, or `privatekey` (auto-detected from `PRIVATE_KEY` if unset)
- `DEPLOYER_ADDRESS` -- required for hardware wallets
- `SAFE_ADDRESS` -- Gnosis Safe multisig, required for mainnet
- `<CHAIN>_RPC_URL` -- RPC endpoint for target chain

## License

[BUSL-1.1](LICENSE)
