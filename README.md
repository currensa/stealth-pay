# StealthPay — 企业级隐私发薪系统

> **版本：** v3.0 (多租户 SaaS 架构) | **框架：** Foundry + TypeScript SDK | **网络：** EVM 兼容链（已验证 Sepolia）

在 Web3 企业和 DAO 的日常运营中，"链上发薪"存在严重的隐私泄露问题：通过区块链浏览器可以轻易推导出公司的**完整员工名单**和**内部薪资结构**。StealthPay 通过 ECDH 隐身地址 + Merkle Tree + EIP-712 中继提取的组合，在隐私保护、Gas 成本与用户体验之间取得平衡。

---

## 一、设计目标

| 目标 | 方案 |
|------|------|
| **隐私性** | 链上只可见 32 字节 Merkle Root，员工地址与金额完全链下保管 |
| **冷启动无感提取** | 员工签名，Relayer 垫付 Gas，影子地址无需持有 ETH |
| **全资产兼容** | 原生支持 ERC-20（USDT/USDC）与 Native ETH |
| **企业自托管** | 资金由企业智能合约绝对控制，无外部混币依赖 |
| **多租户隔离** | 单一合约服务多个企业，每笔发薪与发起方、代币严格绑定，跨企业攻击被合约层拦截 |

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
│  depositForPayroll(merkleRoot, token, total)  [Permissionless] │
│    payrolls[root] = PayrollRecord(msg.sender, token, total) │
│                                                             │
│  claim(req, sig, merkleProof[], root)                       │
│    ① deadline ② isClaimed ③ fee ≤ amount                   │
│    ④ payrolls[root].employer != 0                          │
│    ⑤ req.token == payrolls[root].token  ← 跨租户防护       │
│    ⑥ MerkleProof.verify                                    │
│    ⑦ ECDSA.recover == stealthAddress                       │
│    ⑧ isClaimed[stealth] = true                             │
│    ⑨ transfer(recipient, net) + transfer(relayer, fee)     │
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
│   ├── StealthPayVault.sol          # 核心合约（Merkle + EIP-712）
│   └── mocks/
│       └── ERC20Mock.sol            # 测试网用可铸造 ERC-20
├── test/
│   └── StealthPayVault.t.sol        # Foundry 测试套件（11 个测试）
├── script/
│   └── Deploy.s.sol                 # Foundry 部署脚本（ERC20Mock + Vault）
├── sdk/
│   ├── src/
│   │   └── StealthKey.ts            # ECDH 影子密钥推导 SDK
│   ├── scripts/
│   │   └── testnet-e2e.ts           # Sepolia 全链路交互脚本
│   └── test/
│       ├── StealthKey.test.ts       # SDK 单元测试
│       └── e2e.integration.test.ts  # 全链路 E2E 测试（Anvil）
├── example/                         # Next.js 可视化演示门户（HR + 员工 UI）
│   ├── src/app/
│   │   ├── hr/page.tsx              # HR 控制台（approve + depositForPayroll）
│   │   ├── employee/page.tsx        # 员工提取端（scan + signTypedData + relayer）
│   │   └── api/
│   │       ├── db/route.ts          # Mock DB API（GET/POST/PATCH）
│   │       └── relayer/route.ts     # Relayer API（POST → Sepolia claim）
│   └── src/lib/
│       ├── stealthKey.ts            # ECDH SDK（从父 SDK 复制，浏览器兼容）
│       ├── merkle.ts                # 单叶 Merkle root（无 OZ 依赖）
│       ├── vaultAbi.ts              # 合约 ABI 常量
│       ├── constants.ts             # 合约地址、链配置
│       └── db.ts                    # 共享内存 + db.json 持久化
├── lib/
│   ├── forge-std/
│   └── openzeppelin-contracts/
├── foundry.toml
└── DEVLOG.md                        # 完整开发日志（16 个阶段）
```

---

## 四、智能合约接口

### 状态变量与结构体

```solidity
// 每个 Merkle Root 绑定的发薪上下文（employer==address(0) 表示未注册）
struct PayrollRecord {
    address employer;    // 发薪方地址（调用 depositForPayroll 的 HR）
    address token;       // 本批薪资代币（address(0) = ETH）
    uint256 totalAmount; // 存入总额
}

mapping(bytes32 => PayrollRecord) public payrolls; // root → 发薪记录
mapping(address => bool) public isClaimed;         // 影子地址是否已提款
bytes32 public constant CLAIM_TYPEHASH;            // EIP-712 类型哈希
bytes32 public immutable DOMAIN_SEPARATOR;         // 链 ID + 合约地址绑定
```

### 发薪（Permissionless，任何 HR 均可调用）

```solidity
function depositForPayroll(
    bytes32 merkleRoot,   // 本期所有叶子构成的树根
    address token,        // 代币地址（address(0) = ETH）
    uint256 totalAmount   // 本期总发薪额
) external payable;
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
// 双重哈希，与 @openzeppelin/merkle-tree StandardMerkleTree 兼容
bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(stealthAddress, token, amount))));
```

### 自定义错误

| 错误 | 触发条件 |
|------|---------|
| `SignatureExpired()` | `block.timestamp > req.deadline` |
| `AlreadyClaimed()` | `isClaimed[stealthAddress] == true` |
| `FeeExceedsAmount()` | `feeAmount > amount` |
| `InvalidRoot()` | `payrolls[root].employer == address(0)`（root 未注册） |
| `TokenMismatch()` | `req.token != payrolls[root].token`（跨租户代币攻击） |
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
HR: computeStealthAddress → StandardMerkleTree.of → depositForPayroll
Employee: recoverStealthPrivateKey → signTypedData (EIP-712)
Relayer: claim(req, sig, proof, root) → broadcast
Assert: recipient +4950 USDT, relayer +50 USDT
```

---

## 六、快速开始

> 本节按从零到可运行的顺序讲解。分为两条路径：
> - **路径 A**：本地合约测试 + SDK 单元测试（无需 Sepolia，5 分钟内跑通）
> - **路径 B**：Sepolia 测试网部署 → Demo 门户 / SDK 全链路（需要钱包和 RPC）

---

### 路径 A — 纯本地测试（无需钱包）

**前置工具**
- [Foundry](https://book.getfoundry.sh/getting-started/installation)（`curl -L https://foundry.paradigm.xyz | bash && foundryup`）
- Node.js ≥ 20、Git

```bash
# 1. 拉取子模块依赖
git submodule update --init --recursive

# 2. 编译合约
forge build

# 3. 运行合约测试（含 256 轮模糊测试）
forge test -v

# 4. SDK 单元测试（ECDH 推导，纯链下，无需节点）
cd sdk && npm install && npm test
```

Anvil（Foundry 内置本地节点）会在 E2E 测试中自动启动和关闭：

```bash
# 本地全链路 E2E（Anvil 自动管理）
cd sdk && npm test test/e2e.integration.test.ts
```

---

### 路径 B — Sepolia 测试网（Demo 门户 / SDK 全链路）

#### B-1. 准备账户和 RPC

需要准备 **3 个账户**（可用 MetaMask 新建，导出私钥备用）：

| 角色 | 用途 | 需要 Sepolia ETH |
|------|------|-----------------|
| Deployer | 部署合约、铸造测试 USDT | ✅ 约 0.05 ETH |
| HR | 调用 `approve` + `depositForPayroll` | ✅ 约 0.02 ETH |
| Relayer | 替员工代发 `claim` 交易 | ✅ 约 0.02 ETH |

> **获取 Sepolia ETH（水龙头）**
> - https://sepoliafaucet.com（需 Alchemy 账号）
> - https://faucet.quicknode.com/ethereum/sepolia
> - https://faucets.chain.link（需少量主网 ETH）

获取 **Alchemy RPC URL**（免费）：
1. 注册 [alchemy.com](https://alchemy.com) → 创建 App → 选择 Ethereum Sepolia
2. 复制 HTTPS URL，格式为 `https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY`

---

#### B-2. 部署合约（一次性）

在仓库根目录创建 `.env`：

```bash
# .env（根目录，仅部署用，不要提交）
DEPLOYER_PRIVATE_KEY=0x...   # Deployer 私钥
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
ETHERSCAN_KEY=YOUR_KEY        # 可选，用于合约验证
```

```bash
source .env

forge script script/Deploy.s.sol:DeployScript \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast
```

部署完成后控制台输出两个地址，**记录下来**：

```
=== Deployment Complete ===
ERC20Mock (USDT) : 0xAAAA...   ← USDT_ADDRESS
StealthPayVault  : 0xBBBB...   ← VAULT_ADDRESS
Deployer         : 0x...
Minted 1,000,000 USDT to deployer.
```

> 部署成功后 Deployer 账户持有 1,000,000 测试 USDT，转部分到 HR 账户用于发薪。

---

#### B-3A. SDK 全链路脚本

```bash
# sdk/.env
cat > sdk/.env <<EOF
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
HR_PRIVATE_KEY=0x...          # HR 账户私钥（持有测试 USDT）
RELAYER_PRIVATE_KEY=0x...     # Relayer 账户私钥（持有少量 ETH）
VAULT_ADDRESS=0xBBBB...       # 部署步骤输出的 StealthPayVault 地址
USDT_ADDRESS=0xAAAA...        # 部署步骤输出的 ERC20Mock 地址
EOF

cd sdk && npm run run:testnet
```

---

#### B-3B. Demo 门户（Next.js 可视化）

```bash
cd example

npm install

# 从模板创建配置文件
cp .env.local.example .env.local
```

编辑 `example/.env.local`，填入以下参数：

| 变量 | 填入内容 |
|------|---------|
| `NEXT_PUBLIC_VAULT_ADDRESS` | 部署步骤输出的 `StealthPayVault` 地址 |
| `NEXT_PUBLIC_USDT_ADDRESS` | 部署步骤输出的 `ERC20Mock` 地址 |
| `NEXT_PUBLIC_SEPOLIA_RPC_URL` | Alchemy HTTPS URL（浏览器端使用） |
| `RELAYER_PRIVATE_KEY` | Relayer 账户私钥（服务端代发 Gas） |
| `SEPOLIA_RPC_URL` | Alchemy HTTPS URL（服务端 Relayer 使用） |

```bash
npm run dev
# → 打开 http://localhost:3000
```

**Demo 使用流程（需要 MetaMask）：**

```
① 员工端 /employee
   → 连接 MetaMask（员工账户）→ 签名 → 复制蓝色框里的 Meta 公钥

② HR 端 /hr
   → 连接 MetaMask（HR 账户，需持有测试 USDT）
   → 粘贴员工 Meta 公钥 → 输入金额 → 执行发薪
   （自动完成 approve + depositForPayroll）

③ 员工端 /employee
   → 点击「一键提取全部」→ Relayer 代发 Gas，无需员工持有 ETH
   → 点击「+ 添加 USDT 到 MetaMask」即可在钱包中看到余额
```

> **同一浏览器测试两个角色**：在 MetaMask 中切换 Account（HR 用 Account 1，员工用 Account 2），切换后点页面上的「切换」按钮重新连接即可。

---

## 七、测试覆盖

### Foundry（合约）

测试角色：`hrAdmin`（默认发薪方，持有 USDT）/ `relayerNode`（调用 claim）/ `employeeDest`（最终收款）

| 测试 | 类型 | 验证内容 |
|------|------|---------|
| `test_DepositForPayroll` | 正常流程 | 任意地址可存款，`payrolls` 记录正确的 employer 与 token |
| `test_ClaimWithValidSignature` | 正常流程 | 2-叶 Merkle + EIP-712 完整提款 + AlreadyClaimed 防双花 |
| `test_NativeETH_Flow` | 正常流程 | ETH 完整发薪+提款，vault 余额清零，payrolls 记录 ETH |
| `test_MultiTenant_Isolation` | 多租户 | hrA(USDT)+hrB(USDC) 各自存款，员工互不干扰独立提款 |
| `test_RevertIf_CrossTenantTokenAttack` | 安全边界 | 拿 USDT root 的 proof 请求提 USDC → `TokenMismatch()` |
| `test_RevertIf_ExpiredDeadline` | 安全边界 | 过期签名被 `SignatureExpired()` 拦截 |
| `test_RevertIf_TamperedPayload` | 安全边界 | 篡改 amount → `InvalidMerkleProof`；篡改 recipient → `InvalidSignature` |
| `test_RevertIf_WrongSigner` | 安全边界 | 篡改 feeAmount → EIP-712 签名不匹配 |
| `test_RevertIf_InvalidRoot` | 安全边界 | 未注册 root → `InvalidRoot()` |
| `test_RevertIf_InvalidMerkleProof` | 安全边界 | 错误 proof → `InvalidMerkleProof()` |
| `test_RevertIf_SignatureMalleability` | 安全边界 | high-s 签名被 OZ ECDSA 拦截 |
| `testFuzz_AllocationAndClaim` | 模糊测试 | 256 轮随机金额，单叶退化树（root=leaf） |
| `test_GasCost_Claim` | Gas 基准 | Merkle claim gas 基准测量 |

### SDK（TypeScript）

| 测试 | 验证内容 |
|------|---------|
| ECDH 主链路 | 影子私钥 ↔ 影子地址完全吻合 |
| 一次性特性 | 不同 ephemeral key → 不同影子地址 |
| 格式断言 | `getMetaPublicKey` 输出 `0x04[128 hex]` |
| E2E 全链路 | Anvil 上全流程验证，StandardMerkleTree + Merkle v2 接口 |

### Sepolia 全链路脚本

`sdk/scripts/testnet-e2e.ts` 在真实测试网上跑通完整发薪流程（已在 Sepolia 验证）：
- 读取 `sdk/.env` 中的 `HR_PRIVATE_KEY` + `RELAYER_PRIVATE_KEY` + `SEPOLIA_RPC_URL`
- 实例化 `hrClient`（approve + depositForPayroll）与 `relayerClient`（claim）
- `computeStealthAddress` 生成影子地址 → `StandardMerkleTree.of` 构建 Merkle 树
- `depositForPayroll` → EIP-712 本地签名 → `claim`
- 打印 Sepolia Etherscan 链接

---

## 八、安全设计

**claim 检查顺序（防信息泄露）：**
```
deadline → isClaimed → feeAmount ≤ amount
→ payrolls[root].employer != 0
→ req.token == payrolls[root].token  ← 跨租户防护
→ MerkleProof.verify → ECDSA.recover → isClaimed=true → 转账
```

**关键安全属性：**
- `TokenMismatch`：每个 root 绑定特定代币，防止用 A 企业 root 提取 B 企业资产
- Merkle Proof 和签名验证均在状态变更前完成（CEI 模式）
- `isClaimed` 替代 `nonces`：每个影子地址全生命周期只能提款一次
- OZ `ECDSA.recover`：自动防签名延展性（high-s 值）
- `SafeERC20`：防不规范 token 静默失败
- `nonReentrant`：防重入攻击
- `block.chainid` + `address(this)` 绑定：防跨链/跨合约重放

---

## 九、部署

`script/Deploy.s.sol` 一次性部署 **ERC20Mock（测试网用）** 和 **StealthPayVault**，并向 deployer 铸造 1,000,000 USDT。

```bash
# 本地 Anvil
PRIVATE_KEY=0xac0974... forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Sepolia 测试网（附合约验证）
PRIVATE_KEY=$YOUR_KEY forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast --verify \
  --etherscan-api-key $ETHERSCAN_KEY
```

部署后控制台输出：

```
=== Deployment Complete ===
ERC20Mock (USDT) : 0x...
StealthPayVault  : 0x...
Deployer         : 0x...
Minted 1,000,000 USDT to deployer.
```

合约无 Owner，部署后任何 HR 地址均可直接调用 `depositForPayroll` 发薪。

---

> 完整开发过程（16 个阶段，含 Next.js 门户）详见 [DEVLOG.md](./DEVLOG.md)。
