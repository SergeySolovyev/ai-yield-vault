"""
Multi-Criteria Decision Making (MCDM) scoring engine.

Evaluates each protocol across four weighted factors:
  - APY (40%):       Raw yield — higher is better
  - Risk (25%):      Utilization-based — lower utilization = safer
  - Cost (20%):      Gas efficiency of switching — amortized over cooldown
  - Stability (15%): TVL change — stable TVL signals healthy protocol

Each factor is normalized to [0, 1], then combined into a weighted score.
The agent rebalances when the best protocol's score exceeds the current
protocol's score by more than SCORE_THRESHOLD.
"""

from dataclasses import dataclass

import config


@dataclass
class ProtocolScore:
    """Detailed scoring breakdown for a single protocol."""

    adapter_index: int
    name: str
    apy_score: float
    risk_score: float
    cost_score: float
    stability_score: float
    total_score: float


@dataclass
class ScoringDecision:
    """The agent's decision after scoring all protocols."""

    should_rebalance: bool
    current_index: int
    target_index: int
    current_score: float
    target_score: float
    score_delta: float
    scores: list[ProtocolScore]


def normalize(value: float, min_val: float, max_val: float) -> float:
    """Normalize a value to [0, 1] within the given range."""
    if max_val <= min_val:
        return 0.0
    clamped = max(min_val, min(value, max_val))
    return (clamped - min_val) / (max_val - min_val)


def score_protocol(
    apy: float,
    utilization: float,
    gas_cost_eth: float,
    tvl_delta_pct: float,
    max_apy: float = 0.20,
    max_gas_eth: float = 0.01,
) -> ProtocolScore:
    """
    Score a protocol using Multi-Criteria Decision Making (MCDM).

    Args:
        apy:            Annual yield as decimal (e.g., 0.05 for 5%)
        utilization:    Protocol utilization ratio [0, 1]
        gas_cost_eth:   Estimated gas cost to switch (in ETH)
        tvl_delta_pct:  TVL change since last observation (e.g., -0.05 for 5% drop)
        max_apy:        Upper bound for APY normalization (20%)
        max_gas_eth:    Upper bound for gas cost normalization

    Returns:
        ProtocolScore with individual and total scores
    """
    # APY: higher = better
    apy_score = normalize(apy, 0.0, max_apy)

    # Risk: lower utilization = safer (less chance of rate drop / liquidity issues)
    risk_score = 1.0 - normalize(utilization, 0.0, 1.0)

    # Cost: lower gas = better (inverted)
    cost_score = 1.0 - normalize(gas_cost_eth, 0.0, max_gas_eth)

    # Stability: small TVL changes = better (penalize large swings in either direction)
    stability_score = 1.0 - normalize(abs(tvl_delta_pct), 0.0, 0.30)

    total = (
        config.WEIGHT_APY * apy_score
        + config.WEIGHT_RISK * risk_score
        + config.WEIGHT_COST * cost_score
        + config.WEIGHT_STABILITY * stability_score
    )

    return ProtocolScore(
        adapter_index=-1,  # set by caller
        name="",
        apy_score=round(apy_score, 4),
        risk_score=round(risk_score, 4),
        cost_score=round(cost_score, 4),
        stability_score=round(stability_score, 4),
        total_score=round(total, 4),
    )


def evaluate(
    protocols: list[dict],
    current_adapter_index: int,
    gas_cost_eth: float,
) -> ScoringDecision:
    """
    Evaluate all protocols and decide whether to rebalance.

    Args:
        protocols: List of dicts with keys: adapter_index, name, apy, utilization, tvl_delta
        current_adapter_index: Index of the currently active adapter
        gas_cost_eth: Estimated gas cost for a rebalance (in ETH)

    Returns:
        ScoringDecision with the recommended action
    """
    scores: list[ProtocolScore] = []

    for p in protocols:
        ps = score_protocol(
            apy=p["apy"],
            utilization=p["utilization"],
            gas_cost_eth=gas_cost_eth,
            tvl_delta_pct=p.get("tvl_delta", 0.0),
        )
        ps.adapter_index = p["adapter_index"]
        ps.name = p["name"]
        scores.append(ps)

    # Find best and current
    best = max(scores, key=lambda s: s.total_score)
    current = next((s for s in scores if s.adapter_index == current_adapter_index), scores[0])

    delta = best.total_score - current.total_score
    should_rebalance = (
        delta >= config.SCORE_THRESHOLD
        and best.adapter_index != current_adapter_index
    )

    return ScoringDecision(
        should_rebalance=should_rebalance,
        current_index=current_adapter_index,
        target_index=best.adapter_index,
        current_score=current.total_score,
        target_score=best.total_score,
        score_delta=round(delta, 4),
        scores=scores,
    )
