// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Constants
/// @notice Deployment addresses and protocol constants for Sepolia testnet.
///         These are verified Sepolia addresses from official documentation.
/// @dev Update these constants when deploying to a different network.
library Constants {
    // ========== Aave V3 Sepolia ==========
    address internal constant AAVE_V3_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address internal constant AAVE_V3_POOL_DATA_PROVIDER = 0x3e9708d80f7B3e43118013075F7e95CE3AB31F31;

    // ========== Compound V3 Sepolia ==========
    address internal constant COMPOUND_V3_COMET_USDC = 0xAec1F48e02Cfb822Be958B68C7957156EB3F0b6e;

    // ========== Tokens (Sepolia) ==========
    // Note: Use the Aave faucet USDC, not Circle faucet — they may differ
    address internal constant USDC_SEPOLIA = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;

    // ========== Default Parameters ==========
    uint256 internal constant DEFAULT_COOLDOWN_PERIOD = 1 hours;
    uint256 internal constant DEFAULT_AGENT_TIMEOUT = 6 hours;
    uint256 internal constant DEFAULT_IDLE_BUFFER_BPS = 200; // 2%
    uint256 internal constant DEFAULT_MIN_DELTA_BPS = 50; // 0.5% minimum APY improvement
    uint256 internal constant DEFAULT_MAX_LOSS_BPS = 50; // 0.5% max slippage on rebalance
    uint256 internal constant DEFAULT_EMA_ALPHA_BPS = 3000; // 30% weight on new observation

    // ========== Fees ==========
    uint256 internal constant DEFAULT_MANAGEMENT_FEE_BPS = 50; // 0.5% annual
    uint256 internal constant DEFAULT_PERFORMANCE_FEE_BPS = 1000; // 10% of profit

    // ========== Strategy Manager Defaults ==========
    uint256 internal constant DEFAULT_MAX_RATE_JUMP_BPS = 500; // 5% max rate jump per observation
    uint256 internal constant DEFAULT_ESTIMATED_REBALANCE_GAS = 200_000;

    // ========== Signature ==========
    uint256 internal constant SIGNATURE_MAX_AGE = 5 minutes;
}
