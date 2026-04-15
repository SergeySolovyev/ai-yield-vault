"""
AI Vault Agent — Main Loop

The agent continuously:
  1. Reads on-chain data (APY, utilization, TVL, gas price)
  2. Applies EMA smoothing to rates
  3. Scores each protocol using Multi-Criteria Decision Making (MCDM)
  4. If score delta exceeds threshold: sign & submit rebalance tx
  5. Logs every decision (rebalance or hold) for auditability

Usage:
    python main.py                 # Run the agent loop
    python main.py --once          # Run a single check and exit
    python main.py --dry-run       # Score without submitting tx
"""

import argparse
import logging
import sys
import time

from web3 import Web3

import config
from data_reader import DataReader
from scoring import evaluate
from signer import sign_rebalance_params

# Logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("agent.log", mode="a"),
    ],
)
log = logging.getLogger("ai-vault-agent")

# EMA State

_smoothed_rates: dict[int, float] = {}  # adapter_index -> smoothed APY


def ema_smooth(current: float, previous: float | None, alpha: float) -> float:
    """Exponential Moving Average: new = alpha * current + (1 - alpha) * previous."""
    if previous is None:
        return current
    return alpha * current + (1.0 - alpha) * previous


# Main Agent Logic


def run_check(w3: Web3, reader: DataReader, dry_run: bool = False) -> bool:
    """
    Execute one cycle of the agent: read -> score -> decide -> act.

    Returns True if a rebalance was submitted.
    """
    log.info("=" * 60)
    log.info("Starting agent check cycle")

    # 1. Read on-chain data
    try:
        protocols = reader.read_all()
    except Exception as e:
        log.error(f"Failed to read on-chain data: {e}")
        return False

    gas_price_wei = reader.get_gas_price()
    estimated_gas = 200_000  # Conservative estimate for rebalance tx
    gas_cost_eth = (gas_price_wei * estimated_gas) / 1e18

    log.info(f"Gas price: {gas_price_wei / 1e9:.2f} Gwei | Est. rebalance cost: {gas_cost_eth:.6f} ETH")

    # 2. EMA smooth rates
    protocol_data = []
    for p in protocols:
        smoothed_apy = ema_smooth(p.apy, _smoothed_rates.get(p.adapter_index), config.EMA_ALPHA)
        _smoothed_rates[p.adapter_index] = smoothed_apy
        tvl_delta = reader.get_tvl_delta(p)

        log.info(
            f"  [{p.name}] APY: {p.apy*100:.2f}% (smoothed: {smoothed_apy*100:.2f}%) | "
            f"Util: {p.utilization*100:.1f}% | TVL: {p.tvl:,.0f} | TVL Δ: {tvl_delta*100:.2f}%"
        )

        protocol_data.append({
            "adapter_index": p.adapter_index,
            "name": p.name,
            "apy": smoothed_apy,
            "utilization": p.utilization,
            "tvl_delta": tvl_delta,
        })

    # 3. Read current vault state
    vault = w3.eth.contract(
        address=Web3.to_checksum_address(config.VAULT_ADDRESS),
        abi=config.get_vault_abi(),
    )
    current_adapter_index = vault.functions.activeAdapterIndex().call()
    nonce = w3.eth.contract(
        address=Web3.to_checksum_address(config.STRATEGY_MANAGER_ADDRESS),
        abi=config.get_strategy_manager_abi(),
    ).functions.rebalanceNonce().call()

    log.info(f"Current active adapter: {current_adapter_index} | Nonce: {nonce}")

    # 4. Score and decide
    decision = evaluate(protocol_data, current_adapter_index, gas_cost_eth)

    for s in decision.scores:
        log.info(
            f"  [{s.name}] Score: {s.total_score:.4f} "
            f"(APY:{s.apy_score:.3f} Risk:{s.risk_score:.3f} "
            f"Cost:{s.cost_score:.3f} Stab:{s.stability_score:.3f})"
        )

    log.info(
        f"Decision: {'REBALANCE' if decision.should_rebalance else 'HOLD'} | "
        f"Current score: {decision.current_score:.4f} | "
        f"Best score: {decision.target_score:.4f} | "
        f"Delta: {decision.score_delta:.4f} (threshold: {config.SCORE_THRESHOLD})"
    )

    # 5. Execute if needed
    if not decision.should_rebalance:
        log.info("Holding current position.")
        return False

    if dry_run:
        log.info("[DRY RUN] Would rebalance to adapter %d — skipping tx", decision.target_index)
        return False

    # 6. Sign and submit
    log.info(f"Signing rebalance -> adapter {decision.target_index}")
    signed = sign_rebalance_params(
        target_adapter_index=decision.target_index,
        max_loss_bps=config.MAX_LOSS_BPS,
        nonce=nonce,
    )
    log.info(f"Signed by: {signed['signer']} at timestamp {signed['timestamp']}")

    try:
        tx = vault.functions.rebalance(
            (
                signed["params"]["targetAdapterIndex"],
                signed["params"]["maxLossBps"],
                signed["params"]["timestamp"],
                signed["params"]["nonce"],
            ),
            bytes.fromhex(signed["signature"]),
        ).build_transaction({
            "from": signed["signer"],
            "nonce": w3.eth.get_transaction_count(signed["signer"]),
            "gas": 500_000,
            "maxFeePerGas": gas_price_wei * 2,
            "maxPriorityFeePerGas": w3.to_wei(1, "gwei"),
        })

        signed_tx = w3.eth.account.sign_transaction(tx, config.PRIVATE_KEY)
        tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
        log.info(f"Rebalance tx submitted: {tx_hash.hex()}")

        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        if receipt["status"] == 1:
            log.info(f"Rebalance confirmed in block {receipt['blockNumber']}")
        else:
            log.error(f"Rebalance tx REVERTED in block {receipt['blockNumber']}")

        return receipt["status"] == 1

    except Exception as e:
        log.error(f"Failed to submit rebalance tx: {e}")
        return False


# Entry Point


def main():
    parser = argparse.ArgumentParser(description="AI Vault Agent")
    parser.add_argument("--once", action="store_true", help="Run a single check and exit")
    parser.add_argument("--dry-run", action="store_true", help="Score without submitting tx")
    args = parser.parse_args()

    # Validate config
    if not config.RPC_URL:
        log.error("SEPOLIA_RPC_URL not set. Create a .env file with your RPC URL.")
        sys.exit(1)
    if not config.PRIVATE_KEY:
        log.error("KEEPER_PRIVATE_KEY not set. Create a .env file with the keeper key.")
        sys.exit(1)
    if not config.VAULT_ADDRESS:
        log.error("VAULT_ADDRESS not set. Deploy the vault first and set the address.")
        sys.exit(1)

    w3 = Web3(Web3.HTTPProvider(config.RPC_URL))
    if not w3.is_connected():
        log.error(f"Cannot connect to RPC: {config.RPC_URL}")
        sys.exit(1)
    log.info(f"Connected to chain {w3.eth.chain_id} | Block: {w3.eth.block_number}")

    reader = DataReader(w3)

    if args.once:
        run_check(w3, reader, dry_run=args.dry_run)
        return

    log.info(f"Agent loop started (interval: {config.CHECK_INTERVAL_SECONDS}s)")
    while True:
        try:
            run_check(w3, reader, dry_run=args.dry_run)
        except Exception as e:
            log.error(f"Unhandled error in agent loop: {e}", exc_info=True)

        log.info(f"Sleeping {config.CHECK_INTERVAL_SECONDS}s until next check...")
        time.sleep(config.CHECK_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
