# Stealth-Pay v1.0: 企业级隐私资金分发与无感提取系统

## 一、 项目背景 (Project Background)

在 Web3 企业和 DAO 的日常运营中，"链上发薪"是一个高频且痛点极多的场景。传统的链上转账存在严重的隐私泄露问题：如果企业通过多签钱包直接向员工的常用地址打款，任何人都可以通过区块链浏览器轻易推导出公司的**"完整员工名单"**以及**"内部薪资结构"**。

为了解决这个问题，我们需要构建一套专用的**企业级隐私发薪系统 (Shadow-Payroll)**。我们不追求极其昂贵且复杂的全域零知识证明（ZK）方案，而是立足于 2026 年以太坊主网现状，通过"逻辑隔离"与"元交易"的结合，在**隐私保护、主网 Gas 成本、用户体验**之间取得完美的商业平衡。

## 二、 核心设计目标 (Core Design Objectives)

系统必须严格满足以下四个维度的指标：

1. **隐私性 (Linkability Breaking)：** 必须在链上切断"资金发送方（企业 Vault）"与"最终接收方（员工常用地址）"之间的显性关联。员工之间不能通过链上数据互相查阅薪资。
2. **冷启动无感提取 (Zero-Gas Execution)：** 接收方无需预先持有任何 ETH 作为 Gas 费。系统必须支持"白板地址"独立完成提款。
3. **全资产兼容 (Universal Asset Compatibility)：** 必须原生支持主流 ERC-20 Token（如 USDT/USDC）和 Native ETH，且架构需具备向 ERC-721 扩展的潜力。
4. **企业自托管 (Self-Custody) 与极简依赖：** 资金由企业的智能合约绝对控制，不依赖外部的混币池。同时，**不能强制要求员工使用特定的、尚未普及的隐私钱包**，所有密码学操作需封装在轻量级的 Web 前端中完成。

## 三、 核心架构决策 (Architecture Decisions)

**为什么不直接用"EIP-5564 + ERC-4337 Paymaster"？**
在以太坊主网上，为每一个员工部署独立的 ERC-4337 智能合约账户成本极高，且严重依赖第三方基础设施（Bundler/Paymaster）。

**我们的破局方案：隐身地址映射 + 智能合约记账 + EIP-712 中继提取**

1. **隐身地址生成：** 参考 EIP-5564 的椭圆曲线 Diffie-Hellman (ECDH) 思想，在链下为员工生成一次性的影子 EOA 地址 ()。
2. **Vault 集中记账：** 企业的钱不直接打进这个影子 EOA（因为 EOA 没 ETH 无法发起交易），而是打入我们定制的 `PayrollVault` 智能合约中，在合约内部将资金映射到该影子地址名下。
3. **签名即提款：** 员工用影子私钥签署 EIP-712 指令，由企业的中继器（Relayer）代付 ETH 提交给 `PayrollVault`，合约验证签名后将资金直接推送到员工指定的最终交易所或冷钱包地址。

## 四、 系统流转全流程 (System Workflow)

### 阶段 1：初始化与脱敏 (Setup)

* **员工端：** 员工在公司的 Web 门户连接常用钱包，对固定消息（如 `Shadow-Payroll-2026`）签名，前端以此为种子派生出**隐身元公钥 (Stealth Meta-PublicKey)** 。
* **HR 登记：** 员工将  交给 HR。注意：企业并未收集员工的真实收款地址。

### 阶段 2：隐私发薪 (Batch Allocation)

* **链下计算：** 每月发薪时，HR 的系统利用当月的随机盐（Ephemeral Key）与员工的  结合，计算出当月的**影子地址 (Stealth Address)** 。
* **链上分配：** 企业多签钱包调用 `PayrollVault` 合约的 `batchAllocate` 函数，将总资金打入合约，并附带  列表和对应金额。资金在链上的状态变为"锁定在 Vault 中，归属于各个白板 "。

### 阶段 3：无感提取 (Zero-Gas Claim)

* **前端操作：** 员工登录 Web 门户，系统自动推导出  的私钥 。员工输入最终的收款地址（如币安充值地址），并同意支付少量 USDT 给 Relayer 作为 Gas 补偿。
* **签名构建：** 前端使用  构建并签署一条 **EIP-712 提款指令**。
* **中继上链：** 员工将签名发送给 Relayer。Relayer 垫付主网 ETH，调用 Vault 的 `claim` 函数。Vault 验证签名、扣除手续费发给 Relayer，并将剩余薪资发给员工指定的最终地址。

---

## 五、 智能合约设计规范 (Solidity Spec)

请使用 **Foundry** 框架进行开发，Solidity 版本建议 `>=0.8.20`。
核心合约 `PayrollVault.sol` 需要实现以下关键接口和逻辑：

```solidity
// 核心状态变量
// token => (stealthAddress => balance)
mapping(address => mapping(address => uint256)) public balances;
// stealthAddress => nonce (防重放)
mapping(address => uint256) public nonces;

// EIP-712 提款结构体
struct ClaimRequest {
    address stealthAddress; // 拥有资金的影子地址
    address token;          // 代币地址 (address(0) 为原生 ETH)
    uint256 amount;         // 提取总额
    address recipient;      // 实际接收资金的最终地址
    uint256 feeAmount;      // 支付给 msg.sender (Relayer) 的代币数量
    uint256 nonce;          // 必须匹配 nonces[stealthAddress]
    uint256 deadline;       // 签名过期时间戳
}

// 接口 1: 批量发薪 (需具备权限控制)
function batchAllocate(
    address[] calldata stealthAddresses,
    address[] calldata tokens,
    uint256[] calldata amounts
) external payable onlyOwner;

// 接口 2: 签名提款 (由 Relayer 调用)
function claim(
    ClaimRequest calldata req,
    bytes calldata signature
) external nonReentrant;

```

*安全提示：必须实现严谨的 `ecrecover` 逻辑，且 `domainSeparator` 需绑定 `block.chainid` 和 `address(this)`。*

---

## 六、 强制测试策略 (Testing Strategy via Foundry)

必须提供高覆盖率的测试用例，涵盖以下维度：

### 1. 核心链路测试 (Happy Path)

* `test_BatchAllocate()`: 验证分配逻辑正确，非权限用户调用被拦截。
* `test_ClaimWithValidSignature()`: 验证完整的 EIP-712 提款流程，断言 `recipient` 和 `relayer` 的余额增加完全准确。
* `test_NativeETH_Flow()`: 针对原生 ETH 分配与提取的专项测试。

### 2. 密码学与边界安全测试 (Security Limits)

* `test_RevertIf_ReplayAttack()`: 模拟重放攻击，确保第二次提交相同签名因 Nonce 递增而失败。
* `test_RevertIf_ExpiredDeadline()`: 测试超时签名被拒绝。
* `test_RevertIf_SignatureMalleability()`: 验证防范签名延展性攻击（建议直接使用 OpenZeppelin ECDSA 库）。
* `test_RevertIf_WrongSigner()`: 篡改 `ClaimRequest` 中的金额或收款人，验证签名恢复出的地址与 `stealthAddress` 不匹配并拦截。

### 3. 性能与极限测试 (Fuzz & Gas)

* `testFuzz_AllocationAndClaim()`: 使用随机的大额/极小额输入测试溢出与边界。
* `test_GasCost_BatchAllocate()` & `test_GasCost_Claim()`: 打印 Gas 消耗报告。在以太坊主网背景下，`claim` 的 Gas 必须优化至极限。
