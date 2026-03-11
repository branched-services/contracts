# EVM Contract Deployment Guide

Deploy Infrared's Solidity contracts with deterministic addresses using CREATE3.

## Prerequisites

### Required Software
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)
- `jq` for JSON processing

### Environment Variables

Add the following to `infrared/.env` (auto-loaded by deploy script):

```bash
# Contract deployment
PRIVATE_KEY=0x...                                      # Deployer private key (NEVER commit)
SAFE_ADDRESS=0x...                                     # Safe multi-sig (required for mainnet)
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
BASE_SEPOLIA_RPC_URL=https://base-sepolia.g.alchemy.com/v2/YOUR_KEY
ETH_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_API_KEY
BASESCAN_API_KEY=YOUR_BASESCAN_API_KEY
```

**Note:** `SAFE_ADDRESS` is required for mainnet deployments. The script will fail if not set. For testnet, it's optional - the deployer EOA will be used as owner if not provided.

See `infrared/.env.example` for the full template.

### Contracts Deployed

| Contract        | Purpose                                      |
| --------------- | -------------------------------------------- |
| ExecutionProxy  | Weiroll VM executor with slippage protection |
| Tupler          | Byte tuple extraction helper                 |
| Integer         | Comparison utilities                         |
| Bytes32         | Type conversion helper                       |
| BlockchainInfo  | Block data reader                            |
| ArraysConverter | Array manipulation                           |

## CREATE3 Deterministic Deployment

### How It Works

CREATE3 produces addresses determined only by:
1. Factory address (`0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf`)
2. Deployer address
3. Salt

This means identical addresses across any EVM chain when using the same deployer and salt.

### Salt Strategy

Salts are generated deterministically:
```solidity
keccak256(abi.encodePacked("infrared.contracts.v1", contractName))
```

Configure salt version via environment variable for future contract versions:
```bash
SALT_VERSION=v2 ./deploy.sh deploy 1  # Deploy to different addresses
```

### Address Prediction

Preview addresses before deploying:
```bash
cd contracts  # github.com/branched-services/contracts
./deploy.sh preview 11155111  # Sepolia
./deploy.sh preview 84532     # Base Sepolia
```

### Dry-Run (Simulation)

Test deployment without broadcasting transactions:
```bash
./deploy.sh dry-run 11155111  # Compile + simulate, no broadcast
```

## Testnet Deployment

### Step 1: Deploy to Sepolia

```bash
cd contracts  # github.com/branched-services/contracts

# Preview addresses first
./deploy.sh preview 11155111

# Dry-run to verify (optional)
./deploy.sh dry-run 11155111

# Deploy (auto-generates deployments/11155111.json)
./deploy.sh deploy 11155111
```

### Step 2: Verify Contracts

```bash
./deploy.sh verify 11155111
```

### Step 3: Deploy to Base Sepolia

Repeat for Base Sepolia:
```bash
./deploy.sh preview 84532
./deploy.sh deploy 84532  # Auto-generates deployments/84532.json
./deploy.sh verify 84532
```

## Mainnet Deployment

### Pre-Deployment Checklist

- [ ] Testnet deployment successful on both Sepolia and Base Sepolia
- [ ] All contracts verified on testnet explorers
- [ ] Integration tests pass against testnet contracts
- [ ] Safe multi-sig created and `SAFE_ADDRESS` set in `.env`
- [ ] Sufficient ETH/gas in deployer wallet

### Step 1: Create Safe Multi-sig

1. Go to [Safe](https://app.safe.global)
2. Create new Safe with 2-of-3 threshold
3. Add 3 signer addresses
4. Deploy Safe to target chain
5. Add `SAFE_ADDRESS=0x...` to `infrared/.env`

### Step 2: Deploy Contracts

The deploy script automatically:
- Validates Safe exists on-chain before deploying
- Deploys ExecutionProxy with Safe as owner (or transfers ownership if already deployed)
- Records Safe as owner in the deployment registry

```bash
# Ethereum Mainnet (requires SAFE_ADDRESS)
./deploy.sh deploy 1

# Base (requires SAFE_ADDRESS)
./deploy.sh deploy 8453
```

### Step 3: Verify Contracts

```bash
./deploy.sh verify 1
./deploy.sh verify 8453
```

### Step 4: Verify Ownership

Confirm ExecutionProxy is owned by the Safe:
```bash
cast call <EXECUTION_PROXY_ADDRESS> "owner()(address)" --rpc-url $ETH_RPC_URL
# Should return your SAFE_ADDRESS
```

## Post-Deployment Verification

### Automated Checks

```bash
cd contracts  # github.com/branched-services/contracts
forge script script/Verify.s.sol:VerifyDeployment \
  --rpc-url $ETH_RPC_URL \
  --sig "run(uint256)" 1
```

### Manual Checklist

- [ ] All 6 contracts have code at expected addresses
- [ ] ExecutionProxy owner is Safe address (mainnet) or deployer (testnet)
- [ ] Contracts verified on block explorers
- [ ] `rescue()` function callable by owner only
- [ ] Test execution via API succeeds

### Safe Configuration Verification

1. Verify Safe at [app.safe.global](https://app.safe.global)
2. Confirm 3 signers present
3. Confirm 2-of-3 threshold
4. Test with low-value transaction

## Adding New Chains

1. Add chain config to `chains.json`:
```json
{
  "chains": {
    "<CHAIN_ID>": {
      "name": "<chain-name>",
      "displayName": "<Chain Name>",
      "create3Factory": "0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf",
      "explorer": {
        "url": "https://...",
        "apiUrl": "https://api...",
        "apiKeyEnv": "<EXPLORER_API_KEY>"
      },
      "rpcEnv": "<CHAIN>_RPC_URL",
      "isTestnet": false
    }
  }
}
```

2. Add new contracts to the `contracts` array if needed:
```json
{
  "contracts": ["ExecutionProxy", "Tupler", "Integer", "Bytes32", "BlockchainInfo", "ArraysConverter"]
}
```

3. Set environment variables and deploy.

## Idempotency

The deployment script is idempotent:
- Checks if contract exists at predicted address before deploying
- Skips already-deployed contracts
- Safe to re-run after partial failures

```
$ ./deploy.sh deploy 1
ExecutionProxy already deployed at: 0x...
Tupler already deployed at: 0x...
Integer deployed at: 0x...  # Only deploys missing contracts
```

## Upgradeability Patterns

### Current Design: Immutable

All contracts are deployed as immutable (non-upgradeable):
- Simpler security model
- No proxy overhead
- Deterministic addresses forever

### Future Options

If upgradeability is needed:

**UUPS (Universal Upgradeable Proxy Standard)**
- Upgrade logic in implementation contract
- Smaller proxy bytecode
- [OpenZeppelin UUPS](https://docs.openzeppelin.com/contracts/5.x/api/proxy#UUPSUpgradeable)

**Transparent Proxy**
- Upgrade logic in proxy
- Admin cannot call implementation functions
- [OpenZeppelin TransparentProxy](https://docs.openzeppelin.com/contracts/5.x/api/proxy#TransparentUpgradeableProxy)

**Migration Strategy**
1. Deploy new version via CREATE3 with new salt (e.g., `v2`)
2. Update API to use new addresses
3. Keep old contracts for existing integrations

## Troubleshooting

### Verification Fails
- Check API key is correct for target explorer
- Some explorers have rate limits; wait and retry
- Verify constructor args match exactly

### CREATE3 Factory Not Deployed {#factory-deployment}
The factory is deployed on most EVM chains at `0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf`. If missing:
1. Check [create3-factory repo](https://github.com/ZeframLou/create3-factory) for deployment instructions
2. Deploy factory first, then contracts
3. The deploy script will fail with a clear error if factory is missing

## Partial Failure Recovery

The deployment script is idempotent - safe to re-run after failures.

### How It Works
- Checks if contract exists at predicted address before deploying
- Skips already-deployed contracts
- Only deploys missing contracts

### Recovery Steps

1. **Identify what deployed**: Check forge output or run `./deploy.sh preview <chain-id>`
2. **Re-run deployment**: `./deploy.sh deploy <chain-id>` - only missing contracts will deploy
3. **Verify registry**: The auto-generated `deployments/<chain-id>.json` will include all contracts

### Example
```
$ ./deploy.sh deploy 1
ExecutionProxy already deployed at: 0x...
Tupler already deployed at: 0x...
Integer deployed at: 0x...  # Only deploys missing contracts
```
