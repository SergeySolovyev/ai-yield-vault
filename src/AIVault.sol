// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IStrategyManager} from "./interfaces/IStrategyManager.sol";
import {IProtocolAdapter} from "./interfaces/IProtocolAdapter.sol";
import {StrategyManager} from "./StrategyManager.sol";
import {Constants} from "./libraries/Constants.sol";

/// @title AIVault
/// @notice An ERC-4626 vault managed by an off-chain AI agent that autonomously
///         rebalances between DeFi lending protocols (Aave V3, Compound V3).
///
///         Two rebalance paths:
///         1. Agent mode: off-chain agent signs RebalanceParams, vault verifies and executes
///         2. Fallback mode: Chainlink Automation triggers on-chain evaluation if agent is idle
///
/// @dev Uses UUPS proxy pattern for upgradeability.
///      Inflation attack protection via _decimalsOffset() = 6 (for USDC vaults).
contract AIVault is
    Initializable,
    ERC4626Upgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ========== State ==========

    /// @notice The strategy manager that evaluates rebalance decisions
    StrategyManager public strategyManager;

    /// @notice Address authorized to submit signed rebalance decisions (the AI agent)
    address public keeper;

    /// @notice Index of the adapter currently holding the majority of funds
    uint256 public activeAdapterIndex;

    /// @notice Timestamp of the last rebalance
    uint256 public lastRebalanceTimestamp;

    /// @notice Minimum seconds between rebalances
    uint256 public cooldownPeriod;

    /// @notice Seconds of agent inactivity before fallback mode activates
    uint256 public agentTimeout;

    /// @notice Percentage of TVL kept as idle buffer (in bps, e.g., 200 = 2%)
    uint256 public idleBufferBps;

    /// @notice Annual management fee in basis points (e.g., 50 = 0.5%)
    uint256 public managementFeeBps;

    /// @notice Performance fee in basis points (e.g., 1000 = 10%)
    uint256 public performanceFeeBps;

    /// @notice High-water mark for performance fee calculation
    uint256 public highWaterMark;

    /// @notice Timestamp of the last fee collection
    uint256 public lastFeeTimestamp;

    /// @notice Accumulated protocol fees (in shares) to be claimed
    uint256 public accruedFeeShares;

    /// @notice Address receiving protocol fees
    address public feeRecipient;

    /// @notice Tracks whether the vault has been initialized with funds
    bool public hasActiveStrategy;

    // ========== EIP-712 Domain ==========

    bytes32 public constant REBALANCE_TYPEHASH = keccak256(
        "RebalanceParams(uint256 targetAdapterIndex,uint256 maxLossBps,uint256 timestamp,uint256 nonce)"
    );

    bytes32 private _domainSeparator;

    // ========== Events ==========

    event Rebalanced(
        uint256 indexed fromAdapter,
        uint256 indexed toAdapter,
        uint256 amount,
        bool isAgentTriggered,
        uint256 timestamp
    );
    event EmergencyWithdrawal(uint256 totalWithdrawn, uint256 timestamp);
    event FeesCollected(address indexed recipient, uint256 sharesMinted, uint256 assetsValue);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event ParametersUpdated(uint256 cooldownPeriod, uint256 agentTimeout, uint256 idleBufferBps);

    // ========== Errors ==========

    error CooldownNotElapsed();
    error AgentNotTimedOut();
    error InvalidSignature();
    error SignatureExpired();
    error InvalidAdapterIndex();
    error SlippageExceeded(uint256 totalBefore, uint256 totalAfter, uint256 maxLossBps);
    error NotKeeper();
    error NoActiveStrategy();

    // ========== Modifiers ==========

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    // ========== Initializer ==========

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the vault (called once via proxy)
    /// @param asset_ The underlying asset (e.g., USDC)
    /// @param name_ The vault token name (e.g., "AI Yield Vault")
    /// @param symbol_ The vault token symbol (e.g., "aiUSDC")
    /// @param strategyManager_ The strategy manager contract
    /// @param keeper_ The AI agent's signing address
    /// @param feeRecipient_ The address to receive fees
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address strategyManager_,
        address keeper_,
        address feeRecipient_
    ) public initializer {
        __ERC4626_init(asset_);
        __ERC20_init(name_, symbol_);
        __Ownable_init(msg.sender);
        __Pausable_init();
        // ReentrancyGuard in OZ v5 uses ERC-7201 storage, no __init needed

        strategyManager = StrategyManager(strategyManager_);
        keeper = keeper_;
        feeRecipient = feeRecipient_;

        cooldownPeriod = Constants.DEFAULT_COOLDOWN_PERIOD;
        agentTimeout = Constants.DEFAULT_AGENT_TIMEOUT;
        idleBufferBps = Constants.DEFAULT_IDLE_BUFFER_BPS;
        managementFeeBps = Constants.DEFAULT_MANAGEMENT_FEE_BPS;
        performanceFeeBps = Constants.DEFAULT_PERFORMANCE_FEE_BPS;

        lastFeeTimestamp = block.timestamp;
        lastRebalanceTimestamp = block.timestamp;

        _domainSeparator = _computeDomainSeparator();
    }

    // ========== ERC-4626 Overrides ==========

    /// @notice Returns total assets across idle balance + all protocol adapters
    /// @dev This is the most critical function — it determines share price
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 deployed;

        uint256 adapterCount = strategyManager.adapterCount();
        address underlying = asset();
        for (uint256 i; i < adapterCount; ++i) {
            deployed += strategyManager.adapters(i).balance(underlying);
        }

        return idle + deployed;
    }

    /// @dev Add decimals offset of 6 for USDC (6-decimal token) to prevent inflation attack.
    ///      This creates "virtual shares" that make the vault resistant to donation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice Deposit assets with reentrancy and pause protection
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        uint256 shares = super.deposit(assets, receiver);
        _deployIdleFunds();
        return shares;
    }

    /// @notice Mint shares with reentrancy and pause protection
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        uint256 assets = super.mint(shares, receiver);
        _deployIdleFunds();
        return assets;
    }

    /// @notice Withdraw assets — auto-unwinds from protocol if idle balance insufficient
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _ensureLiquidity(assets);
        return super.withdraw(assets, receiver, owner_);
    }

    /// @notice Redeem shares — auto-unwinds from protocol if idle balance insufficient
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        uint256 assets = previewRedeem(shares);
        _ensureLiquidity(assets);
        return super.redeem(shares, receiver, owner_);
    }

    // ========== Agent Rebalance (Primary Path) ==========

    /// @notice Execute a rebalance based on the AI agent's signed decision
    /// @param params The rebalance parameters (target adapter, max loss, timestamp, nonce)
    /// @param signature The agent's ECDSA signature over the EIP-712 typed data
    function rebalance(
        IStrategyManager.RebalanceParams calldata params,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        // Verify cooldown
        if (block.timestamp < lastRebalanceTimestamp + cooldownPeriod) {
            revert CooldownNotElapsed();
        }

        // Verify signature freshness
        if (block.timestamp > params.timestamp + Constants.SIGNATURE_MAX_AGE) {
            revert SignatureExpired();
        }

        // Verify adapter index
        if (params.targetAdapterIndex >= strategyManager.adapterCount()) {
            revert InvalidAdapterIndex();
        }

        // Verify EIP-712 signature from keeper
        bytes32 structHash = keccak256(abi.encode(
            REBALANCE_TYPEHASH,
            params.targetAdapterIndex,
            params.maxLossBps,
            params.timestamp,
            params.nonce
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator, structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != keeper) revert InvalidSignature();

        // Consume nonce (replay protection)
        strategyManager.consumeNonce(params.nonce);

        // Execute rebalance
        uint256 totalBefore = totalAssets();
        _executeRebalance(activeAdapterIndex, params.targetAdapterIndex);
        uint256 totalAfter = totalAssets();

        // Slippage check
        if (totalAfter < totalBefore * (10_000 - params.maxLossBps) / 10_000) {
            revert SlippageExceeded(totalBefore, totalAfter, params.maxLossBps);
        }

        // Update state
        uint256 previousAdapter = activeAdapterIndex;
        activeAdapterIndex = params.targetAdapterIndex;
        lastRebalanceTimestamp = block.timestamp;
        hasActiveStrategy = true;

        // Update smoothed rates
        strategyManager.updateSmoothedRates(asset());

        // Collect performance fee if applicable
        _collectPerformanceFee();

        emit Rebalanced(previousAdapter, params.targetAdapterIndex, totalBefore, true, block.timestamp);
    }

    // ========== Fallback Rebalance (Chainlink Automation) ==========

    /// @notice Check if a fallback rebalance is needed (Chainlink Automation compatible)
    /// @return upkeepNeeded Whether rebalance should occur
    /// @return performData Encoded rebalance decision
    function checkUpkeep(bytes calldata)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (paused()) return (false, "");
        if (block.timestamp < lastRebalanceTimestamp + cooldownPeriod) return (false, "");

        // Only activate fallback if agent hasn't called recently
        if (block.timestamp < lastRebalanceTimestamp + agentTimeout) return (false, "");

        IStrategyManager.RebalanceDecision memory decision = strategyManager.evaluate(
            asset(),
            totalAssets(),
            tx.gasprice,
            block.timestamp - lastRebalanceTimestamp
        );

        if (decision.shouldRebalance) {
            upkeepNeeded = true;
            performData = abi.encode(decision);
        }
    }

    /// @notice Execute a fallback rebalance (called by Chainlink Automation)
    /// @param /*performData*/ Encoded decision (re-validated on-chain for safety)
    function performUpkeep(bytes calldata /*performData*/) external nonReentrant whenNotPaused {
        // Re-validate everything on-chain (don't trust performData)
        require(
            block.timestamp >= lastRebalanceTimestamp + cooldownPeriod,
            "AIVault: cooldown"
        );
        require(
            block.timestamp >= lastRebalanceTimestamp + agentTimeout,
            "AIVault: agent not timed out"
        );

        IStrategyManager.RebalanceDecision memory decision = strategyManager.evaluate(
            asset(),
            totalAssets(),
            tx.gasprice,
            block.timestamp - lastRebalanceTimestamp
        );
        require(decision.shouldRebalance, "AIVault: no rebalance needed");

        // Execute
        uint256 totalBefore = totalAssets();
        _executeRebalance(decision.fromAdapterIndex, decision.toAdapterIndex);

        // Slippage check with default max loss
        uint256 totalAfter = totalAssets();
        if (totalAfter < totalBefore * (10_000 - Constants.DEFAULT_MAX_LOSS_BPS) / 10_000) {
            revert SlippageExceeded(totalBefore, totalAfter, Constants.DEFAULT_MAX_LOSS_BPS);
        }

        // Update state
        uint256 previousAdapter = activeAdapterIndex;
        activeAdapterIndex = decision.toAdapterIndex;
        lastRebalanceTimestamp = block.timestamp;
        hasActiveStrategy = true;

        strategyManager.updateSmoothedRates(asset());
        _collectPerformanceFee();

        emit Rebalanced(previousAdapter, decision.toAdapterIndex, totalBefore, false, block.timestamp);
    }

    // ========== Emergency Functions ==========

    /// @notice Pause the vault — stops deposits, withdrawals, and rebalancing
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the vault
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Emergency: withdraw all funds from all protocols to idle
    function emergencyWithdrawAll() external onlyOwner {
        uint256 totalWithdrawn;
        address underlying = asset();
        uint256 adapterCount = strategyManager.adapterCount();

        for (uint256 i; i < adapterCount; ++i) {
            IProtocolAdapter adapter = strategyManager.adapters(i);
            uint256 bal = adapter.balance(underlying);
            if (bal > 0) {
                IERC20(underlying).forceApprove(address(adapter), 0);
                uint256 withdrawn = adapter.withdraw(underlying, bal);
                totalWithdrawn += withdrawn;
            }
        }

        hasActiveStrategy = false;
        emit EmergencyWithdrawal(totalWithdrawn, block.timestamp);
    }

    // ========== Admin Functions ==========

    /// @notice Update the keeper (AI agent) address
    function setKeeper(address newKeeper) external onlyOwner {
        address old = keeper;
        keeper = newKeeper;
        emit KeeperUpdated(old, newKeeper);
    }

    /// @notice Update vault parameters
    function setParameters(
        uint256 _cooldownPeriod,
        uint256 _agentTimeout,
        uint256 _idleBufferBps
    ) external onlyOwner {
        cooldownPeriod = _cooldownPeriod;
        agentTimeout = _agentTimeout;
        idleBufferBps = _idleBufferBps;
        emit ParametersUpdated(_cooldownPeriod, _agentTimeout, _idleBufferBps);
    }

    /// @notice Update fee parameters
    function setFees(uint256 _managementFeeBps, uint256 _performanceFeeBps) external onlyOwner {
        require(_managementFeeBps <= 500, "AIVault: management fee too high"); // max 5%
        require(_performanceFeeBps <= 3000, "AIVault: performance fee too high"); // max 30%
        managementFeeBps = _managementFeeBps;
        performanceFeeBps = _performanceFeeBps;
    }

    /// @notice Claim accumulated fee shares
    function claimFees() external {
        require(msg.sender == feeRecipient || msg.sender == owner(), "AIVault: not authorized");
        uint256 shares = accruedFeeShares;
        if (shares > 0) {
            accruedFeeShares = 0;
            _mint(feeRecipient, shares);
            emit FeesCollected(feeRecipient, shares, convertToAssets(shares));
        }
    }

    /// @notice Get the EIP-712 domain separator
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator;
    }

    // ========== Internal Functions ==========

    /// @dev Deploy excess idle funds to the active protocol adapter
    function _deployIdleFunds() internal {
        if (!hasActiveStrategy) return;

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 total = totalAssets();
        if (total == 0) return;

        uint256 targetIdle = (total * idleBufferBps) / 10_000;

        if (idle > targetIdle) {
            uint256 toDeposit = idle - targetIdle;
            IProtocolAdapter adapter = strategyManager.adapters(activeAdapterIndex);
            IERC20(asset()).forceApprove(address(adapter), toDeposit);
            adapter.supply(asset(), toDeposit);
        }
    }

    /// @dev Ensure the vault has enough idle liquidity for a withdrawal
    function _ensureLiquidity(uint256 assets) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= assets) return;

        uint256 needed = assets - idle;

        // Withdraw from adapters to cover the deficit
        uint256 adapterCount = strategyManager.adapterCount();
        address underlying = asset();

        // First try the active adapter
        if (hasActiveStrategy) {
            IProtocolAdapter activeAdapter = strategyManager.adapters(activeAdapterIndex);
            uint256 activeBal = activeAdapter.balance(underlying);
            uint256 toWithdraw = needed > activeBal ? activeBal : needed;
            if (toWithdraw > 0) {
                activeAdapter.withdraw(underlying, toWithdraw);
                needed -= toWithdraw;
            }
        }

        // If still not enough, try other adapters
        if (needed > 0) {
            for (uint256 i; i < adapterCount && needed > 0; ++i) {
                if (i == activeAdapterIndex && hasActiveStrategy) continue;
                IProtocolAdapter adapter = strategyManager.adapters(i);
                uint256 bal = adapter.balance(underlying);
                uint256 toWithdraw = needed > bal ? bal : needed;
                if (toWithdraw > 0) {
                    adapter.withdraw(underlying, toWithdraw);
                    needed -= toWithdraw;
                }
            }
        }
    }

    /// @dev Execute the actual rebalance: withdraw from source, supply to target
    function _executeRebalance(uint256 fromIndex, uint256 toIndex) internal {
        if (fromIndex == toIndex) return;

        address underlying = asset();
        IProtocolAdapter fromAdapter = strategyManager.adapters(fromIndex);
        IProtocolAdapter toAdapter = strategyManager.adapters(toIndex);

        // Withdraw all from source adapter
        uint256 fromBalance = fromAdapter.balance(underlying);
        if (fromBalance > 0) {
            fromAdapter.withdraw(underlying, fromBalance);
        }

        // Supply all idle (including just-withdrawn) to target adapter, keeping buffer
        uint256 idle = IERC20(underlying).balanceOf(address(this));
        uint256 total = idle; // After withdrawal, idle ≈ total
        uint256 targetIdle = (total * idleBufferBps) / 10_000;

        if (idle > targetIdle) {
            uint256 toSupply = idle - targetIdle;
            IERC20(underlying).forceApprove(address(toAdapter), toSupply);
            toAdapter.supply(underlying, toSupply);
        }
    }

    /// @dev Collect performance fee based on high-water mark
    function _collectPerformanceFee() internal {
        if (performanceFeeBps == 0 || totalSupply() == 0) return;

        uint256 currentSharePrice = convertToAssets(1e18); // price per 1e18 shares
        if (currentSharePrice > highWaterMark) {
            uint256 profit = currentSharePrice - highWaterMark;
            uint256 feeAssets = (profit * performanceFeeBps * totalSupply()) / (10_000 * 1e18);
            if (feeAssets > 0) {
                uint256 feeShares = convertToShares(feeAssets);
                accruedFeeShares += feeShares;
            }
            highWaterMark = currentSharePrice;
        } else if (highWaterMark == 0) {
            highWaterMark = currentSharePrice;
        }
    }

    /// @dev Compute the EIP-712 domain separator
    function _computeDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("AIVault")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    /// @dev Authorize UUPS upgrades — only owner
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
