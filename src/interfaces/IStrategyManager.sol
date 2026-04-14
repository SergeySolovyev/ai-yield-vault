// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProtocolAdapter} from "./IProtocolAdapter.sol";

/// @title IStrategyManager
/// @notice Interface for the strategy decision engine that determines
///         when and how to rebalance between protocol adapters.
interface IStrategyManager {
    /// @notice The result of evaluating whether a rebalance should occur
    struct RebalanceDecision {
        bool shouldRebalance;
        uint256 fromAdapterIndex;
        uint256 toAdapterIndex;
        uint256 amount;
        uint256 expectedApyGainBps; // expected improvement in basis points
    }

    /// @notice Parameters signed by the off-chain AI agent for rebalance
    struct RebalanceParams {
        uint256 targetAdapterIndex;
        uint256 maxLossBps;
        uint256 timestamp;
        uint256 nonce;
    }

    /// @notice Evaluate on-chain whether a rebalance is profitable (fallback mode)
    /// @param asset The underlying asset address
    /// @param totalAssets Current total assets in the vault
    /// @param gasPrice Current gas price in wei
    /// @param timeSinceLastRebalance Seconds since the last rebalance
    /// @return decision The rebalance decision
    function evaluate(
        address asset,
        uint256 totalAssets,
        uint256 gasPrice,
        uint256 timeSinceLastRebalance
    ) external view returns (RebalanceDecision memory decision);

    /// @notice Get an adapter by index
    /// @param index The adapter index
    /// @return The protocol adapter at that index
    function adapters(uint256 index) external view returns (IProtocolAdapter);

    /// @notice Get the number of registered adapters
    /// @return The adapter count
    function adapterCount() external view returns (uint256);

    /// @notice Get the minimum APY delta (in bps) required for rebalance in fallback mode
    /// @return Minimum delta in basis points
    function minDeltaBps() external view returns (uint256);
}
