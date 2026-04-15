// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AIVault} from "../src/AIVault.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {CompoundV3Adapter} from "../src/adapters/CompoundV3Adapter.sol";
import {Constants} from "../src/libraries/Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployContinue
/// @notice Continues a partial deployment — deploys AIVault impl + proxy + ownership transfers.
///         Uses already-deployed adapters and StrategyManager from the initial run.
contract DeployContinue is Script {
    // Already deployed in the first run (nonce 0-4)
    address constant AAVE_ADAPTER    = 0x8545D79f6FaB51EDc93Cf024fBD1FfAc98504ba1;
    address constant COMPOUND_ADAPTER = 0xEB0D41F07691765314B9A45645Ee995d879c7ac7;
    address constant STRATEGY_MANAGER = 0x353469534dA4FB64d52Ae5059CEFd098557eBFa9;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);
        address keeperAddr = vm.envAddress("KEEPER_ADDRESS");
        address feeRecip   = vm.envAddress("FEE_RECIPIENT");

        console.log("=== DeployContinue ===");
        console.log("Deployer:", deployer);
        console.log("Using StrategyManager:", STRATEGY_MANAGER);

        vm.startBroadcast(deployerPk);

        // 1. Deploy AIVault implementation
        AIVault vaultImpl = new AIVault();
        console.log("AIVault impl:", address(vaultImpl));

        // 2. Deploy UUPS proxy with initialization
        bytes memory initData = abi.encodeCall(
            AIVault.initialize,
            (
                IERC20(Constants.USDC_SEPOLIA),
                "AI Yield Vault",
                "aiUSDC",
                STRATEGY_MANAGER,
                keeperAddr,
                feeRecip
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        console.log("AIVault proxy:", address(proxy));

        // 3. Transfer adapter ownership to vault
        AaveV3Adapter(AAVE_ADAPTER).transferOwnership(address(proxy));
        CompoundV3Adapter(COMPOUND_ADAPTER).transferOwnership(address(proxy));
        console.log("Adapter ownership transferred to vault");

        // Verify
        AIVault vault = AIVault(address(proxy));
        console.log("--- Summary ---");
        console.log("Vault name:", vault.name());
        console.log("Vault symbol:", vault.symbol());
        console.log("Keeper:", vault.keeper());

        vm.stopBroadcast();
    }
}
