#!/bin/bash
# ============================================================
# AI Yield Vault — Droplet Deployment Script
# Run this on your DigitalOcean droplet
# ============================================================
set -e

echo "=========================================="
echo "  AI Yield Vault — Deployment Setup"
echo "=========================================="

# Step 1: Install Docker (if not present)

if ! command -v docker &> /dev/null; then
    echo "[1/6] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    echo "Docker installed."
else
    echo "[1/6] Docker already installed."
fi

if ! command -v docker compose &> /dev/null; then
    echo "Installing Docker Compose plugin..."
    apt-get update -qq && apt-get install -y -qq docker-compose-plugin
fi

# Step 2: Install Foundry

if ! command -v forge &> /dev/null; then
    echo "[2/6] Installing Foundry..."
    curl -L https://foundry.paradigm.xyz | bash
    export PATH="$HOME/.foundry/bin:$PATH"
    foundryup
    echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
    echo "Foundry installed."
else
    echo "[2/6] Foundry already installed."
fi

# Step 3: Clone / copy project

PROJECT_DIR="$HOME/ai-yield-vault"

if [ -d "$PROJECT_DIR" ]; then
    echo "[3/6] Project directory exists, pulling updates..."
    cd "$PROJECT_DIR" && git pull 2>/dev/null || true
else
    echo "[3/6] Creating project directory..."
    mkdir -p "$PROJECT_DIR"
    echo "IMPORTANT: Copy the project files to $PROJECT_DIR"
    echo "  Option A: git clone <your-repo-url> $PROJECT_DIR"
    echo "  Option B: scp -r . root@<droplet-ip>:$PROJECT_DIR/"
fi

cd "$PROJECT_DIR"

# Step 4: Install Solidity deps

echo "[4/6] Installing Foundry dependencies..."
if [ -f "foundry.toml" ]; then
    forge install 2>/dev/null || true
    forge build
    echo "Contracts compiled."
else
    echo "WARNING: foundry.toml not found. Copy project files first!"
fi

# Step 5: Check .env

echo "[5/6] Checking .env configuration..."
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        cp .env.example .env
        echo "Created .env from .env.example"
        echo ""
        echo "============================================"
        echo "  EDIT .env WITH YOUR KEYS BEFORE DEPLOYING"
        echo "============================================"
        echo ""
        echo "  nano $PROJECT_DIR/.env"
        echo ""
    fi
else
    echo ".env exists."
fi

# Step 6: Summary

echo "[6/6] Setup complete!"
echo ""
echo "=========================================="
echo "  Next Steps:"
echo "=========================================="
echo ""
echo "  1. Edit .env:    nano .env"
echo ""
echo "  2. Deploy contracts to Sepolia:"
echo "     source .env"
echo "     forge script script/Deploy.s.sol:Deploy \\"
echo "       --rpc-url \$SEPOLIA_RPC_URL \\"
echo "       --broadcast --verify"
echo ""
echo "  3. Copy deployed addresses to .env:"
echo "     VAULT_ADDRESS=0x..."
echo "     STRATEGY_MANAGER_ADDRESS=0x..."
echo ""
echo "  4. Start agent:"
echo "     docker compose up -d"
echo ""
echo "  5. Check logs:"
echo "     docker compose logs -f ai-agent"
echo ""
echo "=========================================="
