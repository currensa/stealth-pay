// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title  ERC20Mock
/// @notice 测试网专用可铸造 ERC-20，模拟 USDT（18 位精度）
contract ERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /// @notice 无限印钞，仅供测试网使用
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
