# AI Yield Vault: An Agent-Managed ERC-4626 Yield Optimization Protocol

**Version 1.0 — April 2026**

---

## Abstract

We present AI Yield Vault, an ERC-4626-compliant tokenized vault that autonomously rebalances user deposits between DeFi lending protocols (Aave V3 and Compound V3) using an off-chain AI agent. Unlike existing yield optimizers that rely on simple APY comparison, our system employs Multi-Criteria Decision Making (MCDM) with four weighted factors: yield, risk, cost, and stability. The agent signs its decisions cryptographically using EIP-712 typed data, creating a verifiable on-chain audit trail. A Chainlink Automation fallback ensures protocol safety if the agent goes offline. The system is deployed on Ethereum Sepolia with UUPS upgradeability.

---

## 1. Introduction

### 1.1 Problem Statement

DeFi lending markets exhibit significant APY volatility. Aave V3 and Compound V3 supply rates fluctuate based on utilization, governance parameters, and market conditions. Manual yield optimization is impractical: users must monitor rates continuously, pay gas to rebalance, and assess protocol risk — all while avoiding the pitfalls of chasing momentarily high rates.

### 1.2 Limitations of Existing Solutions

| Protocol | Architecture | Decision Logic | Verifiability |
|----------|-------------|----------------|---------------|
| Yearn V3 | On-chain strategies | Strategist-coded allocation | On-chain (rigid) |
| Beefy Finance | On-chain auto-compound | Harvest → compound loop | On-chain (simple) |
| Idle Finance | On-chain | Best-rate-wins threshold | On-chain (APY only) |
| Almanak | Off-chain agent | ML-based (closed source) | Opaque |
| **AI Yield Vault** | **Hybrid (agent + on-chain)** | **Multi-factor MCDM scoring** | **EIP-712 signed, on-chain verifiable** |

Existing yield optimizers fall into two categories:
1. **On-chain only** (Yearn, Beefy, Idle): Limited to simple heuristics due to gas costs. Cannot perform complex multi-factor analysis on-chain efficiently.
2. **Off-chain opaque** (Almanak): Powerful but unverifiable — users trust a black box.

### 1.3 Our Contribution

AI Yield Vault bridges this gap with a **hybrid architecture**:
- An **off-chain Python agent** performs rich multi-factor analysis (APY, utilization risk, gas cost-efficiency, rate stability)
- Decisions are **signed with EIP-712 typed data** and verified on-chain
- Every rebalance emits an event with the agent's decision, creating a **verifiable audit trail**
- A **Chainlink Automation fallback** activates if the agent goes offline, ensuring the vault is never unmanaged

---

## 2. Architecture

### 2.1 System Overview

```
┌────────────────────────────┐
│    AI Agent (Python)       │  Off-chain
│                            │
│  1. Read on-chain data     │
│     - APY, utilization     │
│     - TVL, gas price       │
│  2. EMA rate smoothing     │
│  3. MCDM scoring           │
│  4. Decision: rebalance    │
│     or hold                │
│  5. EIP-712 sign           │
│  6. Submit rebalance tx    │
└───────────┬────────────────┘
            │ signed RebalanceParams
            ▼
┌────────────────────────────┐
│   AIVault.sol              │  On-chain
│   (ERC-4626 + UUPS)       │
│                            │
│  - Verify ECDSA signature  │
│  - Check cooldown/nonce    │
│  - Execute rebalance       │
│  - Post-check slippage     │
│  - Emit Rebalanced event   │
└───────────┬────────────────┘
            │
    ┌───────┴───────┐
    ▼               ▼
┌──────────┐  ┌──────────────┐
│ Aave V3  │  │ Compound V3  │
│ Adapter  │  │ Adapter      │
└──────────┘  └──────────────┘

Fallback path:
  Chainlink Automation → checkUpkeep → performUpkeep
  (activates only after agentTimeout = 6 hours)
```

### 2.2 Contract Architecture

| Contract | Role | Inherits |
|----------|------|----------|
| `AIVault.sol` | Core vault, ERC-4626 token, rebalance executor | ERC4626Upgradeable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard |
| `StrategyManager.sol` | Decision validation, adapter registry, rate smoothing | Ownable |
| `AaveV3Adapter.sol` | Aave V3 supply/withdraw/balance/rate | IProtocolAdapter, Ownable |
| `CompoundV3Adapter.sol` | Compound V3 supply/withdraw/balance/rate | IProtocolAdapter, Ownable |
| `RateMath.sol` | APY normalization and EMA library | (library) |
| `Constants.sol` | Network addresses and defaults | (library) |

### 2.3 Adapter Pattern (Strategy Design Pattern)

All protocol-specific logic is abstracted behind `IProtocolAdapter`:

```solidity
interface IProtocolAdapter {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external returns (uint256);
    function balance(address asset) external view returns (uint256);
    function getSupplyRate(address asset) external view returns (uint256);
    function getUtilization(address asset) external view returns (uint256);
    function protocolName() external pure returns (string memory);
}
```

This enables adding new protocols (Morpho, Spark, Euler) without modifying the vault or strategy manager — only a new adapter implementation is needed.

---

## 3. Mathematical Foundations

### 3.1 APY Normalization

Different protocols represent rates in different formats. We normalize all rates to a common annual 1e18 scale:

**Aave V3** — rates are stored in RAY (1e27) and are already annualized:

$$\text{APY}_{1e18} = \frac{\text{currentLiquidityRate}_{RAY}}{10^9}$$

**Compound V3** — rates are per-second and must be annualized:

$$\text{APY}_{1e18} = \text{perSecondRate} \times \text{SECONDS\_PER\_YEAR}$$

where $\text{SECONDS\_PER\_YEAR} = 365.25 \times 24 \times 3600 = 31{,}557{,}600$

### 3.2 Exponential Moving Average (EMA) Smoothing

Raw APY readings are noisy and susceptible to flash manipulation. We apply EMA smoothing:

$$S_t = \alpha \cdot R_t + (1 - \alpha) \cdot S_{t-1}$$

where:
- $S_t$ = smoothed rate at time $t$
- $R_t$ = raw observed rate
- $\alpha$ = smoothing factor (0.3 = 30% weight on new data)
- $S_0 = R_0$ (first observation)

**Rate manipulation guard**: If the raw rate jumps more than `maxRateJumpBps` (5%) from the previous smoothed value, the update is skipped. This prevents flash loan attacks from manipulating the agent's scoring.

### 3.3 Multi-Criteria Decision Making (MCDM) Scoring

Each protocol is scored across four factors, each normalized to [0, 1]:

$$\text{Score}_i = w_1 \cdot f_{\text{APY}}(i) + w_2 \cdot f_{\text{Risk}}(i) + w_3 \cdot f_{\text{Cost}}(i) + w_4 \cdot f_{\text{Stability}}(i)$$

| Factor | Weight | Formula | Rationale |
|--------|--------|---------|-----------|
| APY | $w_1 = 0.40$ | $\text{normalize}(\text{smoothedAPY}, 0, 0.20)$ | Primary yield signal |
| Risk | $w_2 = 0.25$ | $1 - \text{normalize}(\text{utilization}, 0, 1)$ | High utilization → rate drop risk |
| Cost | $w_3 = 0.20$ | $1 - \text{normalize}(\text{gasCost}_{ETH}, 0, 0.01)$ | Gas efficiency of switching |
| Stability | $w_4 = 0.15$ | $1 - \text{normalize}(|\Delta\text{TVL}|, 0, 0.30)$ | Large TVL swings → instability |

The agent rebalances when:

$$\text{Score}_{\text{best}} - \text{Score}_{\text{current}} \geq \theta$$

where $\theta = 0.05$ (configurable threshold).

### 3.4 ERC-4626 Share Price

The vault follows the ERC-4626 standard for share pricing:

$$\text{shares} = \frac{\text{assets} \times (\text{totalSupply} + 10^{\text{offset}})}{\text{totalAssets} + 1}$$

$$\text{assets} = \frac{\text{shares} \times (\text{totalAssets} + 1)}{\text{totalSupply} + 10^{\text{offset}}}$$

where $\text{offset} = 6$ (virtual shares for inflation attack protection).

### 3.5 Cost-Aware Rebalance Threshold (Fallback Mode)

The on-chain fallback uses a cost-aware threshold:

$$\text{Rebalance if:} \quad \frac{\Delta\text{APY} \times \text{TVL} \times t_{\text{since}}}{365 \text{ days}} > \text{gasCost}$$

where $t_{\text{since}}$ is time since last rebalance. This ensures the expected yield improvement outweighs the gas cost.

### 3.6 Fee Mechanics

**Management fee** (annual, on TVL): Accrued via share dilution.

$$\text{feeShares} = \frac{\text{TVL} \times \text{mgmtFeeBps}}{10{,}000} \times \frac{\Delta t}{365 \text{ days}}$$

**Performance fee** (on profit above high-water mark):

$$\text{profit} = \max(0, \text{sharePrice}_t - \text{HWM})$$
$$\text{feeAssets} = \text{profit} \times \text{perfFeeBps} \times \text{totalSupply} / 10{,}000$$

---

## 4. Security Analysis

### 4.1 ERC-4626 Inflation Attack

**Threat**: An attacker deposits 1 wei, donates a large amount directly to the vault, then the next depositor receives 0 shares due to rounding.

**Mitigation**: `_decimalsOffset() = 6` creates $10^6$ virtual shares, making the attack economically infeasible. The attacker would need to donate $>10^6$ times the victim's deposit.

**Proof**: Our `test_inflationAttack_mitigated` test verifies that after a 10,000 USDC donation, a victim depositing 10,000 USDC still receives shares worth ~10,000 USDC.

### 4.2 Reentrancy

All state-mutating external functions use OpenZeppelin's `ReentrancyGuard` (ERC-7201 namespaced storage). The `deposit`, `mint`, `withdraw`, `redeem`, `rebalance`, and `performUpkeep` functions are all protected.

### 4.3 Signature Replay

**Protection layers**:
1. **Nonce**: Each rebalance consumes a sequential nonce. Replaying a used nonce reverts.
2. **Timestamp freshness**: Signatures older than 5 minutes are rejected (`SIGNATURE_MAX_AGE`).
3. **EIP-712 domain**: Includes `chainId` and `verifyingContract`, preventing cross-chain replay.

### 4.4 Rate Manipulation

**Threat**: Attacker flash-loans to spike a protocol's utilization, causing a false APY spike.

**Mitigation**:
1. **EMA smoothing** dampens sudden rate changes (only 30% weight on new data)
2. **maxRateJumpBps guard** rejects rate updates that exceed 5% change from the smoothed value
3. **Agent-side smoothing** provides a second layer of EMA in the Python agent

### 4.5 Cooldown Period

A 1-hour cooldown between rebalances prevents:
- Rapid rebalance exploitation (sandwich attacks between protocols)
- Excessive gas consumption from thrashing between similar rates

### 4.6 Access Control Matrix

| Function | Caller | Protection |
|----------|--------|------------|
| `deposit/withdraw` | Any user | whenNotPaused, nonReentrant |
| `rebalance` | Anyone (signature-verified) | Keeper signature, cooldown, nonce |
| `performUpkeep` | Chainlink Automation | agentTimeout, cooldown, on-chain validation |
| `emergencyWithdrawAll` | Owner only | onlyOwner |
| `pause/unpause` | Owner only | onlyOwner |
| `setKeeper` | Owner only | onlyOwner |
| `setFees` | Owner only | onlyOwner, fee caps (5% mgmt, 30% perf) |

---

## 5. Testing Methodology

### 5.1 Test Coverage Summary

| Category | Tests | Technique | Coverage |
|----------|-------|-----------|----------|
| Unit (RateMath) | 20 | Concrete + fuzz (1000 runs) | Normalization, EMA, utilities |
| Unit (AIVault) | 17 | Concrete + fuzz (1000 runs) | Deposit, withdraw, rebalance, admin, inflation |
| Integration | 4 | End-to-end lifecycle | Full agent flow, nonce replay, emergency |
| Invariant | 6 | Stateful fuzzing (256 runs × 50 depth) | Solvency, accounting, conversions |
| Python (Scoring) | 20 | Pytest unit tests | Normalization, scoring, decisions |
| **Total** | **67** | | |

### 5.2 Invariant Properties Verified

With 76,800+ random function calls and zero violations:

1. **Solvency**: `totalAssets >= sum(maxWithdraw(user))` for all users
2. **Accounting**: `deposits - withdrawals ≈ totalAssets` (within 1 wei/operation)
3. **Conversion consistency**: `convertToAssets(convertToShares(x)) ≈ x`
4. **Non-negative assets**: `totalAssets() >= 0` always
5. **Supply consistency**: Shares exist iff assets exist
6. **Share price stability**: Non-decreasing in absence of fees/slippage

---

## 6. Deployment

### 6.1 Network
- **Testnet**: Ethereum Sepolia (Chain ID: 11155111)
- **Underlying asset**: USDC (Aave faucet variant)

### 6.2 Deployment Order
1. AaveV3Adapter → CompoundV3Adapter
2. StrategyManager (registers adapters)
3. AIVault implementation → ERC1967Proxy (UUPS)
4. Transfer adapter ownership to vault
5. Register Chainlink Automation upkeep

### 6.3 Upgradeability
The vault uses the UUPS proxy pattern (ERC-1967). The implementation can be upgraded by the owner via `upgradeToAndCall()`, enabling:
- Adding new features (multi-asset support, governance)
- Fixing discovered vulnerabilities
- Upgrading to newer OpenZeppelin versions

---

## 7. Future Work

### 7.1 Short-term Enhancements
- **ML rate prediction**: Replace EMA with LSTM/XGBoost for APY forecasting
- **Multi-chain deployment**: Arbitrum, Base, Optimism
- **Additional adapters**: Morpho, Spark, Euler V2
- **Withdrawal queue**: For large positions exceeding protocol liquidity

### 7.2 Long-term Vision
- **DAO governance**: Transition from owner multisig to token-weighted governance
- **NLP interface**: Telegram/Discord bot for natural-language vault interaction
- **Formal verification**: Certora/Halmos for mathematical proof of invariants
- **Professional audit**: Trail of Bits, OpenZeppelin, or equivalent

---

## 8. Conclusion

AI Yield Vault demonstrates that the "agentic DeFi" paradigm — off-chain intelligence with on-chain verification — offers meaningful advantages over purely on-chain or purely off-chain approaches. The MCDM scoring model considers factors that on-chain logic cannot efficiently evaluate, while EIP-712 signatures maintain the trustless verification that DeFi users expect.

Our testing methodology (67 tests, 76,800+ invariant calls) provides strong confidence in the system's correctness. The modular adapter architecture and UUPS upgradeability create a foundation that can evolve from an academic prototype to a production-grade yield optimization protocol.

---

## References

1. ERC-4626: Tokenized Vaults — https://eips.ethereum.org/EIPS/eip-4626
2. ERC-1967: Proxy Storage Slots — https://eips.ethereum.org/EIPS/eip-1967
3. EIP-712: Typed Structured Data Hashing and Signing — https://eips.ethereum.org/EIPS/eip-712
4. OpenZeppelin Contracts v5 — https://docs.openzeppelin.com/contracts/5.x/
5. Aave V3 Technical Paper — https://github.com/aave/aave-v3-core/blob/master/techpaper/Aave_V3_Technical_Paper.pdf
6. Compound III (Comet) Documentation — https://docs.compound.finance/
7. Chainlink Automation — https://docs.chain.link/chainlink-automation
8. ERC-4626 Inflation Attack — https://blog.openzeppelin.com/a-]]novel-defense-against-erc4626-inflation-attacks
