"""
AI Vault Agent — REST API

Exposes vault status, protocol scoring, and agent actions via HTTP.
OpenClaw (or any chat framework) calls these endpoints to provide
a natural-language interface to the vault.

Endpoints:
    GET  /status       — Vault TVL, share price, active adapter, agent state
    GET  /rates        — Current protocol APYs and utilization
    GET  /score        — Run the MCDM scoring engine, return decision
    POST /rebalance    — Trigger a rebalance (dry-run by default)
    GET  /health       — Agent liveness check

Usage:
    python api.py                    # Start on port 8042
    uvicorn api:app --host 0.0.0.0   # Production
"""

import time
import logging

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from web3 import Web3

import config
from data_reader import DataReader
from scoring import evaluate
from signer import sign_rebalance_params
from main import ema_smooth, _smoothed_rates

log = logging.getLogger("ai-vault-api")

app = FastAPI(
    title="AI Yield Vault API",
    description="REST API for the AI-managed ERC-4626 yield vault",
    version="1.0.0",
)

# ── Lazy web3 initialization ─────────────────────────────────────────

_w3: Web3 | None = None
_reader: DataReader | None = None


def _get_w3() -> Web3:
    global _w3
    if _w3 is None:
        if not config.RPC_URL:
            raise HTTPException(503, "SEPOLIA_RPC_URL not configured")
        _w3 = Web3(Web3.HTTPProvider(config.RPC_URL))
    return _w3


def _get_reader() -> DataReader:
    global _reader
    if _reader is None:
        _reader = DataReader(_get_w3())
    return _reader


def _get_vault():
    w3 = _get_w3()
    return w3.eth.contract(
        address=Web3.to_checksum_address(config.VAULT_ADDRESS),
        abi=config.get_vault_abi(),
    )


def _get_strategy_manager():
    w3 = _get_w3()
    return w3.eth.contract(
        address=Web3.to_checksum_address(config.STRATEGY_MANAGER_ADDRESS),
        abi=config.get_strategy_manager_abi(),
    )


# ── Response Models ──────────────────────────────────────────────────


class VaultStatus(BaseModel):
    total_assets_usdc: float
    share_price: float
    total_shares: float
    active_adapter_index: int
    active_adapter_name: str
    has_active_strategy: bool
    is_paused: bool
    last_rebalance_timestamp: int
    seconds_since_rebalance: int
    keeper: str


class ProtocolRate(BaseModel):
    name: str
    adapter_index: int
    apy_percent: float
    utilization_percent: float
    smoothed_apy_percent: float


class ScoreResult(BaseModel):
    should_rebalance: bool
    current_adapter: str
    best_adapter: str
    current_score: float
    best_score: float
    score_delta: float
    threshold: float
    details: list[dict]


class RebalanceResult(BaseModel):
    executed: bool
    dry_run: bool
    target_adapter_index: int
    message: str
    tx_hash: str | None = None


# ── Endpoints ────────────────────────────────────────────────────────


@app.get("/health")
def health():
    """Agent liveness check."""
    connected = False
    try:
        w3 = _get_w3()
        connected = w3.is_connected()
    except Exception:
        pass
    return {
        "status": "ok" if connected else "degraded",
        "rpc_connected": connected,
        "vault_configured": bool(config.VAULT_ADDRESS),
        "timestamp": int(time.time()),
    }


@app.get("/status", response_model=VaultStatus)
def vault_status():
    """Get vault status: TVL, share price, active strategy, etc."""
    vault = _get_vault()

    total_assets = vault.functions.totalAssets().call()
    total_supply = vault.functions.totalSupply().call()
    active_idx = vault.functions.activeAdapterIndex().call()
    has_active = vault.functions.hasActiveStrategy().call()
    paused = vault.functions.paused().call()
    last_rebalance = vault.functions.lastRebalanceTimestamp().call()
    keeper = vault.functions.keeper().call()

    # Share price: how many assets per 1e12 shares (accounting for decimalsOffset=6)
    share_price = vault.functions.convertToAssets(10**12).call() / 1e6 if total_supply > 0 else 1.0

    # Get adapter name
    adapter_names = {0: "Aave V3", 1: "Compound V3"}
    adapter_name = adapter_names.get(active_idx, f"Adapter {active_idx}")

    return VaultStatus(
        total_assets_usdc=total_assets / 1e6,
        share_price=round(share_price, 6),
        total_shares=total_supply / 1e12,
        active_adapter_index=active_idx,
        active_adapter_name=adapter_name,
        has_active_strategy=has_active,
        is_paused=paused,
        last_rebalance_timestamp=last_rebalance,
        seconds_since_rebalance=int(time.time()) - last_rebalance,
        keeper=keeper,
    )


@app.get("/rates", response_model=list[ProtocolRate])
def protocol_rates():
    """Get current APY and utilization for all protocols."""
    reader = _get_reader()
    protocols = reader.read_all()

    results = []
    for p in protocols:
        smoothed = ema_smooth(p.apy, _smoothed_rates.get(p.adapter_index), config.EMA_ALPHA)
        _smoothed_rates[p.adapter_index] = smoothed

        results.append(ProtocolRate(
            name=p.name,
            adapter_index=p.adapter_index,
            apy_percent=round(p.apy * 100, 4),
            utilization_percent=round(p.utilization * 100, 2),
            smoothed_apy_percent=round(smoothed * 100, 4),
        ))

    return results


@app.get("/score", response_model=ScoreResult)
def run_scoring():
    """Run the MCDM scoring engine and return the decision."""
    reader = _get_reader()
    protocols = reader.read_all()
    gas_price = reader.get_gas_price()
    gas_cost_eth = (gas_price * 200_000) / 1e18

    vault = _get_vault()
    current_idx = vault.functions.activeAdapterIndex().call()

    protocol_data = []
    for p in protocols:
        smoothed = ema_smooth(p.apy, _smoothed_rates.get(p.adapter_index), config.EMA_ALPHA)
        _smoothed_rates[p.adapter_index] = smoothed
        tvl_delta = reader.get_tvl_delta(p)

        protocol_data.append({
            "adapter_index": p.adapter_index,
            "name": p.name,
            "apy": smoothed,
            "utilization": p.utilization,
            "tvl_delta": tvl_delta,
        })

    decision = evaluate(protocol_data, current_idx, gas_cost_eth)

    adapter_names = {0: "Aave V3", 1: "Compound V3"}
    details = []
    for s in decision.scores:
        details.append({
            "name": s.name,
            "total_score": s.total_score,
            "apy_score": s.apy_score,
            "risk_score": s.risk_score,
            "cost_score": s.cost_score,
            "stability_score": s.stability_score,
        })

    return ScoreResult(
        should_rebalance=decision.should_rebalance,
        current_adapter=adapter_names.get(decision.current_index, str(decision.current_index)),
        best_adapter=adapter_names.get(decision.target_index, str(decision.target_index)),
        current_score=decision.current_score,
        best_score=decision.target_score,
        score_delta=decision.score_delta,
        threshold=config.SCORE_THRESHOLD,
        details=details,
    )


@app.post("/rebalance", response_model=RebalanceResult)
def trigger_rebalance(dry_run: bool = True):
    """
    Trigger a rebalance. Dry-run by default (scores without submitting tx).
    Pass ?dry_run=false to actually submit.
    """
    # Run scoring first
    score = run_scoring()

    if not score.should_rebalance:
        return RebalanceResult(
            executed=False,
            dry_run=dry_run,
            target_adapter_index=score.details[0]["name"] if score.details else -1,
            message=f"No rebalance needed. Delta {score.score_delta} < threshold {score.threshold}",
        )

    if dry_run:
        return RebalanceResult(
            executed=False,
            dry_run=True,
            target_adapter_index=next(
                (d for d in [0, 1] if d != _get_vault().functions.activeAdapterIndex().call()), 0
            ),
            message=f"DRY RUN: Would rebalance to {score.best_adapter} (delta: {score.score_delta})",
        )

    # Actually execute
    try:
        sm = _get_strategy_manager()
        nonce = sm.functions.rebalanceNonce().call()
        vault = _get_vault()
        current_idx = vault.functions.activeAdapterIndex().call()
        target_idx = next(d["name"] for d in score.details if d["total_score"] == score.best_score)

        # Map name back to index
        name_to_idx = {"Aave V3": 0, "Compound V3": 1}
        target = name_to_idx.get(score.best_adapter, 0)

        signed = sign_rebalance_params(
            target_adapter_index=target,
            max_loss_bps=config.MAX_LOSS_BPS,
            nonce=nonce,
        )

        w3 = _get_w3()
        tx = vault.functions.rebalance(
            (signed["params"]["targetAdapterIndex"], signed["params"]["maxLossBps"],
             signed["params"]["timestamp"], signed["params"]["nonce"]),
            bytes.fromhex(signed["signature"]),
        ).build_transaction({
            "from": signed["signer"],
            "nonce": w3.eth.get_transaction_count(signed["signer"]),
            "gas": 500_000,
            "maxFeePerGas": w3.eth.gas_price * 2,
            "maxPriorityFeePerGas": w3.to_wei(1, "gwei"),
        })

        signed_tx = w3.eth.account.sign_transaction(tx, config.PRIVATE_KEY)
        tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

        return RebalanceResult(
            executed=receipt["status"] == 1,
            dry_run=False,
            target_adapter_index=target,
            message=f"Rebalanced to {score.best_adapter} in block {receipt['blockNumber']}",
            tx_hash=tx_hash.hex(),
        )

    except Exception as e:
        raise HTTPException(500, f"Rebalance failed: {e}")


# ── Entry point ──────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8042)
