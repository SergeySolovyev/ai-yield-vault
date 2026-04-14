"""
On-chain data reader.

Fetches real-time protocol metrics from Aave V3 and Compound V3
via web3.py. All rates are normalized to annual 1e18 scale before
being returned to the scoring engine.
"""

from dataclasses import dataclass
from web3 import Web3

import config

# ── Minimal ABIs (only the functions we need) ────────────────────────

AAVE_POOL_ABI = [
    {
        "inputs": [{"name": "asset", "type": "address"}],
        "name": "getReserveData",
        "outputs": [
            {
                "components": [
                    {"name": "configuration", "type": "uint256"},
                    {"name": "liquidityIndex", "type": "uint128"},
                    {"name": "currentLiquidityRate", "type": "uint128"},
                    {"name": "variableBorrowIndex", "type": "uint128"},
                    {"name": "currentVariableBorrowRate", "type": "uint128"},
                    {"name": "currentStableBorrowRate", "type": "uint128"},
                    {"name": "lastUpdateTimestamp", "type": "uint40"},
                    {"name": "id", "type": "uint16"},
                    {"name": "aTokenAddress", "type": "address"},
                    {"name": "stableDebtTokenAddress", "type": "address"},
                    {"name": "variableDebtTokenAddress", "type": "address"},
                    {"name": "interestRateStrategyAddress", "type": "address"},
                    {"name": "accruedToTreasury", "type": "uint128"},
                    {"name": "unbacked", "type": "uint128"},
                    {"name": "isolationModeTotalDebt", "type": "uint128"},
                ],
                "name": "",
                "type": "tuple",
            }
        ],
        "stateMutability": "view",
        "type": "function",
    }
]

COMET_ABI = [
    {
        "inputs": [],
        "name": "getUtilization",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [{"name": "utilization", "type": "uint256"}],
        "name": "getSupplyRate",
        "outputs": [{"name": "", "type": "uint64"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "totalSupply",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [{"name": "account", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
]

# ── Constants ────────────────────────────────────────────────────────

RAY = 10**27
SECONDS_PER_YEAR = 365.25 * 24 * 3600
SCALE_18 = 10**18


@dataclass
class ProtocolData:
    """Snapshot of a protocol's current state."""

    name: str
    adapter_index: int
    apy: float                # Annual rate as a decimal (e.g., 0.05 = 5%)
    utilization: float        # 0.0 to 1.0
    tvl: float                # Total value locked in the protocol's market (USD or token units)
    raw_rate_1e18: int        # Raw rate in 1e18 scale (for EMA smoothing)


class DataReader:
    """Reads on-chain data from Aave V3 and Compound V3."""

    def __init__(self, w3: Web3):
        self.w3 = w3
        self.aave_pool = w3.eth.contract(
            address=Web3.to_checksum_address(config.AAVE_POOL_ADDRESS),
            abi=AAVE_POOL_ABI,
        )
        self.comet = w3.eth.contract(
            address=Web3.to_checksum_address(config.COMPOUND_COMET_ADDRESS),
            abi=COMET_ABI,
        )
        self._prev_tvl: dict[int, float] = {}

    def read_all(self) -> list[ProtocolData]:
        """Read current data from all supported protocols."""
        aave = self._read_aave()
        compound = self._read_compound()
        return [aave, compound]

    def _read_aave(self) -> ProtocolData:
        """Read Aave V3 supply rate and metrics."""
        usdc = Web3.to_checksum_address(config.USDC_ADDRESS)
        reserve_data = self.aave_pool.functions.getReserveData(usdc).call()

        # currentLiquidityRate is in RAY (1e27)
        liquidity_rate_ray = reserve_data[2]  # currentLiquidityRate

        # Normalize: RAY → 1e18 annual (Aave rates are already annual)
        rate_1e18 = liquidity_rate_ray * SCALE_18 // RAY
        apy = rate_1e18 / SCALE_18

        # Estimate utilization from rate ratio
        borrow_rate_ray = reserve_data[4]  # currentVariableBorrowRate
        if borrow_rate_ray > 0:
            utilization = liquidity_rate_ray / borrow_rate_ray
        else:
            utilization = 0.0

        # For TVL, we'd need the aToken total supply; approximate with 0 for now
        # In production, query IPoolDataProvider for more accurate data
        tvl = 0.0

        return ProtocolData(
            name="Aave V3",
            adapter_index=0,
            apy=apy,
            utilization=min(utilization, 1.0),
            tvl=tvl,
            raw_rate_1e18=rate_1e18,
        )

    def _read_compound(self) -> ProtocolData:
        """Read Compound V3 supply rate and metrics."""
        # Utilization (1e18 scale)
        utilization_raw = self.comet.functions.getUtilization().call()
        utilization = utilization_raw / SCALE_18

        # Supply rate (per-second, needs annualization)
        per_second_rate = self.comet.functions.getSupplyRate(utilization_raw).call()
        rate_1e18 = int(per_second_rate * SECONDS_PER_YEAR)
        apy = rate_1e18 / SCALE_18

        # TVL = totalSupply of the Comet market
        total_supply = self.comet.functions.totalSupply().call()
        tvl = total_supply / 1e6  # USDC has 6 decimals

        return ProtocolData(
            name="Compound V3",
            adapter_index=1,
            apy=apy,
            utilization=min(utilization, 1.0),
            tvl=tvl,
            raw_rate_1e18=rate_1e18,
        )

    def get_tvl_delta(self, protocol: ProtocolData) -> float:
        """
        Compute TVL change since last observation.
        Returns fractional change (e.g., -0.05 means 5% drop).
        """
        idx = protocol.adapter_index
        prev = self._prev_tvl.get(idx)
        self._prev_tvl[idx] = protocol.tvl

        if prev is None or prev == 0:
            return 0.0
        return (protocol.tvl - prev) / prev

    def get_gas_price(self) -> int:
        """Get current gas price in wei."""
        return self.w3.eth.gas_price
