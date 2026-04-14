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

// ── Mocks (same pattern as unit tests) ──────────────────────────────

contract FlowMockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract FlowMockAdapter is IProtocolAdapter {
    mapping(address => uint256) private _balances;
    uint256 private _supplyRate;
    IERC20 public token;

    constructor(address token_) { token = IERC20(token_); }

    function setSupplyRate(uint256 rate) external { _supplyRate = rate; }
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
    function balance(address asset) external view override returns (uint256) { return _balances[asset]; }
    function getSupplyRate(address) external view override returns (uint256) { return _supplyRate; }
    function getUtilization(address) external view override returns (uint256) { return 5e17; }
    function protocolName() external pure override returns (string memory) { return "MockProtocol"; }
    function simulateInterest(address asset, uint256 amount) external { _balances[asset] += amount; }
}

// ── Integration Test ────────────────────────────────────────────────

/// @title AgentFlowTest
/// @notice End-to-end integration test simulating the full agent lifecycle:
///         deposit → agent rebalance → yield accrual → second rebalance → withdraw
contract AgentFlowTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    AIVault public vault;
    StrategyManager public strategyManager;
    FlowMockUSDC public usdc;
    FlowMockAdapter public aaveAdapter;
    FlowMockAdapter public compoundAdapter;

    address public owner = address(this);
    uint256 public keeperPk = 0xBEEF;
    address public keeper = vm.addr(keeperPk);
    address public feeRecipient = makeAddr("feeRecipient");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        usdc = new FlowMockUSDC();
        aaveAdapter = new FlowMockAdapter(address(usdc));
        compoundAdapter = new FlowMockAdapter(address(usdc));

        aaveAdapter.setSupplyRate(5e16);      // 5% APY
        compoundAdapter.setSupplyRate(8e16);   // 8% APY

        strategyManager = new StrategyManager(owner, 50, 3000, 500, 200_000);
        strategyManager.addAdapter(IProtocolAdapter(address(aaveAdapter)));
        strategyManager.addAdapter(IProtocolAdapter(address(compoundAdapter)));

        AIVault impl = new AIVault();
        bytes memory initData = abi.encodeCall(
            AIVault.initialize,
            (IERC20(address(usdc)), "AI Yield Vault", "aiUSDC", address(strategyManager), keeper, feeRecipient)
        );
        vault = AIVault(address(new ERC1967Proxy(address(impl), initData)));

        // Fund users and adapters
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 50_000e6);
        usdc.mint(address(aaveAdapter), 1_000_000e6);
        usdc.mint(address(compoundAdapter), 1_000_000e6);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @notice Full lifecycle: deposit → rebalance to Aave → yield → rebalance to Compound → withdraw
    function test_fullAgentLifecycle() public {
        // ─── Step 1: Users deposit ──────────────────────────────────
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(50_000e6, alice);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(20_000e6, bob);

        assertEq(vault.totalAssets(), 70_000e6, "Total assets after deposits");
        assertFalse(vault.hasActiveStrategy(), "No strategy yet");

        // ─── Step 2: Agent rebalances to Aave (adapter 0) ──────────
        vm.warp(block.timestamp + 1 hours); // Past cooldown

        vm.prank(address(vault));
        usdc.approve(address(aaveAdapter), type(uint256).max);

        IStrategyManager.RebalanceParams memory params1 = IStrategyManager.RebalanceParams({
            targetAdapterIndex: 0,
            maxLossBps: 50,
            timestamp: block.timestamp,
            nonce: 0
        });
        vault.rebalance(params1, _sign(params1));

        assertTrue(vault.hasActiveStrategy(), "Strategy should be active");
        assertEq(vault.activeAdapterIndex(), 0, "Should be on Aave");

        // ─── Step 3: Simulate yield accrual (Aave earns interest) ──
        aaveAdapter.simulateInterest(address(usdc), 500e6); // 500 USDC yield

        uint256 totalAfterYield = vault.totalAssets();
        assertGt(totalAfterYield, 70_000e6, "Total should increase with yield");
        console.log("Total assets after yield:", totalAfterYield);

        // ─── Step 4: Agent rebalances to Compound (adapter 1) ──────
        vm.warp(block.timestamp + 1 hours); // Past cooldown again

        vm.prank(address(vault));
        usdc.approve(address(compoundAdapter), type(uint256).max);

        IStrategyManager.RebalanceParams memory params2 = IStrategyManager.RebalanceParams({
            targetAdapterIndex: 1,
            maxLossBps: 50,
            timestamp: block.timestamp,
            nonce: 1
        });
        vault.rebalance(params2, _sign(params2));

        assertEq(vault.activeAdapterIndex(), 1, "Should now be on Compound");

        // Assets should be preserved (minus buffer)
        uint256 totalAfterSwitch = vault.totalAssets();
        assertApproxEqRel(totalAfterSwitch, totalAfterYield, 0.01e18, "Assets preserved after switch");

        // ─── Step 5: Users withdraw ─────────────────────────────────
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        uint256 aliceReceived = usdc.balanceOf(alice) - aliceBalBefore;

        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);
        uint256 bobReceived = usdc.balanceOf(bob) - bobBalBefore;

        console.log("Alice deposited 50k, received:", aliceReceived);
        console.log("Bob deposited 20k, received:", bobReceived);

        // Both should receive at least their deposit (yield was earned)
        assertGe(aliceReceived, 50_000e6 - 1, "Alice should profit");
        assertGe(bobReceived, 20_000e6 - 1, "Bob should profit");

        // Vault should be empty
        assertEq(vault.totalSupply(), 0, "No shares remaining");
    }

    /// @notice Multiple deposits and withdrawals interleaved with rebalances
    function test_interleavedOperations() public {
        // Alice deposits
        vm.prank(alice);
        vault.deposit(30_000e6, alice);

        // Rebalance to Aave
        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(vault));
        usdc.approve(address(aaveAdapter), type(uint256).max);

        IStrategyManager.RebalanceParams memory p = IStrategyManager.RebalanceParams({
            targetAdapterIndex: 0, maxLossBps: 50, timestamp: block.timestamp, nonce: 0
        });
        vault.rebalance(p, _sign(p));

        // Bob deposits AFTER rebalance (his funds should still be tracked)
        vm.prank(bob);
        vault.deposit(10_000e6, bob);

        assertEq(vault.totalAssets(), 40_000e6, "Both deposits tracked");

        // Alice partial withdraw
        vm.prank(alice);
        vault.withdraw(10_000e6, alice, alice);

        assertApproxEqAbs(vault.totalAssets(), 30_000e6, 1, "30k remaining after partial withdraw");

        // Bob full withdraw
        vm.prank(bob);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);

        assertApproxEqAbs(vault.totalAssets(), 20_000e6, 1, "20k remaining (Alice's remainder)");
    }

    /// @notice Nonce replay protection — same nonce can't be used twice
    function test_nonceReplayProtection() public {
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(vault));
        usdc.approve(address(aaveAdapter), type(uint256).max);

        // First rebalance with nonce 0
        IStrategyManager.RebalanceParams memory p0 = IStrategyManager.RebalanceParams({
            targetAdapterIndex: 0, maxLossBps: 50, timestamp: block.timestamp, nonce: 0
        });
        vault.rebalance(p0, _sign(p0));

        // Try to replay nonce 0 after cooldown
        vm.warp(block.timestamp + 1 hours);
        IStrategyManager.RebalanceParams memory p0replay = IStrategyManager.RebalanceParams({
            targetAdapterIndex: 1, maxLossBps: 50, timestamp: block.timestamp, nonce: 0
        });
        bytes memory sig = _sign(p0replay);
        vm.expectRevert("StrategyManager: invalid nonce");
        vault.rebalance(p0replay, sig);
    }

    /// @notice Emergency withdrawal pulls all funds back to idle
    function test_emergencyDuringActiveStrategy() public {
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(vault));
        usdc.approve(address(aaveAdapter), type(uint256).max);

        IStrategyManager.RebalanceParams memory p = IStrategyManager.RebalanceParams({
            targetAdapterIndex: 0, maxLossBps: 50, timestamp: block.timestamp, nonce: 0
        });
        vault.rebalance(p, _sign(p));

        assertTrue(vault.hasActiveStrategy(), "Strategy active");

        // Emergency
        vault.emergencyWithdrawAll();

        assertFalse(vault.hasActiveStrategy(), "Strategy deactivated");
        assertEq(usdc.balanceOf(address(vault)), 50_000e6, "All funds idle");

        // Alice can still withdraw
        vm.prank(alice);
        vault.withdraw(50_000e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 100_000e6, "Alice got everything back");
    }

    // ── Helper ──────────────────────────────────────────────────────

    function _sign(IStrategyManager.RebalanceParams memory params)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            vault.REBALANCE_TYPEHASH(),
            params.targetAdapterIndex,
            params.maxLossBps,
            params.timestamp,
            params.nonce
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(vault.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keeperPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
