// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AIVault} from "../src/AIVault.sol";
import {StrategyManager} from "../src/StrategyManager.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {CompoundV3Adapter} from "../src/adapters/CompoundV3Adapter.sol";
import {IProtocolAdapter} from "../src/interfaces/IProtocolAdapter.sol";
import {Constants} from "../src/libraries/Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Deploy
/// @notice Deploys the full AIVault system to Sepolia:
///         1. AaveV3Adapter
///         2. CompoundV3Adapter
///         3. StrategyManager (with adapters registered)
///         4. AIVault implementation
///         5. ERC1967Proxy (pointing to AIVault impl)
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy --rpc-url sepolia --broadcast --verify
///
/// Required env vars:
///   PRIVATE_KEY         — deployer private key
///   KEEPER_ADDRESS      — AI agent's public address (signer)
///   FEE_RECIPIENT       — address to receive protocol fees
contract Deploy is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address keeperAddress = vm.envAddress("KEEPER_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        console.log("Deployer:", deployer);
        console.log("Keeper:", keeperAddress);
        console.log("Fee recipient:", feeRecipient);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPk);

        // 1. Deploy Aave V3 Adapter (owned by deployer initially, will transfer to vault)
        AaveV3Adapter aaveAdapter = new AaveV3Adapter(
            Constants.AAVE_V3_POOL,
            deployer
        );
        console.log("AaveV3Adapter:", address(aaveAdapter));

        // 2. Deploy Compound V3 Adapter
        CompoundV3Adapter compoundAdapter = new CompoundV3Adapter(
            Constants.COMPOUND_V3_COMET_USDC,
            deployer
        );
        console.log("CompoundV3Adapter:", address(compoundAdapter));

        // 3. Deploy StrategyManager
        StrategyManager strategyManager = new StrategyManager(
            deployer,
            Constants.DEFAULT_MIN_DELTA_BPS,
            Constants.DEFAULT_EMA_ALPHA_BPS,
            Constants.DEFAULT_MAX_RATE_JUMP_BPS,
            Constants.DEFAULT_ESTIMATED_REBALANCE_GAS
        );
        console.log("StrategyManager:", address(strategyManager));

        // Register adapters
        strategyManager.addAdapter(IProtocolAdapter(address(aaveAdapter)));
        strategyManager.addAdapter(IProtocolAdapter(address(compoundAdapter)));
        console.log("Adapters registered: Aave (0), Compound (1)");

        // 4. Deploy AIVault implementation
        AIVault vaultImpl = new AIVault();
        console.log("AIVault impl:", address(vaultImpl));

        // 5. Deploy UUPS proxy with initialization
        bytes memory initData = abi.encodeCall(
            AIVault.initialize,
            (
                IERC20(Constants.USDC_SEPOLIA),
                "AI Yield Vault",
                "aiUSDC",
                address(strategyManager),
                keeperAddress,
                feeRecipient
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        AIVault vault = AIVault(address(proxy));
        console.log("AIVault proxy:", address(proxy));

        // 6. Transfer adapter ownership to the vault
        aaveAdapter.transferOwnership(address(vault));
        compoundAdapter.transferOwnership(address(vault));
        console.log("Adapter ownership transferred to vault");

        // Verify
        console.log("--- Deployment Summary ---");
        console.log("Vault asset:", vault.asset());
        console.log("Vault name:", vault.name());
        console.log("Vault symbol:", vault.symbol());
        console.log("Keeper:", vault.keeper());
        console.log("Adapter count:", strategyManager.adapterCount());

        vm.stopBroadcast();
    }
}
