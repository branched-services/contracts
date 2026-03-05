#!/bin/bash
set -euo pipefail

# Infrared Contract Deployment Script
# Uses CREATE3 for deterministic addresses across chains

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRARED_DIR="$(dirname "$SCRIPT_DIR")"
CHAINS_FILE="$SCRIPT_DIR/chains.json"
DEPLOYMENTS_DIR="$SCRIPT_DIR/deployments"

# Auto-source .env from infrared/ directory if it exists
if [[ -f "$INFRARED_DIR/.env" ]]; then
    set -a
    source "$INFRARED_DIR/.env"
    set +a
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  deploy <chain-id>    Deploy contracts to specified chain"
    echo "  dry-run <chain-id>   Simulate deployment without broadcasting"
    echo "  preview <chain-id>   Preview deployment addresses without deploying"
    echo "  verify <chain-id>    Verify deployed contracts on block explorer"
    echo "  list-chains          List supported chains"
    echo ""
    echo "Environment Variables (auto-loaded from infrared/.env):"
    echo "  PRIVATE_KEY          Deployer private key"
    echo "  SAFE_ADDRESS         Safe multi-sig address (required for mainnet, optional for testnet)"
    echo "  <CHAIN>_RPC_URL      RPC URL for the target chain (e.g., ETH_RPC_URL, BASE_RPC_URL)"
    echo "  ETHERSCAN_API_KEY    API key for Etherscan (Ethereum, Sepolia)"
    echo "  BASESCAN_API_KEY     API key for Basescan (Base, Base Sepolia)"
    echo "  SALT_VERSION         Salt version for CREATE3 addresses (default: v1)"
    exit 1
}

check_env() {
    local var_name="$1"
    if [[ -z "${!var_name:-}" ]]; then
        echo -e "${RED}Error: $var_name environment variable is not set${NC}"
        exit 1
    fi
}

get_chain_config() {
    local chain_id="$1"
    local field="$2"
    jq -r ".chains[\"$chain_id\"].$field // empty" "$CHAINS_FILE"
}

# Check if chain is a testnet
get_is_testnet() {
    local chain_id="$1"
    local is_testnet
    is_testnet=$(jq -r ".chains[\"$chain_id\"].isTestnet // false" "$CHAINS_FILE")
    [[ "$is_testnet" == "true" ]]
}

# Validate Safe address format and existence on-chain
validate_safe_address() {
    local safe_addr="$1"
    local rpc_url="$2"

    # Check format: 0x followed by 40 hex characters
    if [[ ! "$safe_addr" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        echo -e "${RED}Error: Invalid SAFE_ADDRESS format${NC}"
        echo "Must be 0x followed by 40 hex characters (e.g., 0x1234...abcd)"
        exit 1
    fi

    # Check Safe exists on-chain
    local code
    code=$(cast code "$safe_addr" --rpc-url "$rpc_url" 2>/dev/null || echo "0x")

    if [[ "$code" == "0x" || -z "$code" ]]; then
        echo -e "${RED}Error: No Safe found at $safe_addr${NC}"
        echo "Verify the address is correct and Safe is deployed on this chain."
        exit 1
    fi
}

# CREATE3 factory address (same on all supported chains)
CREATE3_FACTORY="0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf"

check_create3_factory() {
    local rpc_url="$1"
    local code
    code=$(cast code "$CREATE3_FACTORY" --rpc-url "$rpc_url" 2>/dev/null || echo "0x")

    if [[ "$code" == "0x" || -z "$code" ]]; then
        echo -e "${RED}Error: CREATE3 factory not found at $CREATE3_FACTORY${NC}"
        echo "See docs/evm-deployment.md#factory-deployment for deployment instructions."
        exit 1
    fi
}

list_chains() {
    echo "Supported chains:"
    echo ""
    jq -r '.chains | to_entries[] | "  \(.key): \(.value.displayName) (\(.value.name))"' "$CHAINS_FILE"
}

# Get contracts list from chains.json
get_contracts() {
    jq -r '.contracts[]' "$CHAINS_FILE"
}

# Get contract source path for verification
get_contract_path() {
    local contract="$1"
    if [[ "$contract" == "ExecutionProxy" ]]; then
        echo "src/ExecutionProxy.sol:ExecutionProxy"
    else
        echo "src/weiroll-helpers/${contract}.sol:${contract}"
    fi
}

# Generate deployment registry from broadcast logs
generate_registry() {
    local chain_id="$1"
    local deployer="$2"
    local rpc_url="$3"

    local broadcast_file="$SCRIPT_DIR/broadcast/DeployCreate3.s.sol/$chain_id/run-latest.json"
    local registry_file="$DEPLOYMENTS_DIR/$chain_id.json"

    if [[ ! -f "$broadcast_file" ]]; then
        echo -e "${RED}Error: No broadcast logs found at $broadcast_file${NC}"
        echo "Deployment may have failed - check forge output above."
        return 1
    fi

    # Check if registry file exists
    if [[ -f "$registry_file" ]]; then
        echo -e "${YELLOW}Warning: Overwriting existing deployments/$chain_id.json${NC}"
    fi

    local chain_name
    chain_name=$(get_chain_config "$chain_id" "displayName")
    local salt_version="${SALT_VERSION:-v1}"
    local owner="${SAFE_ADDRESS:-$deployer}"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build contracts object from broadcast
    local contracts_json="{"
    local first=true

    while IFS= read -r contract; do
        # Generate the salt for this contract (matches Solidity keccak256(abi.encodePacked(prefix, contractName)))
        local salt_prefix="infrared.contracts.${salt_version}"
        local packed
        packed=$(printf '%s%s' "$salt_prefix" "$contract")
        local salt
        salt=$(cast keccak "$packed")

        # Find the contract creation in broadcast (look for CREATE3 factory calls)
        # The deployed address is predicted by CREATE3
        local predicted_addr
        predicted_addr=$(cast call "$CREATE3_FACTORY" "getDeployed(address,bytes32)(address)" "$deployer" "$salt" --rpc-url "$rpc_url" 2>/dev/null || echo "")

        if [[ -z "$predicted_addr" || "$predicted_addr" == "0x0000000000000000000000000000000000000000" ]]; then
            echo -e "${YELLOW}Warning: Could not determine address for $contract${NC}"
            continue
        fi

        # Find tx hash and block from broadcast
        local tx_hash
        tx_hash=$(jq -r --arg addr "${predicted_addr,,}" '.transactions[] | select(.contractAddress != null and (.contractAddress | ascii_downcase) == $addr) | .hash // empty' "$broadcast_file" | head -1)

        # If not found directly, look for transactions to the factory
        if [[ -z "$tx_hash" ]]; then
            tx_hash=$(jq -r '.transactions[0].hash // empty' "$broadcast_file")
        fi

        local block_number
        block_number=$(jq -r --arg hash "$tx_hash" '.receipts[] | select(.transactionHash == $hash) | .blockNumber // empty' "$broadcast_file" | head -1)

        # Convert hex block number to decimal if needed
        if [[ "$block_number" =~ ^0x ]]; then
            block_number=$((block_number))
        fi

        if [[ "$first" == "true" ]]; then
            first=false
        else
            contracts_json+=","
        fi

        contracts_json+="\"$contract\":{\"address\":\"$predicted_addr\",\"salt\":\"$salt\",\"verified\":false"
        if [[ -n "$tx_hash" ]]; then
            contracts_json+=",\"txHash\":\"$tx_hash\""
        fi
        if [[ -n "$block_number" && "$block_number" != "null" ]]; then
            contracts_json+=",\"blockNumber\":$block_number"
        fi
        contracts_json+="}"
    done < <(get_contracts)

    contracts_json+="}"

    # Write registry file
    cat > "$registry_file" << EOF
{
  "chainId": $chain_id,
  "chainName": "$chain_name",
  "deployedAt": "$timestamp",
  "deployer": "$deployer",
  "owner": "$owner",
  "contracts": $contracts_json,
  "create3Factory": "$CREATE3_FACTORY"
}
EOF

    echo ""
    echo -e "${GREEN}Registry generated: $registry_file${NC}"
}

deploy() {
    local chain_id="$1"

    # Validate chain
    local chain_name
    chain_name=$(get_chain_config "$chain_id" "name")
    if [[ -z "$chain_name" ]]; then
        echo -e "${RED}Error: Chain ID $chain_id not found in chains.json${NC}"
        list_chains
        exit 1
    fi

    local display_name
    display_name=$(get_chain_config "$chain_id" "displayName")
    echo -e "${GREEN}Deploying to $display_name (Chain ID: $chain_id)${NC}"

    # Check required env vars
    check_env "PRIVATE_KEY"

    local rpc_env
    rpc_env=$(get_chain_config "$chain_id" "rpcEnv")
    check_env "$rpc_env"
    local rpc_url="${!rpc_env}"

    # Get deployer address from private key
    local deployer
    deployer=$(cast wallet address "$PRIVATE_KEY")

    # Determine owner address based on testnet/mainnet
    local owner_address
    if get_is_testnet "$chain_id"; then
        # Testnet: use Safe if provided, otherwise deployer
        if [[ -n "${SAFE_ADDRESS:-}" ]]; then
            validate_safe_address "$SAFE_ADDRESS" "$rpc_url"
            owner_address="$SAFE_ADDRESS"
            echo "Owner: $owner_address (Safe multi-sig)"
        else
            owner_address="$deployer"
            echo "Owner: $owner_address (deployer EOA - testnet)"
        fi
    else
        # Mainnet: require Safe address
        if [[ -z "${SAFE_ADDRESS:-}" ]]; then
            echo -e "${RED}Error: Mainnet deployment requires SAFE_ADDRESS${NC}"
            echo "Set SAFE_ADDRESS in infrared/.env to your Safe multi-sig address."
            echo "See docs/evm-deployment.md for Safe setup instructions."
            exit 1
        fi
        validate_safe_address "$SAFE_ADDRESS" "$rpc_url"
        owner_address="$SAFE_ADDRESS"
        echo "Owner: $owner_address (Safe multi-sig)"
    fi

    # Verify CREATE3 factory exists
    check_create3_factory "$rpc_url"

    # Show salt version being used
    local salt_version="${SALT_VERSION:-v1}"
    echo "Salt version: $salt_version"
    echo "Deployer: $deployer"

    # Export owner address for forge script
    export OWNER_ADDRESS="$owner_address"

    # Run deployment
    cd "$SCRIPT_DIR"
    forge script script/DeployCreate3.s.sol:DeployCreate3 \
        --rpc-url "$rpc_url" \
        --private-key "$PRIVATE_KEY" \
        --broadcast \
        -vvv

    echo ""
    echo -e "${GREEN}Deployment complete!${NC}"

    # Generate deployment registry
    generate_registry "$chain_id" "$deployer" "$rpc_url"

    echo ""
    echo "Next steps:"
    echo "  1. Run '$0 verify $chain_id' to verify contracts on block explorer"
}

preview() {
    local chain_id="$1"

    # Validate chain
    local chain_name
    chain_name=$(get_chain_config "$chain_id" "name")
    if [[ -z "$chain_name" ]]; then
        echo -e "${RED}Error: Chain ID $chain_id not found in chains.json${NC}"
        list_chains
        exit 1
    fi

    local display_name
    display_name=$(get_chain_config "$chain_id" "displayName")
    echo -e "${YELLOW}Previewing addresses for $display_name (Chain ID: $chain_id)${NC}"

    local rpc_env
    rpc_env=$(get_chain_config "$chain_id" "rpcEnv")
    check_env "$rpc_env"
    local rpc_url="${!rpc_env}"

    # Show salt version being used
    local salt_version="${SALT_VERSION:-v1}"
    echo "Salt version: $salt_version"

    cd "$SCRIPT_DIR"
    forge script script/DeployCreate3.s.sol:DeployCreate3 \
        --rpc-url "$rpc_url" \
        --sig "preview()" \
        -vvv
}

dry_run() {
    local chain_id="$1"

    # Validate chain
    local chain_name
    chain_name=$(get_chain_config "$chain_id" "name")
    if [[ -z "$chain_name" ]]; then
        echo -e "${RED}Error: Chain ID $chain_id not found in chains.json${NC}"
        list_chains
        exit 1
    fi

    local display_name
    display_name=$(get_chain_config "$chain_id" "displayName")
    echo -e "${YELLOW}Dry-run deployment for $display_name (Chain ID: $chain_id)${NC}"

    # Check required env vars
    check_env "PRIVATE_KEY"

    local rpc_env
    rpc_env=$(get_chain_config "$chain_id" "rpcEnv")
    check_env "$rpc_env"
    local rpc_url="${!rpc_env}"

    # Verify CREATE3 factory exists
    check_create3_factory "$rpc_url"

    # Show salt version being used
    local salt_version="${SALT_VERSION:-v1}"
    echo "Salt version: $salt_version"
    echo ""

    # Run deployment simulation (no --broadcast)
    cd "$SCRIPT_DIR"
    echo "=== Compiling contracts ==="
    if forge build; then
        echo -e "${GREEN}Compilation successful${NC}"
    else
        echo -e "${RED}Compilation failed${NC}"
        exit 1
    fi
    echo ""

    echo "=== Simulating deployment ==="
    forge script script/DeployCreate3.s.sol:DeployCreate3 \
        --rpc-url "$rpc_url" \
        --private-key "$PRIVATE_KEY" \
        -vvv

    echo ""
    echo -e "${GREEN}Dry-run complete!${NC}"
    echo ""
    echo "To execute the actual deployment, run:"
    echo "  $0 deploy $chain_id"
}

verify() {
    local chain_id="$1"

    # Validate chain
    local chain_name
    chain_name=$(get_chain_config "$chain_id" "name")
    if [[ -z "$chain_name" ]]; then
        echo -e "${RED}Error: Chain ID $chain_id not found in chains.json${NC}"
        list_chains
        exit 1
    fi

    local display_name
    display_name=$(get_chain_config "$chain_id" "displayName")
    echo -e "${GREEN}Verifying contracts on $display_name${NC}"

    # Get API key env var
    local api_key_env
    api_key_env=$(get_chain_config "$chain_id" "explorer.apiKeyEnv")
    check_env "$api_key_env"
    local api_key="${!api_key_env}"

    local rpc_env
    rpc_env=$(get_chain_config "$chain_id" "rpcEnv")
    check_env "$rpc_env"
    local rpc_url="${!rpc_env}"

    # Get explorer API URL
    local api_url
    api_url=$(get_chain_config "$chain_id" "explorer.apiUrl")

    # Read deployment registry if exists
    local registry_file="$DEPLOYMENTS_DIR/$chain_id.json"
    if [[ ! -f "$registry_file" ]]; then
        echo -e "${YELLOW}Warning: No deployment registry found at $registry_file${NC}"
        echo "Please create the registry file with deployed addresses first."
        exit 1
    fi

    cd "$SCRIPT_DIR"

    # Get owner address from registry
    local owner_addr
    owner_addr=$(jq -r '.deployer' "$registry_file")

    # Verify all contracts from chains.json
    while IFS= read -r contract; do
        local addr
        addr=$(jq -r ".contracts.${contract}.address" "$registry_file")
        local path
        path=$(get_contract_path "$contract")

        echo "Verifying $contract at $addr..."

        if [[ "$contract" == "ExecutionProxy" ]]; then
            # ExecutionProxy has constructor arg: owner
            forge verify-contract "$addr" "$path" \
                --chain-id "$chain_id" \
                --verifier-url "$api_url" \
                --etherscan-api-key "$api_key" \
                --constructor-args "$(cast abi-encode 'constructor(address)' "$owner_addr")" \
                --watch || echo -e "${YELLOW}$contract verification may have failed or already verified${NC}"
        else
            # Stateless helpers (no constructor args)
            forge verify-contract "$addr" "$path" \
                --chain-id "$chain_id" \
                --verifier-url "$api_url" \
                --etherscan-api-key "$api_key" \
                --watch || echo -e "${YELLOW}$contract verification may have failed or already verified${NC}"
        fi
    done < <(get_contracts)

    echo ""
    echo -e "${GREEN}Verification complete!${NC}"
}

# Main
if [[ $# -lt 1 ]]; then
    usage
fi

case "$1" in
    deploy)
        [[ $# -lt 2 ]] && usage
        deploy "$2"
        ;;
    dry-run)
        [[ $# -lt 2 ]] && usage
        dry_run "$2"
        ;;
    preview)
        [[ $# -lt 2 ]] && usage
        preview "$2"
        ;;
    verify)
        [[ $# -lt 2 ]] && usage
        verify "$2"
        ;;
    list-chains)
        list_chains
        ;;
    *)
        usage
        ;;
esac
