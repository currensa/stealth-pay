// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title  StealthPayVault
/// @author StealthPay
/// @notice 多租户企业级隐私发薪平台：任意企业（HR）均可向本合约存入薪资并注册 Merkle Root，
///         无需中心化 Owner。每笔发薪与发起方、代币严格绑定，跨租户攻击被合约层拦截。
/// @dev    架构要点：
///         - Permissionless：任何地址均可调用 depositForPayroll 成为发薪方。
///         - 每个 Merkle Root 与（employer, token, totalAmount）三元组绑定（PayrollRecord）。
///         - claim 验证 req.token 与 payrolls[root].token 严格一致，防止跨租户代币攻击。
///         - isClaimed 映射替代 nonce，每个影子地址全生命周期只能提款一次。
///         - 安全检查顺序：deadline → isClaimed → fee ≤ amount → root → token → MerkleProof → ECDSA → 转账。
contract StealthPayVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // 自定义错误
    // -------------------------------------------------------------------------

    /// @notice ETH 发薪时，msg.value 与 totalAmount 参数不匹配
    error EthAmountMismatch();

    /// @notice 提款请求的 deadline 已过（block.timestamp > req.deadline）
    error SignatureExpired();

    /// @notice 该影子地址已完成过一次提款，不允许重复提取
    error AlreadyClaimed();

    /// @notice 手续费超过提款总额（feeAmount > amount）
    error FeeExceedsAmount();

    /// @notice 提供的 Merkle Root 未注册（对应 payrolls[root].employer == address(0)）
    error InvalidRoot();

    /// @notice 请求提款的代币与该 root 存入时的代币不一致（跨租户攻击防护）
    error TokenMismatch();

    /// @notice Merkle Proof 路径验证失败（叶子与 root 不匹配）
    error InvalidMerkleProof();

    /// @notice EIP-712 签名恢复的地址与 req.stealthAddress 不一致
    error InvalidSignature();

    /// @notice 原生 ETH 转账（call）失败
    error EthTransferFailed();

    // -------------------------------------------------------------------------
    // 结构体
    // -------------------------------------------------------------------------

    /// @notice 绑定每个 Merkle Root 的发薪上下文
    /// @dev    payrolls[root].employer == address(0) 表示该 root 尚未注册
    struct PayrollRecord {
        /// @dev 调用 depositForPayroll 的 HR 地址
        address employer;
        /// @dev 本批薪资对应的代币（address(0) = 原生 ETH）
        address token;
        /// @dev 存入的总金额
        uint256 totalAmount;
    }

    /// @notice EIP-712 提款请求结构体
    struct ClaimRequest {
        /// @dev 拥有资金的影子地址（ECDH 推导的一次性 EOA）
        address stealthAddress;
        /// @dev 代币合约地址；address(0) 表示原生 ETH
        address token;
        /// @dev 本次提取的总额（必须等于 Merkle 叶子中的 amount）
        uint256 amount;
        /// @dev 资金最终接收地址（如员工的交易所充值地址）
        address recipient;
        /// @dev 支付给 msg.sender（Relayer）的手续费；不得超过 amount
        uint256 feeAmount;
        /// @dev 签名过期时间戳（Unix 秒）
        uint256 deadline;
    }

    // -------------------------------------------------------------------------
    // 核心状态变量
    // -------------------------------------------------------------------------

    /// @notice 每个 Merkle Root 对应的发薪记录（employer + token + totalAmount）
    /// @dev    employer == address(0) 表示未注册；任何人可注册新 root
    mapping(bytes32 => PayrollRecord) public payrolls;

    /// @notice 记录影子地址是否已完成提款（防止双花）
    mapping(address => bool) public isClaimed;

    // -------------------------------------------------------------------------
    // EIP-712
    // -------------------------------------------------------------------------

    /// @notice ClaimRequest 结构体的 EIP-712 类型哈希
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "ClaimRequest(address stealthAddress,address token,uint256 amount,address recipient,uint256 feeAmount,uint256 deadline)"
    );

    /// @notice EIP-712 域分隔符（不可变，绑定链 ID 与合约地址，防跨链/跨合约重放）
    bytes32 public immutable DOMAIN_SEPARATOR;

    // -------------------------------------------------------------------------
    // 事件
    // -------------------------------------------------------------------------

    /// @notice 企业完成一期发薪存款
    /// @param merkleRoot  本期发薪 Merkle Root
    /// @param employer    发薪方地址
    /// @param token       存入的代币地址（address(0) = ETH）
    /// @param totalAmount 本期总发薪额
    event PayrollDeposited(bytes32 indexed merkleRoot, address indexed employer, address indexed token, uint256 totalAmount);

    /// @notice 影子地址完成一次提款
    /// @param token          代币地址
    /// @param stealthAddress 资金来源的影子地址
    /// @param recipient      实际收款地址
    /// @param net            扣除手续费后到账金额
    event Claimed(address indexed token, address indexed stealthAddress, address indexed recipient, uint256 net);

    // -------------------------------------------------------------------------
    // 构造函数
    // -------------------------------------------------------------------------

    constructor() {
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

    /// @notice 任何 HR 均可存入本期发薪资金并注册 Merkle Root（Permissionless）
    /// @dev    ERC-20 通过 safeTransferFrom 拉入（需提前 approve）；
    ///         原生 ETH 通过 msg.value 传入，需满足 msg.value == totalAmount。
    ///         每次调用以 msg.sender 为 employer 写入 payrolls[merkleRoot]；
    ///         同一 root 重复注册将覆盖原记录（幂等）。
    /// @param merkleRoot  本期所有叶子（stealthAddress, token, amount）构成的 Merkle 树根
    /// @param token       代币地址；address(0) 表示原生 ETH
    /// @param totalAmount 本期所有叶子金额之和
    function depositForPayroll(
        bytes32 merkleRoot,
        address token,
        uint256 totalAmount
    ) external payable {
        if (token == address(0)) {
            if (msg.value != totalAmount) revert EthAmountMismatch();
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);
        }
        payrolls[merkleRoot] = PayrollRecord({
            employer:    msg.sender,
            token:       token,
            totalAmount: totalAmount
        });
        emit PayrollDeposited(merkleRoot, msg.sender, token, totalAmount);
    }

    /// @notice 签名提款：Relayer 代发，Vault 验证 Merkle Proof + EIP-712 签名后完成转账
    /// @dev    检查顺序（安全关键，请勿调整）：
    ///         1. deadline：防止过期签名被延迟提交
    ///         2. isClaimed：防止双花（每地址仅一次）
    ///         3. feeAmount ≤ amount：廉价的合法性检查
    ///         4. payrolls[root].employer != address(0)：确认 root 已注册
    ///         5. req.token == payrolls[root].token：防跨租户代币攻击
    ///         6. MerkleProof.verify：验证 (stealthAddress, token, amount) 在树中
    ///         7. ECDSA.recover：验证签名来自 stealthAddress（EIP-712，防延展性）
    ///         8. 状态更新（CEI 模式）：isClaimed = true，先于转账
    ///         9. 转账：net → recipient，fee → msg.sender（Relayer）
    /// @param req          提款请求（amount 必须与 Merkle 叶子完全一致）
    /// @param signature    影子地址对 req 的 EIP-712 packed(r,s,v) 签名
    /// @param merkleProof  从 req.stealthAddress 叶子到 root 的 Merkle 路径
    /// @param root         本期发薪 Merkle Root（必须在 payrolls 中）
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

        // 3. 手续费合法性（廉价检查，置于昂贵密码学操作之前）
        if (req.amount < req.feeAmount) revert FeeExceedsAmount();

        // 4. Root 合法性（employer 非零表示已注册）
        if (payrolls[root].employer == address(0)) revert InvalidRoot();

        // 5. 代币一致性：防止用 USDT root 的 proof 提取 USDC（跨租户攻击）
        if (req.token != payrolls[root].token) revert TokenMismatch();

        // 6. Merkle Proof 验证
        //    叶子格式：keccak256(keccak256(abi.encode(stealthAddress, token, amount)))
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(stealth, req.token, req.amount))));
        if (!MerkleProof.verify(merkleProof, root, leaf)) revert InvalidMerkleProof();

        // 7. EIP-712 验签（先于状态更新，防余额/信息泄露）
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

        // 8. 状态更新（CEI 模式：Effects 先于 Interactions）
        isClaimed[stealth] = true;

        // 9. 转账
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
