// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/StealthPayVault.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        StealthPayVault vault = new StealthPayVault(vm.addr(deployerPrivateKey));
        vm.stopBroadcast();

        console2.log("StealthPayVault deployed at:", address(vault));
    }
}
