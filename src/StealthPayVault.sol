// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StealthPayVault
/// @notice 企业级隐私资金分发与无感提取 — 合约骨架
/// @dev 采用 EIP-712 签名验证，支持 ERC-20 与原生 ETH
contract StealthPayVault is Ownable, ReentrancyGuard {
    // -------------------------------------------------------------------------
    // 核心状态变量
    // -------------------------------------------------------------------------

    /// @notice token => (stealthAddress => balance)
    mapping(address => mapping(address => uint256)) public balances;

    /// @notice stealthAddress => nonce（防重放）
    mapping(address => uint256) public nonces;

    // -------------------------------------------------------------------------
    // EIP-712
    // -------------------------------------------------------------------------

    bytes32 public constant CLAIM_REQUEST_TYPEHASH = keccak256(
        "ClaimRequest(address stealthAddress,address token,uint256 amount,address recipient,uint256 feeAmount,uint256 nonce,uint256 deadline)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR;

    // -------------------------------------------------------------------------
    // 结构体
    // -------------------------------------------------------------------------

    /// @notice EIP-712 提款请求结构体
    struct ClaimRequest {
        address stealthAddress; // 拥有资金的影子地址
        address token;          // 代币地址（address(0) 为原生 ETH）
        uint256 amount;         // 提取总额
        address recipient;      // 实际接收资金的最终地址
        uint256 feeAmount;      // 支付给 msg.sender（Relayer）的代币数量
        uint256 nonce;          // 必须匹配 nonces[stealthAddress]
        uint256 deadline;       // 签名过期时间戳
    }

    // -------------------------------------------------------------------------
    // 事件
    // -------------------------------------------------------------------------

    event Allocated(address indexed token, address indexed stealthAddress, uint256 amount);
    event Claimed(address indexed token, address indexed stealthAddress, address indexed recipient, uint256 amount);

    // -------------------------------------------------------------------------
    // 构造函数
    // -------------------------------------------------------------------------

    constructor(address initialOwner) Ownable(initialOwner) {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("StealthPayVault"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // -------------------------------------------------------------------------
    // 核心接口
    // -------------------------------------------------------------------------

    /// @notice 批量发薪：将资金分配给指定的影子地址列表（仅限 Owner）
    /// @param stealthAddresses 影子地址数组
    /// @param tokens           对应的代币地址数组（address(0) 为 ETH）
    /// @param amounts          对应的分配金额数组
    function batchAllocate(
        address[] calldata stealthAddresses,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external payable onlyOwner {
        // TODO: 实现批量分配逻辑
    }

    /// @notice 签名提款：由 Relayer 代发，Vault 验证 EIP-712 签名后向 recipient 转账
    /// @param req       ClaimRequest 结构体
    /// @param signature 影子私钥对 req 的 EIP-712 签名
    function claim(
        ClaimRequest calldata req,
        bytes calldata signature
    ) external nonReentrant {
        // TODO: 实现签名验证与资金转移逻辑
    }
}
