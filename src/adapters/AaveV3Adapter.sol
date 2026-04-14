// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IAaveV3Pool} from "../interfaces/IAaveV3Pool.sol";
import {RateMath} from "../libraries/RateMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title AaveV3Adapter
/// @notice Protocol adapter for Aave V3 lending POOL.
///         Wraps supply/withdraw/balance/rate operations for a single asset.
/// @dev Owned by the AIVault — only the vault can supply/withdraw.
///      The adapter holds aTokens on behalf of the vault.
contract AaveV3Adapter is IProtocolAdapter, Ownable {
    using SafeERC20 for IERC20;

    IAaveV3Pool public immutable POOL;

    /// @notice Cached aToken address for the asset (set on first supply)
    mapping(address asset => address aToken) public aTokenForAsset;

    event Supplied(address indexed asset, uint256 amount);
    event Withdrawn(address indexed asset, uint256 amount, uint256 actual);

    error ATokenNotFound();

    constructor(address pool_, address _owner) Ownable(_owner) {
        POOL = IAaveV3Pool(pool_);
    }

    /// @inheritdoc IProtocolAdapter
    function supply(address asset, uint256 amount) external onlyOwner {
        // Cache aToken address if not yet known
        if (aTokenForAsset[asset] == address(0)) {
            _cacheAToken(asset);
        }

        // Transfer asset from vault to this adapter, then supply to Aave
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(POOL), amount);
        POOL.supply(asset, amount, address(this), 0);

        emit Supplied(asset, amount);
    }

    /// @inheritdoc IProtocolAdapter
    function withdraw(address asset, uint256 amount) external onlyOwner returns (uint256 withdrawn) {
        // Withdraw from Aave directly to the vault (msg.sender)
        withdrawn = POOL.withdraw(asset, amount, msg.sender);

        emit Withdrawn(asset, amount, withdrawn);
    }

    /// @inheritdoc IProtocolAdapter
    function balance(address asset) external view returns (uint256) {
        address aToken = aTokenForAsset[asset];
        if (aToken == address(0)) {
            // Try to get aToken dynamically if not cached
            IAaveV3Pool.ReserveData memory data = POOL.getReserveData(asset);
            aToken = data.aTokenAddress;
            if (aToken == address(0)) return 0;
        }
        return IERC20(aToken).balanceOf(address(this));
    }

    /// @inheritdoc IProtocolAdapter
    function getSupplyRate(address asset) external view returns (uint256) {
        IAaveV3Pool.ReserveData memory data = POOL.getReserveData(asset);
        // currentLiquidityRate is in RAY (1e27), normalize to 1e18 annual
        return RateMath.normalizeAaveRate(uint256(data.currentLiquidityRate));
    }

    /// @inheritdoc IProtocolAdapter
    function getUtilization(address asset) external view returns (uint256) {
        // Aave doesn't expose utilization directly, but we can derive it
        // For simplicity, return 0 — the off-chain agent computes this from DataProvider
        // In production, use IPoolDataProvider to get total supply/debt
        IAaveV3Pool.ReserveData memory data = POOL.getReserveData(asset);
        // Utilization ≈ variableBorrowRate / maxBorrowRate, but approximate
        // For now return a basic estimate from the rate ratio
        if (data.currentLiquidityRate == 0) return 0;
        // Rough approximation: utilization correlates with supplyRate/borrowRate
        uint256 supplyRate = uint256(data.currentLiquidityRate);
        uint256 borrowRate = uint256(data.currentVariableBorrowRate);
        if (borrowRate == 0) return 0;
        return (supplyRate * 1e18) / borrowRate;
    }

    /// @inheritdoc IProtocolAdapter
    function protocolName() external pure returns (string memory) {
        return "Aave V3";
    }

    /// @dev Cache the aToken address for an asset from Aave's reserve data
    function _cacheAToken(address asset) internal {
        IAaveV3Pool.ReserveData memory data = POOL.getReserveData(asset);
        if (data.aTokenAddress == address(0)) revert ATokenNotFound();
        aTokenForAsset[asset] = data.aTokenAddress;
    }
}
