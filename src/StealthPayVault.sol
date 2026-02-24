// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title StealthPayVault
/// @notice 企业级隐私资金分发与无感提取（Merkle 架构）
/// @dev EIP-712 签名 + Merkle Proof 双重验证，隐藏员工总数与薪资结构
contract StealthPayVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // 自定义错误
    // -------------------------------------------------------------------------

    error EthAmountMismatch();
    error SignatureExpired();
    error AlreadyClaimed();
    error FeeExceedsAmount();
    error InvalidRoot();
    error InvalidMerkleProof();
    error InvalidSignature();
    error EthTransferFailed();

    // -------------------------------------------------------------------------
    // 核心状态变量
    // -------------------------------------------------------------------------

    /// @notice 企业提交的合法发薪 Merkle Root 集合
    mapping(bytes32 => bool) public activeRoots;

    /// @notice 影子地址是否已提款（防止双花，替代 nonce）
    mapping(address => bool) public isClaimed;

    // -------------------------------------------------------------------------
    // EIP-712
    // -------------------------------------------------------------------------

    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "ClaimRequest(address stealthAddress,address token,uint256 amount,address recipient,uint256 feeAmount,uint256 deadline)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR;

    // -------------------------------------------------------------------------
    // 结构体
    // -------------------------------------------------------------------------

    /// @notice EIP-712 提款请求结构体（无 nonce，由 isClaimed 防重放）
    struct ClaimRequest {
        address stealthAddress; // 拥有资金的影子地址
        address token;          // 代币地址（address(0) 为原生 ETH）
        uint256 amount;         // 提取总额（必须与 Merkle 叶子匹配）
        address recipient;      // 实际接收资金的最终地址
        uint256 feeAmount;      // 支付给 msg.sender（Relayer）的代币数量
        uint256 deadline;       // 签名过期时间戳
    }

    // -------------------------------------------------------------------------
    // 事件
    // -------------------------------------------------------------------------

    event PayrollDeposited(bytes32 indexed merkleRoot, address indexed token, uint256 totalAmount);
    event Claimed(address indexed token, address indexed stealthAddress, address indexed recipient, uint256 net);

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

    /// @notice HR 存入本期发薪资金，提交对应 Merkle Root（仅 Owner）
    /// @param merkleRoot 本期所有叶子（stealthAddr, token, amount）构成的树根
    /// @param token      代币地址（address(0) = 原生 ETH）
    /// @param totalAmount 本期总发薪额
    function depositForPayroll(
        bytes32 merkleRoot,
        address token,
        uint256 totalAmount
    ) external payable onlyOwner {
        if (token == address(0)) {
            if (msg.value != totalAmount) revert EthAmountMismatch();
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);
        }
        activeRoots[merkleRoot] = true;
        emit PayrollDeposited(merkleRoot, token, totalAmount);
    }

    /// @notice 签名提款：Relayer 代发，Vault 验证 Merkle Proof + EIP-712 签名后转账
    /// @param req         提款请求（金额必须与 Merkle 叶子完全一致）
    /// @param signature   影子地址对 req 的 EIP-712 签名
    /// @param merkleProof 从 req.stealthAddress 叶子到 root 的 Merkle 路径
    /// @param root        发薪 Merkle Root（必须在 activeRoots 中）
    function claim(
        ClaimRequest calldata req,
        bytes calldata signature,
        bytes32[] calldata merkleProof,
        bytes32 root
    ) external nonReentrant {
        address stealth = req.stealthAddress;

        // 1. 时效检查
        if (block.timestamp > req.deadline) revert SignatureExpired();

        // 2. 防双花：每个影子地址只能提款一次
        if (isClaimed[stealth]) revert AlreadyClaimed();

        // 3. 手续费合法性（廉价检查）
        if (req.amount < req.feeAmount) revert FeeExceedsAmount();

        // 4. Root 合法性
        if (!activeRoots[root]) revert InvalidRoot();

        // 5. Merkle Proof 验证
        //    叶子 = keccak256(abi.encodePacked(stealthAddress, token, amount))
        bytes32 leaf = keccak256(abi.encodePacked(stealth, req.token, req.amount));
        if (!MerkleProof.verify(merkleProof, root, leaf)) revert InvalidMerkleProof();

        // 6. EIP-712 验签（先于状态更新，防余额信息泄露）
        bytes32 structHash = keccak256(abi.encode(
            CLAIM_TYPEHASH,
            stealth,
            req.token,
            req.amount,
            req.recipient,
            req.feeAmount,
            req.deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        if (ECDSA.recover(digest, signature) != stealth) revert InvalidSignature();

        // 7. 状态更新（CEI 模式）
        isClaimed[stealth] = true;

        // 8. 转账
        address token = req.token;
        uint256 fee   = req.feeAmount;
        uint256 net;
        unchecked { net = req.amount - fee; }

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
