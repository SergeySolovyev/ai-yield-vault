---
marp: true
theme: default
paginate: true
math: mathjax
style: |
  section {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    font-size: 22px;
  }
  h1 { font-size: 36px; color: #1a1a2e; }
  h2 { font-size: 28px; color: #16213e; }
  table { font-size: 18px; }
  code { font-size: 16px; }
  .columns { display: flex; gap: 40px; }
  .col { flex: 1; }
---

<!-- _class: lead -->

# AI-Managed ERC-4626 Yield Vault
## Multi-Criteria Decision Making for Automated DeFi Yield Optimization

**[Your Name]**
[University], Department of [CS / Finance]
April 2026

---

# Agenda

1. Problem: DeFi Yield Volatility
2. Existing Solutions & Their Limitations
3. Our Architecture: Hybrid Agent + On-Chain
4. Mathematical Foundations
5. Multi-Criteria Decision Making (MCDM)
6. Security Model
7. Testing & Formal Verification
8. Demo: OpenClaw Chat Interface
9. Results & Comparison
10. Future Work

---

# 1. The Problem

**DeFi lending rates are volatile and cross over frequently**

```
APY (%)
  8 │        ╱╲        Compound
    │       ╱  ╲      ╱
  6 │──────╱────╲────╱──── Optimal = follow the leader
    │     ╱      ╲  ╱
  4 │────╱────────╲╱─────  But: gas costs, timing, risk...
    │   ╱    Aave  ╲
  2 │──╱────────────╲────
    └──────────────────── Time
```

**Why manual optimization fails:**
- Rates change every ~12 seconds
- Each rebalance costs $2–50 in gas
- APY alone is not enough — utilization, stability, cost all matter
- Timing mistakes destroy value (temporary spikes)

---

# 2. Existing Solutions

| Protocol | Decision Logic | Verifiable? | Multi-Factor? |
|----------|---------------|-------------|---------------|
| **Yearn V3** | Strategist-coded, on-chain | Yes | No |
| **Beefy** | Harvest → compound loop | Yes | No |
| **Idle Finance** | Best-APY-wins threshold | Yes | No |
| **Almanak** | ML models (closed source) | **No** | Yes |

**The gap:** No system combines rich off-chain analysis with on-chain verifiability.

### Our position:
> **Off-chain intelligence + On-chain verification = Best of both worlds**

---

# 3. Architecture Overview

```
┌──────────────────────────┐
│   OpenClaw Chat Interface │  "What's the APY?"
└────────────┬─────────────┘
             │ REST API
┌────────────┴─────────────┐
│   Python AI Agent         │  Off-chain
│   • Read on-chain data    │
│   • EMA rate smoothing    │
│   • MCDM scoring (4 factors) │
│   • EIP-712 sign decision │
└────────────┬─────────────┘
             │ Signed tx
┌────────────┴─────────────┐
│   AIVault.sol (ERC-4626)  │  On-chain
│   • Verify ECDSA signature│
│   • Execute rebalance     │
│   • Post-check slippage   │
│   ├── AaveV3Adapter       │
│   └── CompoundV3Adapter   │
└──────────────────────────┘
  Fallback: Chainlink Automation (if agent offline >6h)
```

---

# 4. Smart Contract Design

**ERC-4626 Tokenized Vault** — users deposit USDC, receive `aiUSDC` shares

**Share pricing:**
$$s = \left\lfloor \frac{a \cdot (S + 10^6)}{A + 1} \right\rfloor$$

The $10^6$ offset creates **virtual shares** preventing the inflation attack.

**Key contracts:**

| Contract | Lines | Role |
|----------|-------|------|
| `AIVault.sol` | 571 | Core vault, ERC-4626, rebalance |
| `StrategyManager.sol` | 208 | Decision validation, EMA |
| `AaveV3Adapter.sol` | 102 | Aave V3 wrapper |
| `CompoundV3Adapter.sol` | 73 | Compound V3 wrapper |
| `RateMath.sol` | 60 | Rate normalization |

---

# 5. APY Normalization

Protocols use incompatible rate formats. We normalize to **annual 1e18**:

**Aave V3** (RAY = $10^{27}$, already annual):
$$\text{APY}_{1e18} = \frac{\text{liquidityRate}_{\text{RAY}}}{10^9}$$

**Compound V3** (per-second rate):
$$\text{APY}_{1e18} = r_{\text{sec}} \times 31{,}557{,}600$$

**EMA Smoothing** (dampens noise and manipulation):
$$S_t = 0.3 \cdot R_t + 0.7 \cdot S_{t-1}$$

Rate jump guard: skip update if $|R_t - S_{t-1}| > 5\%$

---

# 6. MCDM Scoring Model — The Core Innovation

$$\text{Score}_i = 0.40 \cdot f_{\text{APY}} + 0.25 \cdot f_{\text{Risk}} + 0.20 \cdot f_{\text{Cost}} + 0.15 \cdot f_{\text{Stability}}$$

| Factor | Formula | Why |
|--------|---------|-----|
| **APY** (40%) | $\text{APY} / 0.20$ | Primary yield signal |
| **Risk** (25%) | $1 - \text{utilization}$ | High util → rate drop risk |
| **Cost** (20%) | $1 - \text{gasCost} / 0.01$ | Gas efficiency |
| **Stability** (15%) | $1 - |\Delta\text{TVL}| / 0.30$ | TVL stability |

**Decision rule:** Rebalance if $\text{Score}_{\text{best}} - \text{Score}_{\text{current}} \geq 0.05$

---

# 7. Worked Example: Risk Beats APY

| | Aave V3 | Compound V3 |
|---|---------|-------------|
| APY | **6.0%** | 5.2% |
| Utilization | 85% (risky) | **45% (safe)** |
| Gas | 0.003 ETH | 0.003 ETH |
| TVL Δ | -2% | +1% |

**Scoring:**

| Factor | Aave | Compound |
|--------|------|----------|
| APY (×0.40) | 0.120 | 0.104 |
| Risk (×0.25) | 0.038 | **0.138** |
| Cost (×0.20) | 0.140 | 0.140 |
| Stability (×0.15) | 0.140 | **0.145** |
| **Total** | **0.438** | **0.527** |

> **Result: Compound wins despite lower APY. Risk-awareness outperforms APY-chasing.**

---

# 8. EIP-712 Signature Verification

**Agent signs structured data, vault verifies on-chain:**

```
Agent (off-chain):
  1. Build RebalanceParams{target, maxLoss, timestamp, nonce}
  2. Hash with EIP-712 domain (name, version, chainId, contract)
  3. Sign with keeper private key → (v, r, s)

Vault (on-chain):
  1. Reconstruct digest from params
  2. ecrecover(digest, v, r, s) → signer
  3. Verify: signer == keeper ✓
  4. Check: nonce, timestamp freshness, cooldown
  5. Execute rebalance
```

**Protection layers:** nonce (replay), 5-min max age (stale), domain binding (cross-chain)

---

# 9. Security Model

| Threat | Mitigation |
|--------|------------|
| **Inflation attack** | Virtual shares ($10^6$ offset) |
| **Reentrancy** | ReentrancyGuard on all externals |
| **Rate manipulation** | EMA + 5% jump guard |
| **Signature forgery** | EIP-712 + ECDSA verification |
| **Replay attack** | Sequential nonce + timestamp |
| **Agent downtime** | Chainlink Automation fallback (6h) |
| **Rapid exploitation** | 1-hour cooldown between rebalances |
| **Max loss** | Post-rebalance slippage check |

---

# 10. Testing & Formal Verification

## 67 tests, 81,800+ randomized calls, 0 failures

| Category | Tests | Technique |
|----------|-------|-----------|
| RateMath unit | 20 | Concrete + fuzz (×1000) |
| AIVault unit | 17 | Concrete + fuzz (×1000) |
| Integration | 4 | Full lifecycle E2E |
| **Invariant** | **6** | **Stateful fuzzing: 76,800 calls** |
| Python scoring | 20 | Pytest |

### Invariants proven (zero violations):
- ✓ Vault always solvent
- ✓ Accounting: deposits − withdrawals = assets
- ✓ Share conversions round-trip consistent
- ✓ Share price non-decreasing

---

# 11. Invariant Testing: Why It Matters

**Unit tests**: "Does function X work with input Y?" → specific scenarios

**Invariant tests**: "Does property P hold under ANY sequence of calls?" → universal proof

```
Foundry fuzzer generates random sequences:
  deposit(actor=3, amount=47291) → OK
  withdraw(actor=1, amount=8831) → OK  
  redeem(actor=4, amount=12003) → OK
  deposit(actor=0, amount=99102) → OK
  ...
  After each sequence: check all 6 invariants ✓

  256 sequences × 50 calls = 12,800 calls per invariant
  6 invariants × 12,800 = 76,800 total calls
  0 violations
```

---

# 12. OpenClaw: Natural Language DeFi Interface

```
User:  "What's the current APY on Aave?"
Bot:   "Aave V3: 4.82% (smoothed: 4.65%) | Utilization: 78.3%
        Compound V3: 3.15% (smoothed: 3.20%) | Utilization: 45.1%"

User:  "Should we rebalance?"
Bot:   "Score: Aave 0.62, Compound 0.58
        Delta: 0.04 < threshold 0.05
        Recommendation: HOLD — Aave still leads."

User:  "Show vault status"
Bot:   "TVL: 50,000 USDC | Active: Aave V3 | Share price: 1.0071
        Last rebalance: 3h ago | Agent: ONLINE ✓"
```

**Architecture:** Python FastAPI (port 8042) ← OpenClaw skill → Telegram/Discord

---

# 13. Architecture — Three Layers

```
┌───────────────────────────────────────────────────┐
│             INTERFACE LAYER                        │
│  OpenClaw + REST API (FastAPI, port 8042)          │
│  Natural language ↔ structured vault queries       │
├───────────────────────────────────────────────────┤
│             INTELLIGENCE LAYER                     │
│  Python Agent: MCDM scoring + EIP-712 signing      │
│  Every hour: read → smooth → score → decide → act  │
├───────────────────────────────────────────────────┤
│             EXECUTION LAYER (On-Chain)             │
│  AIVault.sol → StrategyManager → Adapters          │
│  Verify signature → Execute → Slippage check       │
│  Fallback: Chainlink Automation (after 6h)         │
└───────────────────────────────────────────────────┘
```

---

# 14. Adapter Pattern — Extensibility

```solidity
interface IProtocolAdapter {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external returns (uint256);
    function balance(address asset) external view returns (uint256);
    function getSupplyRate(address asset) external view returns (uint256);
    function getUtilization(address asset) external view returns (uint256);
}
```

**Adding a new protocol** (Morpho, Euler, Spark):
1. Implement `IProtocolAdapter` (~70 lines)
2. Register with StrategyManager
3. **Zero changes** to vault or scoring engine

---

# 15. Comparison with Existing Systems

| Feature | Yearn | Beefy | Idle | Almanak | **Ours** |
|---------|-------|-------|------|---------|----------|
| Multi-factor scoring | ✗ | ✗ | ✗ | ✓ (closed) | **✓ (open)** |
| Decision verifiability | ✓ | ✓ | ✓ | ✗ | **✓ (EIP-712)** |
| Off-chain intelligence | ✗ | ✗ | ✗ | ✓ | **✓** |
| Fallback mechanism | — | — | — | ✗ | **✓ (Chainlink)** |
| Invariant-tested | Varies | ✗ | ✗ | ? | **✓ (76K calls)** |
| Chat interface | ✗ | ✗ | ✗ | ✗ | **✓ (OpenClaw)** |
| Upgradeable | Some | ✗ | Some | — | **✓ (UUPS)** |
| Open source | ✓ | ✓ | ✓ | ✗ | **✓** |

---

# 16. Project Statistics

| Metric | Value |
|--------|-------|
| Solidity contracts | 6 contracts + 2 libraries |
| Python modules | 5 (agent) + 1 (API) |
| Total lines of code | ~2,500 |
| Tests (total) | 67 |
| Fuzz/invariant calls | 81,800+ |
| Invariant violations | **0** |
| Supported protocols | 2 (extensible to N) |
| Testnet | Ethereum Sepolia |
| Proxy pattern | UUPS (ERC-1967) |
| Token standard | ERC-4626 |

---

# 17. Key Innovations

### 1. Hybrid Architecture
Off-chain scoring power + on-chain trust guarantees

### 2. MCDM Scoring
4-factor weighted model beats single-factor APY comparison

### 3. Verifiable Decisions
Every rebalance has an EIP-712 signed proof on-chain

### 4. Formal Safety
76,800+ invariant calls prove solvency, accounting, price stability

### 5. Graceful Degradation
Chainlink fallback ensures the vault is never unmanaged

### 6. Conversational DeFi
First yield vault with a natural language interface (OpenClaw)

---

# 18. Future Work

| Priority | Enhancement | Impact |
|----------|-------------|--------|
| High | ML rate prediction (LSTM/XGBoost) | Better timing |
| High | Multi-chain (Arbitrum, Base) | Broader market |
| Medium | More adapters (Morpho, Spark, Euler) | More opportunities |
| Medium | Formal verification (Certora) | Stronger proofs |
| Low | DAO governance | Decentralization |
| Low | Risk scoring oracle | Composability |

---

<!-- _class: lead -->

# 19. Conclusion

## AI Yield Vault demonstrates that
## **agentic DeFi** — off-chain intelligence
## with on-chain verification —
## is a viable and superior paradigm
## for automated yield optimization.

**67 tests | 76,800+ invariant calls | 0 violations**
**4-factor MCDM | EIP-712 signed | Chainlink fallback | OpenClaw chat**

---

<!-- _class: lead -->

# Thank You

**Questions?**

Code: `github.com/[your-repo]`
Testnet: Ethereum Sepolia
Stack: Solidity 0.8.24 + Python 3.12 + Foundry + Docker + OpenClaw
