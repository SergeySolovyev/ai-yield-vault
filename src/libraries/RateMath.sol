// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RateMath
/// @notice Library for normalizing APY rates from different DeFi protocols
///         and applying Exponential Moving Average (EMA) smoothing.
///
///         All normalized rates use a common format:
///         - Annual rate scaled by 1e18 (e.g., 5% = 5e16, 0.5% = 5e15)
///
/// @dev Formulas documented in the litepaper:
///      - Aave normalization: liquidityRate (RAY=1e27) -> annual rate (1e18)
///      - Compound normalization: perSecondRate (1e18) * SECONDS_PER_YEAR -> annual rate
///      - EMA: smoothed = alpha × current + (1 - alpha) × previous
library RateMath {
    /// @notice One RAY unit used by Aave V3 (1e27)
    uint256 internal constant RAY = 1e27;

    /// @notice Seconds in a year (365.25 days to account for leap years)
    uint256 internal constant SECONDS_PER_YEAR = 365.25 days;

    /// @notice Basis point denominator (100% = 10_000 bps)
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Normalize an Aave V3 liquidity rate (RAY) to annual rate (1e18)
    /// @dev Aave's currentLiquidityRate is already an annualized rate in RAY format.
    ///      We simply rescale: rate_1e18 = rate_RAY * 1e18 / 1e27 = rate_RAY / 1e9
    /// @param liquidityRateRay The Aave liquidity rate in RAY (1e27)
    /// @return Annual supply rate scaled by 1e18
    function normalizeAaveRate(uint256 liquidityRateRay) internal pure returns (uint256) {
        return liquidityRateRay / 1e9;
    }

    /// @notice Normalize a Compound V3 per-second supply rate to annual rate (1e18)
    /// @dev Compound returns a per-second rate scaled by 1e18.
    ///      Annual rate = perSecondRate × SECONDS_PER_YEAR
    /// @param perSecondRate The Compound per-second supply rate (1e18 scale)
    /// @return Annual supply rate scaled by 1e18
    function normalizeCompoundRate(uint256 perSecondRate) internal pure returns (uint256) {
        return perSecondRate * SECONDS_PER_YEAR;
    }

    /// @notice Apply Exponential Moving Average smoothing to a rate observation
    /// @dev EMA formula: smoothed = (alpha × current + (BPS - alpha) × previous) / BPS
    ///      Alpha is in basis points: 3000 = 30% weight on new observation
    /// @param currentRate The newly observed rate (1e18)
    /// @param previousSmoothed The previous smoothed rate (1e18)
    /// @param alphaBps Weight for the new observation in basis points (0-10000)
    /// @return The smoothed rate (1e18)
    function emaSmooth(
        uint256 currentRate,
        uint256 previousSmoothed,
        uint256 alphaBps
    ) internal pure returns (uint256) {
        require(alphaBps <= BPS_DENOMINATOR, "RateMath: alpha > 100%");

        // First observation: no smoothing needed
        if (previousSmoothed == 0) {
            return currentRate;
        }

        return (currentRate * alphaBps + previousSmoothed * (BPS_DENOMINATOR - alphaBps)) / BPS_DENOMINATOR;
    }

    /// @notice Convert a normalized rate (1e18) to basis points
    /// @param rate Annual rate scaled by 1e18
    /// @return Rate in basis points (e.g., 5% = 500 bps)
    function rateToBps(uint256 rate) internal pure returns (uint256) {
        return rate * BPS_DENOMINATOR / 1e18;
    }

    /// @notice Calculate the absolute difference between two rates
    /// @param a First rate
    /// @param b Second rate
    /// @return The absolute difference |a - b|
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
