// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AIVault} from "../../src/AIVault.sol";
import {StrategyManager} from "../../src/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/IStrategyManager.sol";
import {IProtocolAdapter} from "../../src/interfaces/IProtocolAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// ========== Mock Contracts ==========

/// @dev Simple ERC-20 mock for testing (represents USDC with 6 decimals)
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock protocol adapter — simulates a lending protocol for testing
contract MockAdapter is IProtocolAdapter {
    mapping(address => uint256) private _balances;
    uint256 private _supplyRate;
    uint256 private _utilization;

    IERC20 public token;

    constructor(address token_) {
        token = IERC20(token_);
    }

    function setSupplyRate(uint256 rate) external {
        _supplyRate = rate;
    }

    function setUtilization(uint256 util) external {
        _utilization = util;
    }

    function supply(address asset, uint256 amount) external override {
        token.transferFrom(msg.sender, address(this), amount);
        _balances[asset] += amount;
    }

    function withdraw(address asset, uint256 amount) external override returns (uint256) {
        uint256 bal = _balances[asset];
        uint256 toWithdraw = amount > bal ? bal : amount;
        _balances[asset] -= toWithdraw;
        token.transfer(msg.sender, toWithdraw);
        return toWithdraw;
    }

    function balance(address asset) external view override returns (uint256) {
        return _balances[asset];
    }

    function getSupplyRate(address) external view override returns (uint256) {
        return _supplyRate;
    }

    function getUtilization(address) external view override returns (uint256) {
        return _utilization;
    }

    function protocolName() external pure override returns (string memory) {
        return "MockProtocol";
    }

    /// @dev Simulate interest accrual (for testing)
    function simulateInterest(address asset, uint256 amount) external {
        _balances[asset] += amount;
    }
}

// ========== Test Contract ==========

contract AIVaultTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    AIVault public vault;
    AIVault public vaultImpl;
    StrategyManager public strategyManager;
    MockUSDC public usdc;
    MockAdapter public aaveAdapter;
    MockAdapter public compoundAdapter;

    address public owner = address(this);
    uint256 public keeperPk = 0xBEEF;
    address public keeper = vm.addr(keeperPk);
    address public feeRecipient = makeAddr("feeRecipient");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant INITIAL_BALANCE = 100_000e6; // 100k USDC

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockUSDC();

        // Deploy mock adapters
        aaveAdapter = new MockAdapter(address(usdc));
        compoundAdapter = new MockAdapter(address(usdc));

        // Set initial rates: Aave 5%, Compound 3%
        aaveAdapter.setSupplyRate(5e16);     // 5% annual (1e18 scale)
        compoundAdapter.setSupplyRate(3e16); // 3% annual

        // Deploy strategy manager
        strategyManager = new StrategyManager(
            owner,
            50,     // minDeltaBps (0.5%)
            3000,   // emAlphaBps (30%)
            500,    // maxRateJumpBps (5%)
            200_000 // estimatedRebalanceGas
        );

        // Register adapters
        strategyManager.addAdapter(IProtocolAdapter(address(aaveAdapter)));
        strategyManager.addAdapter(IProtocolAdapter(address(compoundAdapter)));

        // Deploy vault via UUPS proxy
        vaultImpl = new AIVault();
        bytes memory initData = abi.encodeCall(
            AIVault.initialize,
            (IERC20(address(usdc)), "AI Yield Vault", "aiUSDC", address(strategyManager), keeper, feeRecipient)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = AIVault(address(proxy));

        // Mint USDC to test users
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);

        // Mint USDC to adapters (so they can simulate having funds)
        usdc.mint(address(aaveAdapter), 1_000_000e6);
        usdc.mint(address(compoundAdapter), 1_000_000e6);

        // Approve vault for deposits
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ========== Deposit Tests ==========

    function test_deposit_basic() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.balanceOf(alice), shares, "Share balance mismatch");
        assertEq(vault.totalAssets(), depositAmount, "Total assets should match deposit");
    }

    function test_deposit_multipleUsers() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(bob);
        vault.deposit(5_000e6, bob);

        assertEq(vault.totalAssets(), 15_000e6, "Total assets should be sum of deposits");
    }

    function test_deposit_whenPaused_reverts() public {
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(10_000e6, alice);
    }

    // ========== Withdraw Tests ==========

    function test_withdraw_basic() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(depositAmount, alice, alice);

        assertEq(usdc.balanceOf(alice) - balBefore, depositAmount, "Should receive full deposit back");
        assertEq(vault.balanceOf(alice), 0, "Should have no shares left");
    }

    function test_withdraw_partial() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(alice);
        vault.withdraw(3_000e6, alice, alice);

        assertApproxEqAbs(vault.totalAssets(), 7_000e6, 1, "Should have 7k remaining");
    }

    // ========== Agent Rebalance Tests ==========

    function test_rebalance_agentSigned() public {
        // Deposit funds first
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        // Approve adapter to pull funds from vault (simulate deployment)
        vm.prank(address(vault));
        usdc.approve(address(aaveAdapter), type(uint256).max);

        // Advance time past the cooldown period (initialized at block.timestamp=1)
        vm.warp(block.timestamp + 1 hours);

        // Build signed rebalance params
        IStrategyManager.RebalanceParams memory params = IStrategyManager.RebalanceParams({
            targetAdapterIndex: 0, // Aave
            maxLossBps: 50,
            timestamp: block.timestamp,
            nonce: 0
        });

        bytes memory signature = _signRebalanceParams(params);

        // Execute rebalance
        vault.rebalance(params, signature);

        assertEq(vault.activeAdapterIndex(), 0, "Active adapter should be Aave");
        assertTrue(vault.hasActiveStrategy(), "Should have active strategy");
    }

    function test_rebalance_invalidSignature_reverts() public {
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        vm.warp(block.timestamp + 1 hours);

        IStrategyManager.RebalanceParams memory params = IStrategyManager.RebalanceParams({
            targetAdapterIndex: 0,
            maxLossBps: 50,
            timestamp: block.timestamp,
            nonce: 0
        });

        // Sign with wrong key
        uint256 wrongPk = 0xDEAD;
        bytes memory signature = _signRebalanceParamsWithKey(params, wrongPk);

        vm.expectRevert(AIVault.InvalidSignature.selector);
        vault.rebalance(params, signature);
    }

    function test_rebalance_expiredSignature_reverts() public {
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        // Advance past cooldown first
        vm.warp(block.timestamp + 1 hours);

        IStrategyManager.RebalanceParams memory params = IStrategyManager.RebalanceParams({
            targetAdapterIndex: 0,
            maxLossBps: 50,
            timestamp: block.timestamp,
            nonce: 0
        });

        bytes memory signature = _signRebalanceParams(params);

        // Advance time past signature expiry (SIGNATURE_MAX_AGE = 5 min)
        vm.warp(block.timestamp + 6 minutes);

        vm.expectRevert(AIVault.SignatureExpired.selector);
        vault.rebalance(params, signature);
    }

    function test_rebalance_cooldown_reverts() public {
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        vm.prank(address(vault));
        usdc.approve(address(aaveAdapter), type(uint256).max);

        // Advance past initial cooldown
        vm.warp(block.timestamp + 1 hours);

        // First rebalance succeeds
        IStrategyManager.RebalanceParams memory params1 = IStrategyManager.RebalanceParams({
            targetAdapterIndex: 0,
            maxLossBps: 50,
            timestamp: block.timestamp,
            nonce: 0
        });
        vault.rebalance(params1, _signRebalanceParams(params1));

        // Second rebalance within cooldown fails
        IStrategyManager.RebalanceParams memory params2 = IStrategyManager.RebalanceParams({
            targetAdapterIndex: 1,
            maxLossBps: 50,
            timestamp: block.timestamp,
            nonce: 1
        });

        // Pre-compute signature BEFORE vm.expectRevert (it makes external calls that would consume the expectRevert)
        bytes memory sig2 = _signRebalanceParams(params2);
        vm.expectRevert(AIVault.CooldownNotElapsed.selector);
        vault.rebalance(params2, sig2);
    }

    // ========== Emergency Tests ==========

    function test_emergencyWithdrawAll() public {
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        // Manually supply to adapter (simulate active strategy)
        vm.startPrank(address(vault));
        usdc.approve(address(aaveAdapter), 40_000e6);
        aaveAdapter.supply(address(usdc), 40_000e6);
        vm.stopPrank();

        // Verify funds are in adapter
        assertEq(aaveAdapter.balance(address(usdc)), 40_000e6, "Adapter should hold funds");

        // Emergency withdraw
        vault.emergencyWithdrawAll();

        assertFalse(vault.hasActiveStrategy(), "Strategy should be deactivated");
        // All funds should be back in vault as idle
        assertEq(usdc.balanceOf(address(vault)), 50_000e6, "All funds should be idle in vault");
    }

    function test_pause_unpause() public {
        vault.pause();
        assertTrue(vault.paused(), "Should be paused");

        vault.unpause();
        assertFalse(vault.paused(), "Should be unpaused");
    }

    // ========== Admin Tests ==========

    function test_setKeeper() public {
        address newKeeper = makeAddr("newKeeper");
        vault.setKeeper(newKeeper);
        assertEq(vault.keeper(), newKeeper, "Keeper should be updated");
    }

    function test_setKeeper_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setKeeper(alice);
    }

    function test_setFees() public {
        vault.setFees(100, 2000); // 1% management, 20% performance
        assertEq(vault.managementFeeBps(), 100);
        assertEq(vault.performanceFeeBps(), 2000);
    }

    function test_setFees_tooHigh_reverts() public {
        vm.expectRevert("AIVault: management fee too high");
        vault.setFees(501, 1000); // >5% management fee
    }

    // ========== ERC-4626 Inflation Attack Resistance ==========

    function test_inflationAttack_mitigated() public {
        // This test verifies the vault is resistant to the classic ERC-4626
        // donation/inflation attack via the _decimalsOffset() = 6

        // Attacker deposits 1 wei
        usdc.mint(address(this), 1);
        usdc.approve(address(vault), 1);
        uint256 attackerShares = vault.deposit(1, address(this));

        // Attacker "donates" a large amount directly to the vault
        usdc.mint(address(vault), 10_000e6);

        // Victim deposits
        vm.prank(alice);
        uint256 victimShares = vault.deposit(10_000e6, alice);

        // With _decimalsOffset = 6, victim should still get meaningful shares
        // Without it, victim would get 0 shares (the attack)
        assertGt(victimShares, 0, "Victim should receive shares (attack mitigated)");

        // Victim's shares should represent roughly their deposit amount
        uint256 victimAssets = vault.convertToAssets(victimShares);
        assertApproxEqRel(victimAssets, 10_000e6, 0.01e18, "Victim assets should be ~10k USDC");
    }

    // ========== Fuzz Tests ==========

    function testFuzz_depositWithdraw_roundTrip(uint256 amount) public {
        amount = bound(amount, 1e6, 50_000e6); // 1 USDC to 50k USDC

        vm.startPrank(alice);
        uint256 shares = vault.deposit(amount, alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        // Due to rounding, we may lose up to 1 wei
        assertApproxEqAbs(withdrawn, amount, 1, "Should get back approximately the same amount");
    }

    // ========== Helper Functions ==========

    function _signRebalanceParams(IStrategyManager.RebalanceParams memory params)
        internal
        view
        returns (bytes memory)
    {
        return _signRebalanceParamsWithKey(params, keeperPk);
    }

    function _signRebalanceParamsWithKey(
        IStrategyManager.RebalanceParams memory params,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            vault.REBALANCE_TYPEHASH(),
            params.targetAdapterIndex,
            params.maxLossBps,
            params.timestamp,
            params.nonce
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(vault.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
