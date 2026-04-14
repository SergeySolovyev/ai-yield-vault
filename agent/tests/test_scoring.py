"""
Unit tests for the scoring engine.

Tests the MCDM scoring model in isolation — no web3 or on-chain calls.
Verifies normalization, individual factor scoring, weight application,
and decision logic.
"""

import sys
from pathlib import Path

import pytest

# Add agent/ to path so imports work
sys.path.insert(0, str(Path(__file__).parent.parent))

from scoring import normalize, score_protocol, evaluate


class TestNormalize:
    def test_min_value(self):
        assert normalize(0.0, 0.0, 1.0) == 0.0

    def test_max_value(self):
        assert normalize(1.0, 0.0, 1.0) == 1.0

    def test_mid_value(self):
        assert normalize(0.5, 0.0, 1.0) == 0.5

    def test_below_min_clamps(self):
        assert normalize(-1.0, 0.0, 1.0) == 0.0

    def test_above_max_clamps(self):
        assert normalize(2.0, 0.0, 1.0) == 1.0

    def test_custom_range(self):
        assert normalize(10, 0, 20) == 0.5

    def test_equal_min_max(self):
        assert normalize(5.0, 5.0, 5.0) == 0.0


class TestScoreProtocol:
    def test_high_apy_scores_well(self):
        """A protocol with high APY should score higher on the APY factor."""
        high = score_protocol(apy=0.10, utilization=0.5, gas_cost_eth=0.005, tvl_delta_pct=0.0)
        low = score_protocol(apy=0.02, utilization=0.5, gas_cost_eth=0.005, tvl_delta_pct=0.0)
        assert high.apy_score > low.apy_score
        assert high.total_score > low.total_score

    def test_low_utilization_scores_safer(self):
        """Lower utilization means lower risk, higher risk_score."""
        safe = score_protocol(apy=0.05, utilization=0.3, gas_cost_eth=0.005, tvl_delta_pct=0.0)
        risky = score_protocol(apy=0.05, utilization=0.9, gas_cost_eth=0.005, tvl_delta_pct=0.0)
        assert safe.risk_score > risky.risk_score

    def test_low_gas_scores_better(self):
        """Lower gas cost = higher cost_score."""
        cheap = score_protocol(apy=0.05, utilization=0.5, gas_cost_eth=0.001, tvl_delta_pct=0.0)
        expensive = score_protocol(apy=0.05, utilization=0.5, gas_cost_eth=0.009, tvl_delta_pct=0.0)
        assert cheap.cost_score > expensive.cost_score

    def test_stable_tvl_scores_better(self):
        """Stable TVL (no change) should score higher than volatile."""
        stable = score_protocol(apy=0.05, utilization=0.5, gas_cost_eth=0.005, tvl_delta_pct=0.0)
        volatile = score_protocol(apy=0.05, utilization=0.5, gas_cost_eth=0.005, tvl_delta_pct=-0.20)
        assert stable.stability_score > volatile.stability_score

    def test_perfect_protocol_scores_near_one(self):
        """Max APY, no util, no gas, stable TVL should score ~1.0."""
        ps = score_protocol(apy=0.20, utilization=0.0, gas_cost_eth=0.0, tvl_delta_pct=0.0)
        assert ps.total_score >= 0.95

    def test_worst_protocol_scores_near_zero(self):
        """Zero APY, max util, max gas, volatile TVL should score ~0.0."""
        ps = score_protocol(apy=0.0, utilization=1.0, gas_cost_eth=0.01, tvl_delta_pct=0.30)
        assert ps.total_score <= 0.05

    def test_scores_bounded(self):
        """Total score should always be in [0, 1]."""
        for apy in [0.0, 0.05, 0.10, 0.20]:
            for util in [0.0, 0.5, 1.0]:
                ps = score_protocol(apy=apy, utilization=util, gas_cost_eth=0.005, tvl_delta_pct=0.0)
                assert 0.0 <= ps.total_score <= 1.0


class TestEvaluate:
    def _make_protocols(self, apy_a=0.05, apy_b=0.03, util_a=0.5, util_b=0.5):
        return [
            {"adapter_index": 0, "name": "Aave V3", "apy": apy_a, "utilization": util_a, "tvl_delta": 0.0},
            {"adapter_index": 1, "name": "Compound V3", "apy": apy_b, "utilization": util_b, "tvl_delta": 0.0},
        ]

    def test_hold_when_already_best(self):
        """Should hold if current adapter already has the best score."""
        protocols = self._make_protocols(apy_a=0.08, apy_b=0.03)
        decision = evaluate(protocols, current_adapter_index=0, gas_cost_eth=0.005)
        assert not decision.should_rebalance

    def test_rebalance_to_better(self):
        """Should rebalance when another protocol is significantly better."""
        protocols = self._make_protocols(apy_a=0.02, apy_b=0.10)
        decision = evaluate(protocols, current_adapter_index=0, gas_cost_eth=0.005)
        assert decision.should_rebalance
        assert decision.target_index == 1

    def test_hold_when_delta_below_threshold(self):
        """Should hold when score delta is below threshold, even if different protocol is better."""
        # Very similar APYs — delta should be small
        protocols = self._make_protocols(apy_a=0.050, apy_b=0.052)
        decision = evaluate(protocols, current_adapter_index=0, gas_cost_eth=0.005)
        assert not decision.should_rebalance

    def test_risk_can_override_apy(self):
        """
        A protocol with slightly lower APY but much lower utilization
        might still be preferred due to risk weighting.
        """
        protocols = [
            {"adapter_index": 0, "name": "Aave V3", "apy": 0.06, "utilization": 0.95, "tvl_delta": 0.0},
            {"adapter_index": 1, "name": "Compound V3", "apy": 0.05, "utilization": 0.30, "tvl_delta": 0.0},
        ]
        decision = evaluate(protocols, current_adapter_index=0, gas_cost_eth=0.005)
        # Compound has lower APY but much safer utilization
        # Whether it triggers rebalance depends on exact weights, but Compound should score higher
        compound_score = next(s for s in decision.scores if s.adapter_index == 1)
        aave_score = next(s for s in decision.scores if s.adapter_index == 0)
        assert compound_score.total_score > aave_score.total_score

    def test_scores_returned_for_all_protocols(self):
        """Decision should include scores for every protocol."""
        protocols = self._make_protocols()
        decision = evaluate(protocols, current_adapter_index=0, gas_cost_eth=0.005)
        assert len(decision.scores) == 2

    def test_score_delta_calculated(self):
        """Score delta should be best_score - current_score."""
        protocols = self._make_protocols(apy_a=0.02, apy_b=0.10)
        decision = evaluate(protocols, current_adapter_index=0, gas_cost_eth=0.005)
        expected_delta = decision.target_score - decision.current_score
        assert abs(decision.score_delta - expected_delta) < 0.001


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
