# StealthPayVault 开发日志

> 记录每个开发阶段的决策、结论与 TDD 周期。

---

## 阶段 0：项目初始化与环境搭建

### 目标
克隆私有仓库，确保 `forge build` 通过。

### 执行过程
- 仓库为私有，SSH 密钥未配置，改用 `gh auth token` + HTTPS 克隆成功
- 子模块未初始化，执行 `git submodule update --init --recursive` 拉取：
  - `lib/forge-std`
  - `lib/openzeppelin-contracts`

### 结论
- `forge build` 通过，有 4 条 `note[unaliased-plain-import]` 风格提示（非错误，忽略）
- 项目骨架：`src/StealthPayVault.sol`（两个函数体均为 TODO），`test/StealthPayVault.t.sol`（测试体均为 TODO）

---

## 阶段 1：TDD 实现 `batchAllocate`

### 需求
批量向影子地址分配 USDT / 原生 ETH，仅 Owner 可调用。

### RED（测试先行）
`test_BatchAllocate` 覆盖：
1. 3 个隐身地址（2 USDT + 1 ETH）混合批次，断言 `balances` 映射更新
2. 非 Owner 调用必须 revert

**首次红灯原因：** `batchAllocate` 函数体为空，分配后余额仍为 0。

**第二次红灯原因（调试中发现）：** `owner` 地址默认无 ETH，需 `vm.deal(owner, 1 ether)` 补充。

### GREEN（最小实现）
```solidity
function batchAllocate(...) external payable onlyOwner {
    require(arrays same length, "Length mismatch");
    for each entry:
        if ETH: totalEth += amount
        else:   IERC20.transferFrom(owner → vault, amount)
        balances[token][stealth] += amount
    require(msg.value == totalEth)
}
```
新增 import：`IERC20`。

### 关键决策
- ETH 验证放循环结束后（而非逐笔验），减少 gas
- `transferFrom` 拉款模式，Vault 无需提前持有代币

---

## 阶段 2：TDD 实现 `claim`（EIP-712 签名提款）

### 需求
影子地址私钥持有人签名 → Relayer 代发 → Vault 验证后转账给 recipient，Fee 给 Relayer。

### 测试辅助函数
```solidity
function _signClaimRequest(ClaimRequest memory req, uint256 privateKey)
    → bytes memory signature
```
流程：在测试侧重建 `structHash` + `digest`，用 `vm.sign()` 生成 `(v, r, s)`，返回 `abi.encodePacked(r, s, v)`。

```solidity
function _allocateUSDT(address stealth, uint256 amount)  // 共享前置操作
```

### RED
`test_ClaimWithValidSignature`：employee 余额始终为 0（`claim` 体为空）。

### GREEN（最小实现）
`claim` 检查顺序（**第一版，后续被修正**）：
1. `deadline` 检查
2. `nonce` 匹配
3. 余额 & fee 合法性 ← *后来发现此步应移至签名验证之后*
4. 重建 EIP-712 digest，`ECDSA.recover` 验签
5. 状态更新（CEI 模式）：`nonces++`，`balances -= amount`
6. 转账（ETH 用 `call`，ERC-20 用 `IERC20.transfer`）

新增 import：`ECDSA`。

### 关键决策
- 使用 OZ `ECDSA.recover` 而非裸 `ecrecover`，自动防签名延展性（high-s）
- CEI（Check-Effects-Interactions）：状态先于转账更新，配合 `nonReentrant` 双重防重入

---

## 阶段 3：TDD 安全边界测试（第一批）

### 测试覆盖
| 测试 | 攻击场景 | 合约防御点 |
|------|---------|-----------|
| `test_RevertIf_ReplayAttack` | 相同签名提交两次 | `nonces[stealthAddr]++` 后 nonce 不匹配 |
| `test_RevertIf_ExpiredDeadline` | `vm.warp` 推进时间，deadline 已过 | `block.timestamp <= req.deadline` |
| `test_RevertIf_WrongSigner` | 签名后篡改 `feeAmount` | `ecrecover` 恢复出陌生地址 |

**结论：** 三个测试均直接绿灯，说明上一阶段实现已严谨覆盖这些场景。

---

## 阶段 4：升级 `batchAllocate`（ArrayLengthMismatch + SafeERC20）

### 变更内容
**测试层（RED）：**
- 新增 Scenario 1：数组长度不一致 → 期望 `ArrayLengthMismatch()` 自定义错误（而非字符串）
- 扩展为 4 场景：长度不一致 / 非 Owner / 2 ETH 地址 / 2 USDT 地址

**红灯原因：**
```
Error != expected error: "Length mismatch" != custom error 0xa24a13a6
```

**合约层（GREEN）：**
```solidity
error ArrayLengthMismatch();   // 新增自定义错误
using SafeERC20 for IERC20;   // 新增
IERC20.safeTransferFrom(...)  // 替换裸 transferFrom
```

### 关键决策
- `SafeERC20.safeTransferFrom` vs 裸 `transferFrom`：标准 ERC-20 的 `transfer` 对不规范 token（如旧版 USDT）返回 `void` 而非 `bool`，`safeTransferFrom` 自动检查返回值，避免静默失败

---

## 阶段 5：对齐规范（CLAIM_TYPEHASH 重命名 + domain name）

### 变更内容
| 项目 | 旧值 | 新值 |
|------|------|------|
| 常量名 | `CLAIM_REQUEST_TYPEHASH` | `CLAIM_TYPEHASH` |
| Domain name | `"StealthPayVault"` | `"StealthPay"` |
| 测试私钥 | `keccak256("shadow-payroll-2026")` | `0xA11CE` |

**红灯原因（编译期）：**
```
Member "CLAIM_TYPEHASH" not found in contract StealthPayVault
```

**绿灯：** 重命名常量 + 更新 domain name + 同步 `claim()` 内部引用 + 测试辅助函数中的引用。

### 注意
`DOMAIN_SEPARATOR` 使用 `vault.DOMAIN_SEPARATOR()`（从合约读取），测试与合约始终使用同一值，domain name 变更不影响测试一致性。

---

## 阶段 6：TDD 安全边界测试（第二批）

### 新增测试

#### `test_RevertIf_TamperedPayload`
场景 A：签名后篡改 `amount`（100 → 9999 USDT）
场景 B：签名后篡改 `recipient`（employee → hacker）

**首次红灯（发现真实 Bug）：**
```
期望: "Invalid signature"
实际: "Insufficient balance"
```

**根因：** 合约检查顺序 `balance < signature`，篡改 `amount` 超过余额时，余额检查先于签名验证触发。

**修复（重排检查顺序）：**
```
deadline → nonce → fee sanity → 签名验证 → 余额检查 → 状态更新 → 转账
```
安全意义：先验签可防止余额信息泄露，且确保错误语义正确。

#### `test_RevertIf_InsufficientBalance`
- 分配 500 USDT，尝试提取 1000 USDT（有效签名）
- 签名验证后余额检查拦截 → `"Insufficient balance"`
- 直接绿灯（修复排序后，保护已就位）

---

## 阶段 7：模糊测试 + Gas 优化

### 模糊测试
```solidity
function testFuzz_AllocationAndClaim(uint256 allocateAmount, uint256 feeAmount) public {
    vm.assume(allocateAmount > 0 && allocateAmount < 100_000_000 ether);
    vm.assume(feeAmount <= allocateAmount);
    // 按需铸造 → batchAllocate → claim → 断言余额
}
```
256 轮随机输入全部通过，无溢出或边界异常。

### Gas 基线（优化前）
| 函数 | Gas |
|------|-----|
| `batchAllocate(100 地址)` | 2,962,336 |
| `claim` | 97,386 |

### 优化措施

#### 1. 全面替换为自定义错误
```solidity
error SignatureExpired();
error InvalidNonce();
error FeeExceedsAmount();
error InvalidSignature();
error InsufficientBalance();
error EthAmountMismatch();
error EthTransferFailed();
```
每个 revert 路径省 ~20 gas（避免字符串运行时编码）。

#### 2. Unchecked 块
```solidity
unchecked {
    nonces[stealth]          = req.nonce + 1;    // uint256 不会溢出
    balances[token][stealth] = bal - req.amount; // 已校验 bal >= amount
    net                      = req.amount - fee; // 已校验 amount >= fee
}
// 循环计数器
unchecked { ++i; }
```

#### 3. Storage 变量缓存
```solidity
address stealth = req.stealthAddress; // 避免多次 calldata 解码 + storage key 计算
address token   = req.token;
uint256 bal     = balances[token][stealth]; // 一次 SLOAD，复用于检查和更新
```

#### 4. 循环优化
```solidity
uint256 len = stealthAddresses.length; // 缓存 length，避免重复 mload
for (uint256 i = 0; i < len;) { ... unchecked { ++i; } }
```

#### 5. SafeTransfer 统一
`claim` 中的 ERC-20 转账从裸 `.transfer()` 改为 `.safeTransfer()`，与 `batchAllocate` 保持一致。

### Gas 优化结果
| 函数 | 优化前 | 优化后 | 节省 | 降幅 |
|------|--------|--------|------|------|
| `batchAllocate(100)` | 2,962,336 | 2,961,048 | 1,288 | 0.04% |
| `claim` | 97,386 | 92,213 | **5,173** | **5.3%** |

`claim` 是最高频操作，5.3% 降幅在主网高 gas 时期每次可节省约 0.15–0.5 USD。

---

## 最终测试状态

```
Ran 12 tests for test/StealthPayVault.t.sol:StealthPayVaultTest
[PASS] testFuzz_AllocationAndClaim(uint256,uint256)  (runs: 256)
[PASS] test_BatchAllocate()
[PASS] test_ClaimWithValidSignature()
[PASS] test_GasCost_BatchAllocate_100()
[PASS] test_GasCost_Claim()
[PASS] test_NativeETH_Flow()                         (TODO 占位)
[PASS] test_RevertIf_ExpiredDeadline()
[PASS] test_RevertIf_InsufficientBalance()
[PASS] test_RevertIf_ReplayAttack()
[PASS] test_RevertIf_SignatureMalleability()         (TODO 占位)
[PASS] test_RevertIf_TamperedPayload()
[PASS] test_RevertIf_WrongSigner()
```

---

## 架构总结

```
企业多签 (Owner)
  │
  ▼ batchAllocate(stealthAddrs[], tokens[], amounts[])
┌─────────────────────────────┐
│      StealthPayVault        │
│                             │
│  balances[token][stealth]   │  ← 链上账本（隐断关联）
│  nonces[stealth]            │  ← 防重放
│  DOMAIN_SEPARATOR (immut.)  │  ← EIP-712
└─────────────────────────────┘
  │
  ▼ claim(ClaimRequest, signature)  ← Relayer 代发
recipient ← amount - fee
relayer   ← fee
```

**安全检查顺序（claim）：**
`deadline → nonce → fee ≤ amount → 签名验证 → 余额 → 状态更新（unchecked） → 转账`

**关键安全属性：**
- 签名验证先于余额检查：防余额信息泄露
- CEI 模式 + `nonReentrant`：双重防重入
- OZ `ECDSA.recover`：自动防签名延展性（high-s 值）
- `SafeERC20`：防不规范 token 静默失败

---

## 阶段 8：TypeScript SDK（链下 ECDH 影子密钥推导）

### 目标
将合约侧的密码学协议在链下复现：员工用 JS/TS 推导影子私钥，完成独立的密钥管理闭环。

### 技术选型
| 库 | 用途 |
|----|------|
| `@noble/curves` | secp256k1 椭圆曲线运算（ProjectivePoint, CURVE.n） |
| `@noble/hashes` | keccak_256 散列 |
| `viem/accounts` | `privateKeyToAccount` 验证以太坊地址 |
| `vitest` | TypeScript 单元测试框架 |

### TDD 流程

#### RED
三个测试（先行）：
1. **主链路**：`metaPrivKey → metaPubKey → HR 计算 stealthAddress → 员工恢复 stealthPrivKey → 断言地址吻合`
2. **一次性特性**：不同 `ephemeralKey` 生成不同 stealth 地址
3. **格式断言**：`getMetaPublicKey` 输出匹配 `/^0x04[0-9a-f]{128}$/i`（未压缩格式）

红灯：`Error: Failed to load url ../src/StealthKey.js — Does the file exist?`

#### GREEN — 核心密码学实现

```typescript
// ECDH：scalar × point → 压缩字节（33 B）
function sharedSecret(scalarHex, pubHex): Uint8Array {
  return secp256k1.ProjectivePoint.fromHex(pubHex)
    .multiply(BigInt('0x' + scalarHex))
    .toRawBytes(true); // compressed
}

// h = keccak256(sharedSecret) mod n
function sharedSecretToScalar(secret): bigint {
  return BigInt('0x' + bytesToHex(keccak_256(secret))) % CURVE_ORDER;
}

// HR 端
export function computeStealthAddress(metaPub, ephemeralPriv) {
  const h = sharedSecretToScalar(sharedSecret(ephemeralPriv, metaPub));
  const stealthPoint = secp256k1.ProjectivePoint.fromHex(metaPub)
    .add(secp256k1.ProjectivePoint.BASE.multiply(h));
  // ...
}

// 员工端
export function recoverStealthPrivateKey(metaPriv, ephemeralPub) {
  const h = sharedSecretToScalar(sharedSecret(metaPriv, ephemeralPub));
  return (metaPrivBigInt + h) % CURVE_ORDER;
}
```

#### 验证 GREEN

```
✓ test/StealthKey.test.ts (3 tests) 59ms
Test Files  1 passed (1)
     Tests  3 passed (3)
```

### 关键决策
- **ECDH 对称性**：`ephemeralPriv · metaPub = metaPriv · ephemeralPub`，两端独立计算同一共享密钥
- **压缩格式**：共享密钥取压缩形式（33 B）再做 keccak256，与 EIP-5564 参考实现对齐
- **以太坊地址推导**：`keccak256(uncompressed[1:])[12:]`（去掉 0x04 前缀，取哈希最后 20 字节）

---

## 阶段 9：E2E 全链路集成测试

### 目标
将 TypeScript SDK 与真实编译的 Solidity 合约结合，模拟"HR 发薪 → 员工签名 → Relayer 代发"完整闭环，在本地 Anvil 节点上端到端验证。

### 技术选型
| 技术 | 用途 |
|------|------|
| `viem` | 合约部署、交易发送、EIP-712 签名 |
| `viem/chains` `foundry` | chainId = 31337（与 Anvil 对齐） |
| Anvil (子进程) | 本地 EVM 节点，提供有余额的测试账户 |
| `out/*.json` | 真实 forge 编译产物（ABI + Bytecode） |

### TDD 流程

#### RED
首次失败原因：
```
Error: Anvil 启动超时
```
根因：`spawn('anvil', ['--silent'])` 使 Anvil 不输出 `"Listening on"` 日志，Promise 永远无法 resolve。

**修复：** 去掉 `--silent`，同时监听 `stdout` + `stderr`（Anvil 各版本输出渠道不同）。

#### GREEN（全链路流程）

```typescript
// [角色 1] HR
const metaPubKey = getMetaPublicKey(META_PRIV);
const { stealthAddress } = computeStealthAddress(metaPubKey, ephemeralPriv);
await walletClient.writeContract({ functionName: 'mint', ... });
await walletClient.writeContract({ functionName: 'approve', ... });
await walletClient.writeContract({ functionName: 'batchAllocate', ... });

// [角色 2] Employee
const stealthPriv = recoverStealthPrivateKey(META_PRIV, ephemeralPub);
const signature = await walletClient.signTypedData({
  domain: { name: 'StealthPay', version: '1', chainId: 31337, verifyingContract: vaultAddress },
  types: { ClaimRequest: [...] },
  message: { stealthAddress, token, amount: 5000e6, feeAmount: 50e6, ... },
});

// [角色 3] Relayer
await walletClient.writeContract({ functionName: 'claim', args: [claimReq, signature] });

// 断言
expect(recipientBalance).toBe(4_950_000_000n); // 4950 USDT
expect(relayerBalance).toBe(50_000_000n);       //   50 USDT
```

#### 验证 GREEN

```
✓ test/e2e.integration.test.ts (1 test) 185ms
✓ test/StealthKey.test.ts (3 tests) 53ms

Test Files  2 passed (2)
     Tests  4 passed (4)
```

### 关键决策

- **EIP-712 domain 完全对齐**：`name = "StealthPay"`, `version = "1"`, `chainId = 31337`（foundry chain），`verifyingContract` = 部署后的合约地址——任何一项错误均会导致签名验证失败
- **本地签名（LocalAccount）**：`privateKeyToAccount(stealthPriv)` 生成的账户无需连接节点即可签名，不需要 stealthAddress 有 ETH
- **动态 nonce 读取**：`publicClient.readContract({ functionName: 'nonces', args: [stealthAddress] })` 确保 nonce 与链上状态一致
- **Anvil 子进程生命周期**：`beforeAll` 启动（30s timeout），`afterAll` `kill()`，防止测试套件结束后端口占用

---

## 阶段 10：Merkle Tree 架构重构（隐藏员工总数与薪资结构）

### 动机
原有 `batchAllocate` 方案将所有影子地址与金额明文写入 calldata，链上可推断企业发薪规模。改用 Merkle Tree：HR 只提交一个 32 字节的树根，链上信息仅为"本期共发放 X 代币"，员工按需提供自己的 Merkle Proof 提款。

### 架构变更对比

| 方面 | 旧方案 | 新方案（Merkle） |
|------|--------|----------------|
| 资金分配 | `batchAllocate(addrs[], tokens[], amounts[])` | `depositForPayroll(merkleRoot, token, total)` |
| 隐私性 | calldata 含所有地址与金额 | 只有 root（32 字节），叶子数据链下保管 |
| 防重放 | `nonces[stealthAddr]++` | `isClaimed[stealthAddr] = true` |
| claim 签名 | ClaimRequest 含 `nonce` | ClaimRequest 无 `nonce`（一次性 isClaimed 足够） |
| claim 参数 | `claim(req, sig)` | `claim(req, sig, merkleProof[], root)` |
| 状态变量 | `balances[token][stealth]` | `activeRoots[root]` + `isClaimed[stealth]` |

### Merkle 树结构

```
叶子：leaf = keccak256(abi.encodePacked(stealthAddress, token, amount))

2-叶示例（OZ 排序）：
  leaf1 = keccak256(stealthAddr1, usdt, 1000e18)
  leaf2 = keccak256(stealthAddr2, usdt, 2000e18)
  root  = keccak256(min(leaf1,leaf2) ++ max(leaf1,leaf2))

  leaf1 的 proof = [leaf2]，leaf2 的 proof = [leaf1]

单叶退化树（fuzz 测试用）：
  root = leaf，proof = []（OZ processProof 空 proof 时返回 leaf 本身）
```

### claim 检查顺序

```
deadline → isClaimed → feeAmount ≤ amount → activeRoots[root] → MerkleProof.verify → ECDSA.recover → isClaimed=true → 转账
```

### TDD 流程

#### RED
失败原因：`Member "depositForPayroll" not found or not visible`（测试使用新接口，合约还是旧接口）

新增测试：`test_DepositForPayroll`、`test_RevertIf_InvalidRoot`、`test_RevertIf_InvalidMerkleProof`

更新测试：`test_ClaimWithValidSignature`（含 AlreadyClaimed 验证）、`test_RevertIf_TamperedPayload`（篡改 amount 现在触发 `InvalidMerkleProof`）

移除测试：`test_BatchAllocate`、`test_GasCost_BatchAllocate_100`

#### 验证 GREEN

```
Ran 11 tests for test/StealthPayVault.t.sol:StealthPayVaultTest
[PASS] testFuzz_AllocationAndClaim(uint256,uint256) (runs: 256)
[PASS] test_ClaimWithValidSignature()
[PASS] test_DepositForPayroll()
[PASS] test_GasCost_Claim()                     gas: 192036
[PASS] test_NativeETH_Flow()                    (TODO)
[PASS] test_RevertIf_ExpiredDeadline()
[PASS] test_RevertIf_InvalidMerkleProof()
[PASS] test_RevertIf_InvalidRoot()
[PASS] test_RevertIf_SignatureMalleability()    (TODO)
[PASS] test_RevertIf_TamperedPayload()
[PASS] test_RevertIf_WrongSigner()
11 passed; 0 failed
```

---

## 待完善（TODO）

| 项目 | 说明 |
|------|------|
| `test_NativeETH_Flow` | ETH 完整提款流程专项测试 |
| `test_RevertIf_SignatureMalleability` | 构造 high-s 签名，验证 OZ ECDSA 拦截 |
| E2E 集成测试更新 | `sdk/test/e2e.integration.test.ts` 需迁移到 Merkle 接口 |
| 部署脚本 | Foundry `script/Deploy.s.sol` |
| Natspec 完善 | 所有 public 接口补全文档注释 |
