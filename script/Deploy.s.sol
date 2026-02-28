// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/StealthPayVault.sol";
import "../src/mocks/ERC20Mock.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // 可选：HR 地址（填了就直接 mint，省去手动转账）
        address hrAddress = vm.envOr("HR_ADDRESS", address(0));

        // 可选：Relayer 地址（填了就转 0.05 ETH 给 Relayer 做 Gas 储备）
        address relayerAddress = vm.envOr("RELAYER_ADDRESS", address(0));

        vm.startBroadcast(deployerPrivateKey);

        // 1. 部署 Mock USDT（18 位精度）
        ERC20Mock usdt = new ERC20Mock("Tether USD", "USDT");

        // 2. 部署 StealthPayVault（Permissionless，无 Owner）
        StealthPayVault vault = new StealthPayVault();

        // 3. 给 Deployer 铸造 1,000,000 USDT
        usdt.mint(deployer, 1_000_000 * 10 ** 18);

        // 4. 若指定了 HR 地址，再铸造 100,000 USDT 给 HR
        if (hrAddress != address(0) && hrAddress != deployer) {
            usdt.mint(hrAddress, 100_000 * 10 ** 18);
        }

        // 5. 若指定了 Relayer 地址，转 0.05 ETH 给 Relayer 做 Gas 储备
        if (relayerAddress != address(0) && relayerAddress != deployer) {
            (bool ok,) = relayerAddress.call{value: 0.05 ether}("");
            require(ok, "ETH transfer to relayer failed");
        }

        vm.stopBroadcast();

        console2.log("=== Deployment Complete ===");
        console2.log("ERC20Mock (USDT) :", address(usdt));
        console2.log("StealthPayVault  :", address(vault));
        console2.log("Deployer         :", deployer);
        console2.log("Minted 1,000,000 USDT to deployer.");
        if (hrAddress != address(0) && hrAddress != deployer) {
            console2.log("Minted 100,000 USDT to HR     :", hrAddress);
        }
        if (relayerAddress != address(0) && relayerAddress != deployer) {
            console2.log("Sent 0.05 ETH to Relayer      :", relayerAddress);
        }
    }
}
