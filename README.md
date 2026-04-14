# AI Yield Vault

An ERC-4626 tokenized vault managed by an off-chain AI agent that autonomously rebalances between Aave V3 and Compound V3 on Ethereum Sepolia.

## Architecture

```
Off-chain Agent (Python)          On-chain (Solidity)
─────────────────────────         ─────────────────────
Read rates, utilization    ──►    AIVault.sol (ERC-4626 + UUPS)
Multi-factor MCDM scoring         ├── AaveV3Adapter
EIP-712 sign decision      ──►    ├── CompoundV3Adapter
Submit rebalance tx                └── StrategyManager
                                        ▲
                              Chainlink Automation (fallback)
```

**What makes this different from Yearn/Beefy:** The agent scores protocols on 4 factors (APY 40%, Risk 25%, Cost 20%, Stability 15%), not just raw APY. Every decision is EIP-712 signed and verifiable on-chain.

## Quick Start

### Prerequisites
- [Foundry](https://book.getfoundry.sh/) (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)
- Python 3.10+
- Alchemy/Infura account for Sepolia RPC

### Build & Test (Solidity)

```bash
forge build
forge test               # 47 tests (unit + integration + invariant)
forge test -vvv          # Verbose output with traces
```

### Test (Python Agent)

```bash
cd agent
pip install -r requirements.txt
pytest tests/ -v         # 20 scoring model tests
```

### Deploy to Sepolia

```bash
cp .env.example .env
# Edit .env with your keys

forge script script/Deploy.s.sol:Deploy \
  --rpc-url sepolia \
  --broadcast \
  --verify
```

### Run the Agent

```bash
cd agent
python main.py --dry-run   # Score without submitting tx
python main.py --once      # Single check
python main.py             # Continuous loop (1hr interval)
```

## Project Structure

```
src/
├── AIVault.sol                 # Core vault (ERC-4626 + UUPS + agent rebalance)
├── StrategyManager.sol         # Decision engine + adapter registry
├── adapters/
│   ├── AaveV3Adapter.sol       # Aave V3 protocol adapter
│   └── CompoundV3Adapter.sol   # Compound V3 protocol adapter
├── interfaces/
│   ├── IProtocolAdapter.sol    # Universal adapter interface
│   ├── IStrategyManager.sol    # Strategy manager interface
│   ├── IAaveV3Pool.sol         # Minimal Aave V3 interface
│   └── IComet.sol              # Minimal Compound V3 interface
└── libraries/
    ├── RateMath.sol            # APY normalization + EMA
    └── Constants.sol           # Sepolia addresses + defaults

test/
├── unit/
│   ├── RateMath.t.sol          # 20 tests (normalization, EMA, fuzz)
│   └── AIVault.t.sol           # 17 tests (deposit, withdraw, rebalance, inflation)
├── integration/
│   └── AgentFlowTest.t.sol     # 4 tests (full lifecycle, nonce replay, emergency)
└── invariant/
    └── VaultInvariant.t.sol    # 6 invariants (solvency, accounting, conversions)

agent/
├── main.py                     # Agent loop: read → score → sign → send
├── scoring.py                  # MCDM scoring engine
├── data_reader.py              # On-chain data reader (web3.py)
├── signer.py                   # EIP-712 typed data signer
├── config.py                   # Configuration + ABI loading
└── tests/
    └── test_scoring.py         # 20 scoring model tests

script/
└── Deploy.s.sol                # Foundry deployment script

docs/
└── litepaper.md                # Academic litepaper with formulas
```

## Test Results

| Suite | Tests | Status |
|-------|-------|--------|
| RateMath unit | 20 (4 fuzz x 1000 runs) | All pass |
| AIVault unit | 17 (1 fuzz x 1000 runs) | All pass |
| Integration | 4 (full lifecycle) | All pass |
| Invariant | 6 (256 runs x 50 depth = 76,800 calls) | All pass, 0 reverts |
| Python scoring | 20 | All pass |
| **Total** | **67** | **All pass** |

## Environment Variables

```bash
# .env
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
PRIVATE_KEY=0x...           # Deployer private key
KEEPER_PRIVATE_KEY=0x...    # Agent signing key
KEEPER_ADDRESS=0x...        # Agent public address
FEE_RECIPIENT=0x...         # Fee collection address
VAULT_ADDRESS=0x...         # Set after deployment
STRATEGY_MANAGER_ADDRESS=0x... # Set after deployment
ETHERSCAN_API_KEY=...       # For contract verification
```

## Security Considerations

- **Inflation attack**: Mitigated via `_decimalsOffset() = 6` (virtual shares)
- **Reentrancy**: All external functions use ReentrancyGuard
- **Signature replay**: Nonce + timestamp freshness + EIP-712 domain binding
- **Rate manipulation**: EMA smoothing + rate jump guard (5% max)
- **Cooldown**: 1-hour minimum between rebalances

## License

MIT
