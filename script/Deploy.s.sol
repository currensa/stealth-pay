// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/StealthPayVault.sol";
import "../src/mocks/ERC20Mock.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. 部署 Mock USDT
        ERC20Mock usdt = new ERC20Mock("Tether USD", "USDT");

        // 2. 部署 StealthPayVault（Permissionless，无 Owner）
        StealthPayVault vault = new StealthPayVault();

        // 3. 给 deployer 铸造 1,000,000 枚 Mock USDT（18 位精度）
        usdt.mint(deployer, 1_000_000 * 10 ** 18);

        vm.stopBroadcast();

        console2.log("=== Deployment Complete ===");
        console2.log("ERC20Mock (USDT) :", address(usdt));
        console2.log("StealthPayVault  :", address(vault));
        console2.log("Deployer (Owner) :", deployer);
        console2.log("Minted 1,000,000 USDT to deployer.");
    }
}
