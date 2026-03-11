#!/bin/bash
# Infrared Engine Contracts - Initialization Script
# Run this script to set up all Foundry dependencies

set -e

echo "🔧 Initializing Infrared Engine Contracts..."
echo ""

# Check if forge is installed
if ! command -v forge &> /dev/null; then
    echo "❌ Foundry not found. Installing..."
    curl -L https://foundry.paradigm.xyz | bash
    source ~/.bashrc 2>/dev/null || source ~/.zshrc 2>/dev/null || true
    foundryup
else
    echo "✅ Foundry is installed"
fi

# Navigate to repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "📦 Installing dependencies..."

forge soldeer install

echo ""
echo "🔨 Building contracts..."
forge build

echo ""
echo "🧪 Running tests..."
forge test

echo ""
echo "✅ Setup complete!"
echo ""
echo "Useful commands:"
echo "  forge build          - Compile contracts"
echo "  forge test           - Run tests"
echo "  forge test -vvv      - Run tests with verbose output"
echo "  forge test --gas-report  - Run tests with gas reporting"
echo "  forge fmt            - Format Solidity files"
echo ""
