// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IComet
/// @notice Minimal interface for Compound V3 (Comet) — only functions we actually use.
///         Full interface: https://github.com/compound-finance/comet/blob/main/contracts/CometMainInterface.sol
interface IComet {
    /// @notice Supply an amount of base asset to the protocol
    /// @param asset The asset to supply
    /// @param amount The amount to supply
    function supply(address asset, uint256 amount) external;

    /// @notice Withdraw an amount of base asset from the protocol
    /// @param asset The asset to withdraw
    /// @param amount The amount to withdraw
    function withdraw(address asset, uint256 amount) external;

    /// @notice Get the balance of an account (including accrued interest)
    /// @param account The address to query
    /// @return The current balance
    function balanceOf(address account) external view returns (uint256);

    /// @notice Get the current utilization ratio
    /// @return The utilization ratio scaled by 1e18
    function getUtilization() external view returns (uint256);

    /// @notice Get the per-second supply rate for a given utilization
    /// @param utilization The utilization ratio (from getUtilization())
    /// @return The per-second supply rate scaled by 1e18
    function getSupplyRate(uint256 utilization) external view returns (uint256);

    /// @notice Get the total supply of the base asset in the protocol
    /// @return The total supply
    function totalSupply() external view returns (uint256);

    /// @notice Get the base token address
    /// @return The address of the base token (e.g., USDC)
    function baseToken() external view returns (address);

    /// @notice Allow or disallow another address to withdraw/transfer on behalf of msg.sender
    /// @param manager The address to allow
    /// @param isAllowed Whether to allow or disallow
    function allow(address manager, bool isAllowed) external;
}
