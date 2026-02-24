// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title StealthPayVault
/// @notice 企业级隐私资金分发与无感提取
/// @dev EIP-712 签名验证，支持 ERC-20 与原生 ETH
contract StealthPayVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // 自定义错误（节省 string 存储与 ABI 编码开销）
    // -------------------------------------------------------------------------

    error ArrayLengthMismatch();
    error EthAmountMismatch();
    error SignatureExpired();
    error InvalidNonce();
    error FeeExceedsAmount();
    error InvalidSignature();
    error InsufficientBalance();
    error EthTransferFailed();

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

    bytes32 public constant CLAIM_TYPEHASH = keccak256(
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
                keccak256("StealthPay"),
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
    function batchAllocate(
        address[] calldata stealthAddresses,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external payable onlyOwner {
        if (stealthAddresses.length != tokens.length || tokens.length != amounts.length) {
            revert ArrayLengthMismatch();
        }

        uint256 totalEth;
        uint256 len = stealthAddresses.length;

        for (uint256 i = 0; i < len;) {
            address token   = tokens[i];
            uint256 amount  = amounts[i];
            address stealth = stealthAddresses[i];

            if (token == address(0)) {
                totalEth += amount;
            } else {
                IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            }

            balances[token][stealth] += amount;
            emit Allocated(token, stealth, amount);

            unchecked { ++i; }
        }

        if (msg.value != totalEth) revert EthAmountMismatch();
    }

    /// @notice 签名提款：由 Relayer 代发，Vault 验证 EIP-712 签名后向 recipient 转账
    function claim(
        ClaimRequest calldata req,
        bytes calldata signature
    ) external nonReentrant {
        // 缓存高频 storage key，减少重复 SLOAD
        address stealth = req.stealthAddress;
        address token   = req.token;

        // 1. 时效检查
        if (block.timestamp > req.deadline) revert SignatureExpired();

        // 2. 防重放：nonce 必须匹配
        if (req.nonce != nonces[stealth]) revert InvalidNonce();

        // 3. 手续费合法性（廉价检查，置于签名验证前）
        if (req.amount < req.feeAmount) revert FeeExceedsAmount();

        // 4. EIP-712 验签（先于余额检查，防余额信息泄露）
        bytes32 structHash = keccak256(abi.encode(
            CLAIM_TYPEHASH,
            stealth,
            token,
            req.amount,
            req.recipient,
            req.feeAmount,
            req.nonce,
            req.deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        if (ECDSA.recover(digest, signature) != stealth) revert InvalidSignature();

        // 5. 余额检查（签名验证后）
        uint256 bal = balances[token][stealth];
        if (bal < req.amount) revert InsufficientBalance();

        // 6. 状态更新（unchecked 安全：nonce 不会溢出，balance 已校验足够）
        unchecked {
            nonces[stealth]        = req.nonce + 1;
            balances[token][stealth] = bal - req.amount;
        }

        uint256 fee = req.feeAmount;
        uint256 net;
        unchecked { net = req.amount - fee; }

        // 7. 转账
        if (token == address(0)) {
            if (fee > 0) {
                (bool ok,) = msg.sender.call{value: fee}("");
                if (!ok) revert EthTransferFailed();
            }
            (bool ok2,) = req.recipient.call{value: net}("");
            if (!ok2) revert EthTransferFailed();
        } else {
            if (fee > 0) IERC20(token).safeTransfer(msg.sender, fee);
            IERC20(token).safeTransfer(req.recipient, net);
        }

        emit Claimed(token, stealth, req.recipient, net);
    }
}
