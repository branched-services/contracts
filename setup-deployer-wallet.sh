#!/bin/bash
set -euo pipefail

# Create an encrypted keystore for an Infrared deployment role.
#
# Usage:
#   ./setup-deployer-wallet.sh [account-name]
#
# Generates a fresh keypair and encrypts it under a password you set, in a
# single step via 'cast wallet new'. The plaintext private key never appears
# on stdout or on disk -- only the encrypted JSON keystore at
# ~/.foundry/keystores/<account-name>.
#
# Run once for each role you want a hot wallet for, e.g.:
#   ./setup-deployer-wallet.sh infrared-deployer
#   ./setup-deployer-wallet.sh infrared-liquidator

ACCOUNT_NAME="${1:-infrared-deployer}"
KEYSTORE_DIR="${HOME}/.foundry/keystores"
KEYSTORE_PATH="${KEYSTORE_DIR}/${ACCOUNT_NAME}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if ! command -v cast >/dev/null 2>&1; then
    echo -e "${RED}Error: 'cast' (Foundry) not found in PATH. Install via foundryup.${NC}" >&2
    exit 1
fi

if [[ -e "$KEYSTORE_PATH" ]]; then
    echo -e "${RED}Error: keystore '$ACCOUNT_NAME' already exists at $KEYSTORE_PATH${NC}" >&2
    echo "Choose a different name: $0 <account-name>" >&2
    exit 1
fi

mkdir -p "$KEYSTORE_DIR"
chmod 700 "$KEYSTORE_DIR"

echo -e "${GREEN}Creating encrypted keystore '$ACCOUNT_NAME'${NC}"
echo ""
echo -e "${YELLOW}You will be prompted for a password.${NC}"
echo -e "${YELLOW}Use a strong password and store it in a password manager.${NC}"
echo -e "${YELLOW}If you lose the password, the keystore is unrecoverable.${NC}"
echo ""

# cast generates the key and encrypts it in one process; the private key
# never touches stdout or disk in plaintext. Tee its stdout so the user
# still sees cast's output while we capture the address line.
TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

cast wallet new "$KEYSTORE_DIR" "$ACCOUNT_NAME" | tee "$TMP_OUT"

ADDRESS=$(grep -i '^Address:' "$TMP_OUT" | awk '{print $2}')

if [[ -z "$ADDRESS" || ! "$ADDRESS" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    echo -e "${RED}Error: failed to parse address from cast output${NC}" >&2
    exit 1
fi

chmod 600 "$KEYSTORE_PATH"

echo ""
echo -e "${GREEN}Keystore created: $KEYSTORE_PATH${NC}"
echo "Address: $ADDRESS"
echo ""
echo "Add to .env (deployer role):"
echo "  KEYSTORE_ACCOUNT=$ACCOUNT_NAME"
echo "  DEPLOYER_ADDRESS=$ADDRESS"
echo ""
echo "Or, for the Router liquidator role, set:"
echo "  ROUTER_LIQUIDATOR=$ADDRESS"
echo ""
echo "Next steps:"
echo "  1. Fund $ADDRESS with native gas on the target chain(s)."
echo "  2. ./deploy.sh dry-run <chain-id>     # simulate, no password needed"
echo "  3. ./deploy.sh deploy <chain-id>      # broadcasts; prompts for keystore password"
