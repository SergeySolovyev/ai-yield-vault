// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IComet} from "../interfaces/IComet.sol";
import {RateMath} from "../libraries/RateMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CompoundV3Adapter
/// @notice Protocol adapter for Compound V3 (Comet).
///         Wraps supply/withdraw/balance/rate operations for the base asset.
/// @dev Owned by the AIVault — only the vault can supply/withdraw.
///      In Compound V3, the Comet contract itself tracks balances (no separate cToken).
contract CompoundV3Adapter is IProtocolAdapter, Ownable {
    using SafeERC20 for IERC20;

    IComet public immutable COMET;

    event Supplied(address indexed asset, uint256 amount);
    event Withdrawn(address indexed asset, uint256 amount);

    constructor(address comet_, address _owner) Ownable(_owner) {
        COMET = IComet(comet_);
    }

    /// @inheritdoc IProtocolAdapter
    function supply(address asset, uint256 amount) external onlyOwner {
        // Transfer asset from vault to this adapter, then supply to Compound
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(COMET), amount);
        COMET.supply(asset, amount);

        emit Supplied(asset, amount);
    }

    /// @inheritdoc IProtocolAdapter
    function withdraw(address asset, uint256 amount) external onlyOwner returns (uint256 withdrawn) {
        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        COMET.withdraw(asset, amount);
        uint256 balAfter = IERC20(asset).balanceOf(address(this));
        withdrawn = balAfter - balBefore;

        // Transfer withdrawn funds back to the vault
        if (withdrawn > 0) {
            IERC20(asset).safeTransfer(msg.sender, withdrawn);
        }
    }

    /// @inheritdoc IProtocolAdapter
    function balance(address /*asset*/) external view returns (uint256) {
        // Compound V3 balanceOf returns the current balance with accrued interest
        return COMET.balanceOf(address(this));
    }

    /// @inheritdoc IProtocolAdapter
    function getSupplyRate(address /*asset*/) external view returns (uint256) {
        uint256 utilization = COMET.getUtilization();
        uint256 perSecondRate = COMET.getSupplyRate(utilization);
        return RateMath.normalizeCompoundRate(perSecondRate);
    }

    /// @inheritdoc IProtocolAdapter
    function getUtilization(address /*asset*/) external view returns (uint256) {
        return COMET.getUtilization();
    }

    /// @inheritdoc IProtocolAdapter
    function protocolName() external pure returns (string memory) {
        return "Compound V3";
    }
}
