#!/bin/bash
# OpenClaw shell skill — wraps the vault API for quick access
# OpenClaw can call these directly as shell commands

API="http://localhost:8042"

case "$1" in
    status)
        curl -s "$API/status" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"\"\"
=== AI Yield Vault Status ===
TVL:            {d['total_assets_usdc']:,.2f} USDC
Share Price:    {d['share_price']:.6f}
Active Strategy: {d['active_adapter_name']} (index {d['active_adapter_index']})
Strategy Active: {'Yes' if d['has_active_strategy'] else 'No'}
Paused:         {'Yes' if d['is_paused'] else 'No'}
Last Rebalance: {d['seconds_since_rebalance'] // 3600}h {(d['seconds_since_rebalance'] % 3600) // 60}m ago
Keeper:         {d['keeper'][:10]}...{d['keeper'][-6:]}
\"\"\")
"
        ;;
    rates)
        curl -s "$API/rates" | python3 -c "
import sys, json
rates = json.load(sys.stdin)
print('\n=== Protocol Rates ===')
for r in rates:
    print(f\"  {r['name']:15s} APY: {r['apy_percent']:6.2f}%  (smoothed: {r['smoothed_apy_percent']:.2f}%)  Util: {r['utilization_percent']:.1f}%\")
print()
"
        ;;
    score)
        curl -s "$API/score" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"\"\"
=== MCDM Scoring Result ===
Decision: {'REBALANCE' if d['should_rebalance'] else 'HOLD'}
Current:  {d['current_adapter']} (score: {d['current_score']:.4f})
Best:     {d['best_adapter']} (score: {d['best_score']:.4f})
Delta:    {d['score_delta']:.4f} (threshold: {d['threshold']})
\"\"\")
for s in d['details']:
    print(f\"  {s['name']:15s} Total: {s['total_score']:.3f}  APY: {s['apy_score']:.3f}  Risk: {s['risk_score']:.3f}  Cost: {s['cost_score']:.3f}  Stab: {s['stability_score']:.3f}\")
print()
"
        ;;
    rebalance)
        echo "Running dry-run rebalance..."
        curl -s -X POST "$API/rebalance?dry_run=true" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  Result: {d['message']}\")
if d.get('tx_hash'):
    print(f\"  TX: https://sepolia.etherscan.io/tx/{d['tx_hash']}\")
"
        ;;
    health)
        curl -s "$API/health" | python3 -c "
import sys, json
d = json.load(sys.stdin)
status = 'ONLINE' if d['rpc_connected'] else 'OFFLINE'
vault = 'configured' if d['vault_configured'] else 'NOT configured'
print(f'Agent: {status} | Vault: {vault}')
"
        ;;
    *)
        echo "Usage: vault-skill.sh {status|rates|score|rebalance|health}"
        ;;
esac
