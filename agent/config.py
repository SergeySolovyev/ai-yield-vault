"""
Configuration for the AI Vault agent.

Loads environment variables and defines contract addresses / ABIs
for Sepolia testnet deployment.
"""

import os
import json
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

# ── Network ──────────────────────────────────────────────────────────

CHAIN_ID = 11155111  # Sepolia
RPC_URL = os.getenv("SEPOLIA_RPC_URL", "")
PRIVATE_KEY = os.getenv("KEEPER_PRIVATE_KEY", "")

# ── Contract Addresses (Sepolia) ─────────────────────────────────────

VAULT_ADDRESS = os.getenv("VAULT_ADDRESS", "")
STRATEGY_MANAGER_ADDRESS = os.getenv("STRATEGY_MANAGER_ADDRESS", "")
USDC_ADDRESS = "0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8"

# Aave V3 Sepolia
AAVE_POOL_ADDRESS = "0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951"
# Compound V3 Comet (USDC) Sepolia
COMPOUND_COMET_ADDRESS = "0xAec1F48e02Cfb822Be958B68C7957156EB3F0b6e"

# ── Agent Parameters ─────────────────────────────────────────────────

CHECK_INTERVAL_SECONDS = int(os.getenv("CHECK_INTERVAL", "3600"))  # 1 hour
SCORE_THRESHOLD = float(os.getenv("SCORE_THRESHOLD", "0.05"))      # Min score delta to trigger rebalance
MAX_LOSS_BPS = int(os.getenv("MAX_LOSS_BPS", "50"))                # 0.5% max slippage
EMA_ALPHA = float(os.getenv("EMA_ALPHA", "0.3"))                   # 30% weight on new data

# ── Scoring Weights ──────────────────────────────────────────────────

WEIGHT_APY = float(os.getenv("WEIGHT_APY", "0.40"))
WEIGHT_RISK = float(os.getenv("WEIGHT_RISK", "0.25"))
WEIGHT_COST = float(os.getenv("WEIGHT_COST", "0.20"))
WEIGHT_STABILITY = float(os.getenv("WEIGHT_STABILITY", "0.15"))

# ── EIP-712 Domain ───────────────────────────────────────────────────

EIP712_DOMAIN = {
    "name": "AIVault",
    "version": "1",
    "chainId": CHAIN_ID,
    "verifyingContract": VAULT_ADDRESS,
}

EIP712_TYPES = {
    "RebalanceParams": [
        {"name": "targetAdapterIndex", "type": "uint256"},
        {"name": "maxLossBps", "type": "uint256"},
        {"name": "timestamp", "type": "uint256"},
        {"name": "nonce", "type": "uint256"},
    ],
}

# ── ABI Loading ──────────────────────────────────────────────────────

_PROJECT_ROOT = Path(__file__).parent.parent
# In Docker, ABIs are mounted at /out; locally they're at ../out
_OUT_DIR = Path("/out") if Path("/out").exists() else _PROJECT_ROOT / "out"


def load_abi(contract_name: str) -> list:
    """Load ABI from Foundry's compiled output."""
    abi_path = _OUT_DIR / f"{contract_name}.sol" / f"{contract_name}.json"
    with open(abi_path) as f:
        return json.load(f)["abi"]


def get_vault_abi() -> list:
    return load_abi("AIVault")


def get_strategy_manager_abi() -> list:
    return load_abi("StrategyManager")
