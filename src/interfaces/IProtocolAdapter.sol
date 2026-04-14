// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IProtocolAdapter
/// @notice Universal interface for DeFi lending protocol adapters.
///         Each adapter wraps a single protocol (Aave, Compound, etc.)
///         and exposes a uniform API for supply, withdraw, and rate queries.
interface IProtocolAdapter {
    /// @notice Supply assets to the underlying protocol
    /// @param asset The ERC-20 token address to supply
    /// @param amount The amount of tokens to supply
    function supply(address asset, uint256 amount) external;

    /// @notice Withdraw assets from the underlying protocol
    /// @param asset The ERC-20 token address to withdraw
    /// @param amount The amount of tokens to withdraw
    /// @return withdrawn The actual amount withdrawn (may differ due to rounding)
    function withdraw(address asset, uint256 amount) external returns (uint256 withdrawn);

    /// @notice Get the current balance of supplied assets (including accrued interest)
    /// @param asset The ERC-20 token address
    /// @return The current balance in asset terms
    function balance(address asset) external view returns (uint256);

    /// @notice Get the current annualized supply rate, normalized to 1e18
    /// @param asset The ERC-20 token address
    /// @return Annual supply rate scaled by 1e18 (e.g., 5% = 0.05e18)
    function getSupplyRate(address asset) external view returns (uint256);

    /// @notice Get the current utilization ratio, normalized to 1e18
    /// @param asset The ERC-20 token address
    /// @return Utilization ratio scaled by 1e18 (e.g., 80% = 0.8e18)
    function getUtilization(address asset) external view returns (uint256);

    /// @notice Human-readable name of the protocol
    /// @return Protocol name string (e.g., "Aave V3", "Compound V3")
    function protocolName() external pure returns (string memory);
}
