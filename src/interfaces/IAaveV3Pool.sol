// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAaveV3Pool
/// @notice Minimal interface for Aave V3 Pool — only functions we actually use.
///         Full interface: https://github.com/aave/aave-v3-core/blob/master/contracts/interfaces/IPool.sol
interface IAaveV3Pool {
    /// @notice Supplies an `amount` of underlying asset, receiving aTokens in return.
    /// @param asset The address of the underlying asset to supply
    /// @param amount The amount to supply
    /// @param onBehalfOf The address that will receive the aTokens
    /// @param referralCode Code used for 3rd party referral integration (use 0)
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraws an `amount` of underlying asset from the reserve.
    /// @param asset The address of the underlying asset
    /// @param amount The amount to withdraw (use type(uint256).max for full balance)
    /// @param to The address that will receive the underlying asset
    /// @return The final amount withdrawn
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Returns the state and configuration of the reserve
    /// @param asset The address of the underlying asset
    /// @return ReserveData struct (we only use currentLiquidityRate and aTokenAddress)
    function getReserveData(address asset) external view returns (ReserveData memory);

    struct ReserveData {
        // Stores the reserve configuration (bitmap)
        uint256 configuration;
        // The liquidity index in ray (1e27)
        uint128 liquidityIndex;
        // The current supply rate in ray (1e27). This is what we use for APY.
        uint128 currentLiquidityRate;
        // Variable borrow index in ray
        uint128 variableBorrowIndex;
        // The current variable borrow rate in ray
        uint128 currentVariableBorrowRate;
        // Timestamp of last update
        uint40 lastUpdateTimestamp;
        // Token ID of the associated aToken
        uint16 id;
        // Address of the aToken
        address aTokenAddress;
        // Address of the stable debt token (deprecated in V3.1)
        address stableDebtTokenAddress;
        // Address of the variable debt token
        address variableDebtTokenAddress;
        // Address of the interest rate strategy
        address interestRateStrategyAddress;
        // The current treasury balance (scaled)
        uint128 accruedToTreasury;
        // Outstanding unbacked aTokens minted via the bridge
        uint128 unbacked;
        // Outstanding debt from isolation mode
        uint128 isolationModeTotalDebt;
    }
}
