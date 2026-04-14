"""
EIP-712 Typed Data signer for the AI agent.

Signs RebalanceParams as EIP-712 structured data, producing
a signature that the AIVault contract can verify on-chain.
The agent's private key is the "keeper" authorized in the vault.
"""

import time

from eth_account import Account
from eth_account.messages import encode_typed_data

import config


def sign_rebalance_params(
    target_adapter_index: int,
    max_loss_bps: int,
    nonce: int,
    private_key: str | None = None,
) -> dict:
    """
    Sign a RebalanceParams struct using EIP-712.

    Args:
        target_adapter_index: Which adapter to move funds to
        max_loss_bps:         Max acceptable slippage in basis points
        nonce:                Current rebalance nonce from StrategyManager
        private_key:          Keeper's private key (defaults to config)

    Returns:
        Dict with keys: signature, timestamp, params (for tx building)
    """
    pk = private_key or config.PRIVATE_KEY
    timestamp = int(time.time())

    message = {
        "targetAdapterIndex": target_adapter_index,
        "maxLossBps": max_loss_bps,
        "timestamp": timestamp,
        "nonce": nonce,
    }

    # Build the full EIP-712 domain + types + message
    # Update domain with current vault address
    domain = dict(config.EIP712_DOMAIN)
    if config.VAULT_ADDRESS:
        domain["verifyingContract"] = config.VAULT_ADDRESS

    signable = encode_typed_data(
        domain_data=domain,
        types=config.EIP712_TYPES,
        primary_type="RebalanceParams",
        message_data=message,
    )

    signed = Account.sign_message(signable, private_key=pk)

    return {
        "signature": signed.signature.hex(),
        "timestamp": timestamp,
        "params": message,
        "signer": Account.from_key(pk).address,
    }
