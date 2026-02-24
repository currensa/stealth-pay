# StealthPay — 企业级隐私发薪系统

> **版本：** v2.0 (Merkle Tree 架构) | **框架：** Foundry + TypeScript SDK | **网络：** EVM 兼容链

在 Web3 企业和 DAO 的日常运营中，"链上发薪"存在严重的隐私泄露问题：通过区块链浏览器可以轻易推导出公司的**完整员工名单**和**内部薪资结构**。StealthPay 通过 ECDH 隐身地址 + Merkle Tree + EIP-712 中继提取的组合，在隐私保护、Gas 成本与用户体验之间取得平衡。

---

## 一、设计目标

| 目标 | 方案 |
|------|------|
| **隐私性** | 链上只可见 32 字节 Merkle Root，员工地址与金额完全链下保管 |
| **冷启动无感提取** | 员工签名，Relayer 垫付 Gas，影子地址无需持有 ETH |
| **全资产兼容** | 原生支持 ERC-20（USDT/USDC）与 Native ETH |
| **企业自托管** | 资金由企业智能合约绝对控制，无外部混币依赖 |

---

## 二、系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                     链下（Off-Chain）                        │
│                                                             │
│  员工：meta_priv ──→ meta_pub（提交 HR）                    │
│                                                             │
│  HR  ：ephemeral_priv + meta_pub                            │
│        ──→ stealth_address（本月影子地址）                   │
│        ──→ Merkle Tree（所有员工叶子 → root）               │
│                                                             │
│  员工：meta_priv + ephemeral_pub                            │
│        ──→ stealth_priv（可签名提款）                       │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                   StealthPayVault（链上）                    │
│                                                             │
│  depositForPayroll(merkleRoot, token, total)                │
│    activeRoots[root] = true                                 │
│                                                             │
│  claim(req, sig, merkleProof[], root)                       │
│    ① deadline ② isClaimed ③ fee ≤ amount                   │
│    ④ activeRoots[root] ⑤ MerkleProof.verify               │
│    ⑥ ECDSA.recover == stealthAddress                       │
│    ⑦ isClaimed[stealth] = true                             │
│    ⑧ transfer(recipient, net) + transfer(relayer, fee)     │
└──────────────────────────┬──────────────────────────────────┘
                           │
              recipient ←──┘← net
              relayer   ←───── fee
```

### 密码学核心（ECDH 隐身地址）

```
sharedSecret  = ECDH(ephemeralPriv, metaPub)     // = metaPriv · ephemeralPub
h             = keccak256(compress(sharedSecret)) mod n
stealthPub    = metaPub + h·G                    // 椭圆曲线点加法
stealthPriv   = (metaPriv + h) mod n             // 标量加法
stealthAddress = keccak256(stealthPub[1:])[12:]  // 以太坊地址
```

---

## 三、项目结构

```
stealth-pay/
├── src/
│   └── StealthPayVault.sol     # 核心合约（Merkle + EIP-712）
├── test/
│   └── StealthPayVault.t.sol   # Foundry 测试套件（11 个测试）
├── sdk/
│   ├── src/
│   │   └── StealthKey.ts       # ECDH 影子密钥推导 SDK
│   └── test/
│       ├── StealthKey.test.ts  # SDK 单元测试
│       └── e2e.integration.test.ts  # 全链路 E2E 测试（Anvil）
├── lib/
│   ├── forge-std/
│   └── openzeppelin-contracts/
├── foundry.toml
└── DEVLOG.md                   # 完整开发日志（10 个阶段）
```

---

## 四、智能合约接口

### 状态变量

```solidity
mapping(bytes32 => bool) public activeRoots;   // 合法发薪 Root 集合
mapping(address => bool) public isClaimed;     // 影子地址是否已提款
bytes32 public constant CLAIM_TYPEHASH;        // EIP-712 类型哈希
bytes32 public immutable DOMAIN_SEPARATOR;     // 链 ID + 合约地址绑定
```

### 发薪（仅 Owner）

```solidity
function depositForPayroll(
    bytes32 merkleRoot,   // 本期所有叶子构成的树根
    address token,        // 代币地址（address(0) = ETH）
    uint256 totalAmount   // 本期总发薪额
) external payable onlyOwner;
```

### 提款（Relayer 代发）

```solidity
struct ClaimRequest {
    address stealthAddress; // 资金所属影子地址
    address token;          // 代币地址
    uint256 amount;         // 提取总额（必须与 Merkle 叶子完全一致）
    address recipient;      // 最终收款地址（如交易所充值地址）
    uint256 feeAmount;      // Relayer 手续费
    uint256 deadline;       // 签名过期时间戳
}

function claim(
    ClaimRequest calldata req,
    bytes calldata signature,      // 影子私钥的 EIP-712 签名
    bytes32[] calldata merkleProof, // 从叶子到 root 的路径
    bytes32 root                   // 发薪 Merkle Root
) external nonReentrant;
```

### Merkle 叶子格式

```solidity
bytes32 leaf = keccak256(abi.encodePacked(stealthAddress, token, amount));
```

### 自定义错误

| 错误 | 触发条件 |
|------|---------|
| `SignatureExpired()` | `block.timestamp > req.deadline` |
| `AlreadyClaimed()` | `isClaimed[stealthAddress] == true` |
| `FeeExceedsAmount()` | `feeAmount > amount` |
| `InvalidRoot()` | `root` 不在 `activeRoots` |
| `InvalidMerkleProof()` | Merkle 路径验证失败 |
| `InvalidSignature()` | EIP-712 恢复地址不匹配 |
| `EthAmountMismatch()` | ETH 存款金额与参数不符 |
| `EthTransferFailed()` | ETH 转账调用失败 |

---

## 五、TypeScript SDK

```bash
cd sdk && npm install
npm test          # 运行所有测试（单元 + E2E）
```

### 核心 API

```typescript
import {
  getMetaPublicKey,           // 员工：私钥 → 未压缩公钥
  computeStealthAddress,      // HR：ECDH → 影子地址 + 公钥
  recoverStealthPrivateKey,   // 员工：ECDH → 影子私钥
} from './src/StealthKey.js';

// 员工端
const metaPub = getMetaPublicKey(metaPrivKey);

// HR 端
const { stealthAddress, stealthPublicKey } = computeStealthAddress(
  metaPub,
  ephemeralPrivKey,
);

// 员工端（提款时）
const stealthPriv = recoverStealthPrivateKey(metaPrivKey, ephemeralPub);
```

### E2E 集成测试

`sdk/test/e2e.integration.test.ts` 使用 Anvil + viem 验证完整链路：

```
HR: computeStealthAddress → approve → batchAllocate
Employee: recoverStealthPrivateKey → signTypedData (EIP-712)
Relayer: claim → broadcast
Assert: recipient +4950 USDT, relayer +50 USDT
```

> **注意：** E2E 测试基于旧版 `batchAllocate` 接口，待迁移至 Merkle 架构。

---

## 六、快速开始

### 合约

```bash
# 依赖
git submodule update --init --recursive

# 编译
forge build

# 全量测试（含 256 轮模糊测试）
forge test -v
```

### SDK

```bash
cd sdk
npm install
npm test
```

### 本地 E2E

```bash
# 需要 Anvil 在后台运行（或由测试自动启动）
cd sdk
npm test test/e2e.integration.test.ts
```

---

## 七、测试覆盖

### Foundry（合约）

| 测试 | 类型 | 验证内容 |
|------|------|---------|
| `test_DepositForPayroll` | 正常流程 | 存款后 `activeRoots[root] = true`，非 Owner 被拒 |
| `test_ClaimWithValidSignature` | 正常流程 | 2-叶 Merkle + EIP-712 完整提款 + AlreadyClaimed 防双花 |
| `test_RevertIf_ExpiredDeadline` | 安全边界 | 过期签名被 `SignatureExpired()` 拦截 |
| `test_RevertIf_TamperedPayload` | 安全边界 | 篡改 amount → `InvalidMerkleProof`；篡改 recipient → `InvalidSignature` |
| `test_RevertIf_WrongSigner` | 安全边界 | 篡改 feeAmount → EIP-712 签名不匹配 |
| `test_RevertIf_InvalidRoot` | 安全边界 | 未注册 root → `InvalidRoot()` |
| `test_RevertIf_InvalidMerkleProof` | 安全边界 | 错误 proof → `InvalidMerkleProof()` |
| `testFuzz_AllocationAndClaim` | 模糊测试 | 256 轮随机金额，单叶退化树（root=leaf） |
| `test_GasCost_Claim` | Gas 基准 | Merkle claim gas: ~192,036 |

### SDK（TypeScript）

| 测试 | 验证内容 |
|------|---------|
| ECDH 主链路 | 影子私钥 ↔ 影子地址完全吻合 |
| 一次性特性 | 不同 ephemeral key → 不同影子地址 |
| 格式断言 | `getMetaPublicKey` 输出 `0x04[128 hex]` |
| E2E 全链路 | Anvil 上全流程验证（185ms） |

---

## 八、安全设计

**claim 检查顺序（防信息泄露）：**
```
deadline → isClaimed → feeAmount ≤ amount → activeRoots[root]
→ MerkleProof.verify → ECDSA.recover → isClaimed=true → 转账
```

**关键安全属性：**
- Merkle Proof 和签名验证均在状态变更前完成（CEI 模式）
- `isClaimed` 替代 `nonces`：每个影子地址全生命周期只能提款一次
- OZ `ECDSA.recover`：自动防签名延展性（high-s 值）
- `SafeERC20`：防不规范 token 静默失败
- `nonReentrant`：防重入攻击
- `block.chainid` + `address(this)` 绑定：防跨链/跨合约重放

---

## 九、待完善

| 项目 | 说明 |
|------|------|
| `test_NativeETH_Flow` | ETH 完整提款流程专项测试 |
| `test_RevertIf_SignatureMalleability` | 构造 high-s 签名，验证 OZ ECDSA 拦截 |
| E2E 测试迁移 | `sdk/test/e2e.integration.test.ts` 升级到 Merkle 接口 |
| 部署脚本 | `script/Deploy.s.sol` |
| NatSpec 完善 | 所有 public 接口补全文档注释 |

---

> 完整开发过程（10 个 TDD 阶段）详见 [DEVLOG.md](./DEVLOG.md)。
