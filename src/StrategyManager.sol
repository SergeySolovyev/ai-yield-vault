// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyManager} from "./interfaces/IStrategyManager.sol";
import {IProtocolAdapter} from "./interfaces/IProtocolAdapter.sol";
import {RateMath} from "./libraries/RateMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StrategyManager
/// @notice Decision engine that determines when and how to rebalance between
///         protocol adapters. Supports two modes:
///         1. Agent mode: validates off-chain agent decisions (primary)
///         2. Fallback mode: on-chain APY comparison with cost threshold
///
/// @dev The StrategyManager does NOT hold funds or execute transfers.
///      It only evaluates and validates decisions. The AIVault executes.
contract StrategyManager is IStrategyManager, Ownable {
    /// @notice Registered protocol adapters
    IProtocolAdapter[] private _adapters;

    /// @notice Minimum APY improvement (in bps) required for rebalance in fallback mode
    uint256 public override minDeltaBps;

    /// @notice EMA smoothing alpha in basis points (e.g., 3000 = 30% weight on new data)
    uint256 public emAlphaBps;

    /// @notice Maximum allowed APY jump per observation (in bps) — rate manipulation guard
    uint256 public maxRateJumpBps;

    /// @notice Smoothed APY per adapter (adapter index -> smoothed rate in 1e18)
    mapping(uint256 => uint256) public smoothedRates;

    /// @notice Estimated gas cost of a rebalance operation (in wei)
    uint256 public estimatedRebalanceGas;

    /// @notice Nonce for agent-signed rebalance operations (replay protection)
    uint256 public rebalanceNonce;

    event AdapterAdded(address indexed adapter, uint256 index);
    event AdapterRemoved(address indexed adapter, uint256 index);
    event RatesUpdated(uint256 indexed adapterIndex, uint256 rawRate, uint256 smoothedRate);
    event ParametersUpdated(uint256 minDeltaBps, uint256 emAlphaBps, uint256 maxRateJumpBps);

    error AdapterAlreadyRegistered();
    error InvalidAdapterIndex();
    error RateJumpTooLarge(uint256 adapterIndex, uint256 currentRate, uint256 previousRate);

    constructor(
        address _owner,
        uint256 _minDeltaBps,
        uint256 _emAlphaBps,
        uint256 _maxRateJumpBps,
        uint256 _estimatedRebalanceGas
    ) Ownable(_owner) {
        minDeltaBps = _minDeltaBps;
        emAlphaBps = _emAlphaBps;
        maxRateJumpBps = _maxRateJumpBps;
        estimatedRebalanceGas = _estimatedRebalanceGas;
    }

    // ========== Adapter Management ==========

    /// @notice Register a new protocol adapter
    /// @param adapter The adapter to add
    function addAdapter(IProtocolAdapter adapter) external onlyOwner {
        _adapters.push(adapter);
        emit AdapterAdded(address(adapter), _adapters.length - 1);
    }

    /// @notice Get adapter by index
    function adapters(uint256 index) external view override returns (IProtocolAdapter) {
        return _adapters[index];
    }

    /// @notice Get total number of adapters
    function adapterCount() external view override returns (uint256) {
        return _adapters.length;
    }

    // ========== Fallback Mode: On-Chain Evaluation ==========

    /// @inheritdoc IStrategyManager
    function evaluate(
        address asset,
        uint256 totalAssets,
        uint256 gasPrice,
        uint256 timeSinceLastRebalance
    ) external view override returns (RebalanceDecision memory decision) {
        uint256 len = _adapters.length;
        if (len < 2 || totalAssets == 0) {
            return decision; // shouldRebalance = false by default
        }

        // Find the adapter with the highest smoothed rate
        uint256 bestIndex;
        uint256 bestRate;
        uint256 currentIndex;
        uint256 currentRate;

        for (uint256 i; i < len; ++i) {
            uint256 rawRate = _adapters[i].getSupplyRate(asset);
            uint256 smoothed = smoothedRates[i];

            // If no smoothed rate yet, use raw rate
            if (smoothed == 0) {
                smoothed = rawRate;
            }

            if (smoothed > bestRate) {
                bestRate = smoothed;
                bestIndex = i;
            }

            // Detect the current active adapter by which has the highest balance
            uint256 bal = _adapters[i].balance(asset);
            if (bal > 0) {
                currentIndex = i;
                currentRate = smoothed;
            }
        }

        // If best adapter is already active, no rebalance needed
        if (bestIndex == currentIndex) {
            return decision;
        }

        // Cost-aware threshold check:
        // deltaAPY * totalAssets / 365_days * timeSinceLastRebalance > gasCost
        uint256 apyDelta = RateMath.absDiff(bestRate, currentRate);
        uint256 apyDeltaBps = RateMath.rateToBps(apyDelta);

        if (apyDeltaBps < minDeltaBps) {
            return decision; // Delta too small
        }

        // Estimated profit from switching (in asset units, rough approximation)
        // profit ≈ totalAssets * deltaAPY * timeHorizon / 365 days
        // We use a 1-day horizon for the benefit calculation
        uint256 estimatedDailyBenefit = (totalAssets * apyDelta) / 365 days;

        // Estimated gas cost in asset terms (simplified — assumes 1 ETH = some USD)
        // In practice the agent does this more accurately off-chain
        uint256 gasCost = gasPrice * estimatedRebalanceGas;

        // Only rebalance if benefit over the cooldown period exceeds cost
        uint256 benefitOverPeriod = estimatedDailyBenefit * timeSinceLastRebalance / 1 days;

        if (benefitOverPeriod <= gasCost) {
            return decision; // Not profitable
        }

        decision.shouldRebalance = true;
        decision.fromAdapterIndex = currentIndex;
        decision.toAdapterIndex = bestIndex;
        decision.amount = totalAssets; // Move everything for simplicity
        decision.expectedApyGainBps = apyDeltaBps;
    }

    // ========== Rate Update (called by vault during rebalance) ==========

    /// @notice Update smoothed rates for all adapters
    /// @param asset The underlying asset
    function updateSmoothedRates(address asset) external {
        uint256 len = _adapters.length;
        for (uint256 i; i < len; ++i) {
            uint256 rawRate = _adapters[i].getSupplyRate(asset);
            uint256 prevSmoothed = smoothedRates[i];

            // Rate manipulation guard
            if (prevSmoothed > 0) {
                uint256 jumpBps = RateMath.rateToBps(RateMath.absDiff(rawRate, prevSmoothed));
                if (jumpBps > maxRateJumpBps) {
                    // Skip this update — rate jumped too much, possible manipulation
                    emit RatesUpdated(i, rawRate, prevSmoothed);
                    continue;
                }
            }

            uint256 newSmoothed = RateMath.emaSmooth(rawRate, prevSmoothed, emAlphaBps);
            smoothedRates[i] = newSmoothed;

            emit RatesUpdated(i, rawRate, newSmoothed);
        }
    }

    /// @notice Consume and increment the rebalance nonce (called by vault)
    /// @param expectedNonce The nonce the agent signed
    function consumeNonce(uint256 expectedNonce) external {
        require(expectedNonce == rebalanceNonce, "StrategyManager: invalid nonce");
        ++rebalanceNonce;
    }

    // ========== Parameter Management ==========

    /// @notice Update strategy parameters
    function setParameters(
        uint256 _minDeltaBps,
        uint256 _emAlphaBps,
        uint256 _maxRateJumpBps,
        uint256 _estimatedRebalanceGas
    ) external onlyOwner {
        minDeltaBps = _minDeltaBps;
        emAlphaBps = _emAlphaBps;
        maxRateJumpBps = _maxRateJumpBps;
        estimatedRebalanceGas = _estimatedRebalanceGas;
        emit ParametersUpdated(_minDeltaBps, _emAlphaBps, _maxRateJumpBps);
    }
}
