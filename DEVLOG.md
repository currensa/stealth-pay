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

## 阶段 11：合约完善（ETH 流程 + 签名延展性 + NatSpec）

### 目标
清除阶段 10 遗留的 TODO 测试，完成合约文档注释。

### `test_NativeETH_Flow`
原生 ETH 完整流程：`depositForPayroll{value}` → 单叶树 → `claim` → 断言 ETH 余额精准到账。
关键点：`token = address(0)` 走 `call{value}` 分支；`vm.deal(owner, amount)` 补充测试 ETH。

### `test_RevertIf_SignatureMalleability`
构造 high-s 签名：`s2 = N - s`，`v2 = flip(v)`（secp256k1 曲线阶 N 已知常量）。
OZ `ECDSA.recover` 内部检查 `s <= N/2`，遇到 high-s 直接 revert `ECDSAInvalidSignatureS`。
测试用 `vm.expectRevert()` 宽松匹配，避免依赖 OZ 内部错误字符串。

### NatSpec
为所有 `public`/`external` 接口、状态变量、事件、自定义错误补全 `@notice`/`@dev`/`@param`/`@return`。

### 验证 GREEN

```
Ran 11 tests for test/StealthPayVault.t.sol:StealthPayVaultTest
[PASS] testFuzz_AllocationAndClaim(uint256,uint256) (runs: 256)
[PASS] test_ClaimWithValidSignature()
[PASS] test_DepositForPayroll()
[PASS] test_GasCost_Claim()               gas: ~192,036
[PASS] test_NativeETH_Flow()              ✅ 新增
[PASS] test_RevertIf_ExpiredDeadline()
[PASS] test_RevertIf_InvalidMerkleProof()
[PASS] test_RevertIf_InvalidRoot()
[PASS] test_RevertIf_SignatureMalleability() ✅ 新增
[PASS] test_RevertIf_TamperedPayload()
[PASS] test_RevertIf_WrongSigner()
11 passed; 0 failed
```

---

## 阶段 12：E2E 迁移至 Merkle v2 + 部署脚本

### E2E 迁移
`sdk/test/e2e.integration.test.ts` 从旧 `batchAllocate` 接口完整迁移至 Merkle v2：

**关键变更：**
- 安装 `@openzeppelin/merkle-tree`，引入 `StandardMerkleTree`
- `StandardMerkleTree.of([[stealthAddr, token, amount]], ["address","address","uint256"])` 构建单叶树
- `tree.root` → `depositForPayroll`；`tree.getProof(0)` → `claim` 的第三参数
- 移除 `nonce`，`ClaimRequest` 精简为 6 字段
- `claim` 升级为 4 参数 `(req, sig, proof[], root)`

**叶子格式兼容问题（关键 Bug）：**
`StandardMerkleTree` 使用双重哈希：`keccak256(keccak256(abi.encode(...)))`，而原合约使用 `keccak256(abi.encodePacked(...))`——两者不兼容，E2E 必然抛 `InvalidMerkleProof`。

**修复：** 同步更新合约与 Solidity 测试辅助函数 `_leaf()`：
```solidity
// 旧：keccak256(abi.encodePacked(stealth, token, amount))
// 新：
bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(stealth, token, amount))));
```

### 部署脚本 `script/Deploy.s.sol`
`DeployScript` 继承 `Script`，`run()` 读取 `PRIVATE_KEY` 环境变量，依次部署 `ERC20Mock` 和 `StealthPayVault`，铸造初始 USDT，打印地址。

### 验证 GREEN

```
forge test:  11/11 PASS
vitest:       4/4 PASS（StealthKey × 3 + E2E × 1）
forge build: Compiler run successful!
```

---

## 阶段 13：Sepolia 测试网部署脚手架

### 目标
提供完整的测试网部署 + 全链路验证工具链，使任何人可在 Sepolia 上复现完整发薪流程。

### 新增文件

#### `src/mocks/ERC20Mock.sol`
继承 OZ `ERC20`，添加无权限 `mint(address, uint256)` 函数（测试网专用）。

#### `script/Deploy.s.sol`（更新）
```solidity
// 1. 部署 ERC20Mock("Tether USD", "USDT")
// 2. 部署 StealthPayVault(deployer)
// 3. usdt.mint(deployer, 1_000_000 * 10**18)
// 4. console2.log 打印两个合约地址
```

#### `sdk/scripts/testnet-e2e.ts`
Node.js/TypeScript 脚本，读取 `sdk/.env`（`PRIVATE_KEY` + `SEPOLIA_RPC_URL`），串联完整发薪闭环：

```
[本地] computeStealthAddress → StandardMerkleTree.of
[链上] approve → depositForPayroll
[本地] recoverStealthPrivateKey → signTypedData (EIP-712)
[链上] claim(req, sig, proof, root)
[输出] Sepolia Etherscan 链接
```

**运行：** `cd sdk && npm run run:testnet`（使用 `tsx` 直接执行 TypeScript）

### 依赖
- `dotenv` → 读取 `.env` 环境变量
- `tsx`（devDependency）→ 无需编译直接运行 TypeScript
- `viem/chains` `sepolia` → Sepolia 链配置（chainId = 11155111）

### 验证

```
forge build: Compiler run successful!（5 个文件）
```

---

---

## 阶段 14：Sepolia 测试网首次上链验证

### 目标
将完整发薪流程部署并运行在真实的 Sepolia 测试网，验证合约与 SDK 在链上的端到端可用性。

### 前置配置修复
在执行部署前，发现根目录 `.env` 存在两个配置错误：

| 问题 | 原值 | 修正值 |
|------|------|--------|
| `SEPOLIA_RPC_URL` 缺少协议头 | `eth-sepolia.g.alchemy.com/...` | `https://eth-sepolia.g.alchemy.com/...` |
| `PRIVATE_KEY` 缺少 `0x` 前缀 | `f9988c31...` | `0xf9988c31...` |

`Deploy.s.sol` 使用 `vm.envUint("PRIVATE_KEY")` 读取私钥，该函数需要 `0x` 前缀才能正确解析十六进制；`viem` 的 `privateKeyToAccount` 同理。

同时创建 `sdk/.env`（`testnet-e2e.ts` 使用 `import 'dotenv/config'` 从脚本运行目录加载，而非项目根目录）。

### 部署

```bash
source .env && forge script script/Deploy.s.sol:DeployScript \
  --rpc-url $SEPOLIA_RPC_URL --broadcast
```

部署产物（Sepolia）：
- `ERC20Mock (USDT)` : `0x36Beb3D00ca469BC61d8521eb6Dc804F6Ba7E9D6`
- `StealthPayVault`  : `0x96da8F41A85382b607E84982D398110E2C3f89a7`
- `Deployer (Owner)` : `0xeb310f47111a9E5DB4b66C0E3A4C5d8F31E99189`

合约地址通过环境变量管理（`sdk/.env` 中的 `VAULT_ADDRESS` / `USDT_ADDRESS`），不硬编码进代码；`broadcast/` 目录加入 `.gitignore`，防止交易日志泄露。

### 全链路运行结果

```
=== StealthPay Sepolia E2E ===
Deployer / HR / Relayer : 0xeb310f47111a9E5DB4b66C0E3A4C5d8F31E99189
Vault                   : 0x96da8F41A85382b607E84982D398110E2C3f89a7
Mock USDT               : 0x36Beb3D00ca469BC61d8521eb6Dc804F6Ba7E9D6

Stealth address         : 0xb53d1b56ead22ecb07395e585eb52b29fb30c80a
Merkle root             : 0x2d78826de1004a791ebdfb2f99be1b8a3e5f6ba79863db0af2c57c396c407220

[1/4] Approving Mock USDT to Vault...        tx: 0xf07569...
[2/4] depositForPayroll...                   tx: 0x3cdbee...
[3/4] Employee signed ClaimRequest (EIP-712, offline)
[4/4] Relayer calling claim...               tx: 0x7977cc...

✅ Testnet E2E 完成！
```

4 笔交易全部上链，隐私发薪全链路在 Sepolia 首次验证通过。

---

## 阶段 15：物理角色隔离重构

### 动机
原有测试与 E2E 脚本存在角色混用问题：
- Foundry 测试中 `owner`、`relayer`、`employee` 语义不够明确，`_depositUSDT` 辅助函数内部自行铸币，未反映真实的角色职责边界
- `testnet-e2e.ts` 使用单一 `PRIVATE_KEY` 同时扮演 HR、Relayer 两个角色，一个 `walletClient` 发起所有链上操作

### Foundry 测试重构（`test/StealthPayVault.t.sol`）

**角色重命名：**

| 旧变量 | 新变量 | 职责定义 |
|--------|--------|---------|
| `owner` | `hrAdmin` | Vault Owner，持有海量 USDT，拥有发薪权限 |
| `relayer` | `relayerNode` | 中继器节点，唯一调用 `claim()`，无初始 USDT |
| `employee` | `employeeDest` | 员工最终收款地址，纯白板 |

**`setUp()` 职责集中化：**
```solidity
// 新 setUp：铸币与授权统一完成，覆盖 fuzz 上界
usdt.mint(hrAdmin, 1e36);
vm.prank(hrAdmin);
usdt.approve(address(vault), type(uint256).max);
```

**`_depositUSDT` 精简：**
```solidity
// 旧：内部自行 mint + approve + deposit（职责越界）
// 新：只负责 prank + depositForPayroll
function _depositUSDT(bytes32 root, uint256 totalAmount) internal {
    vm.prank(hrAdmin);
    vault.depositForPayroll(root, address(usdt), totalAmount);
}
```

**验证 GREEN：**
```
Ran 11 tests for test/StealthPayVault.t.sol:StealthPayVaultTest
[PASS] testFuzz_AllocationAndClaim(uint256,uint256) (runs: 256)
... 11 passed; 0 failed
```

### TypeScript E2E 重构（`sdk/scripts/testnet-e2e.ts`）

**环境变量拆分：**

| 旧 | 新 |
|----|----|
| `PRIVATE_KEY` | `HR_PRIVATE_KEY` + `RELAYER_PRIVATE_KEY` |

**双 Client 架构：**
```typescript
const hrClient      = createWalletClient({ account: hrAccount, ... });
const relayerClient = createWalletClient({ account: relayerAccount, ... });
```

**调用主体绑定：**

| 步骤 | 操作 | 发起方 |
|------|------|--------|
| 1/4 | approve USDT | `hrClient` |
| 2/4 | depositForPayroll | `hrClient` |
| 3/4 | EIP-712 签名 | `stealthAccount`（纯本地，无 gas） |
| 4/4 | claim | `relayerClient` |

---

---

## 阶段 16：多租户 SaaS 架构升级（v3.0）

### 动机
原有合约依赖 `Ownable`，仅 Owner 可调用 `depositForPayroll`，限制了 SaaS 扩展性。目标：升级为 Permissionless 多租户平台——任何企业（HR）均可自主存入薪资，同一合约服务多个企业，跨租户攻击在合约层拦截。

### 架构变更

| 方面 | 旧方案 | 新方案（v3.0） |
|------|--------|---------------|
| 权限模型 | `Ownable`，`depositForPayroll` 限 Owner | Permissionless，任意地址可成为 Employer |
| 状态变量 | `mapping(bytes32 => bool) activeRoots` | `mapping(bytes32 => PayrollRecord) payrolls` |
| Root 绑定 | 仅记录是否存在 | 绑定 `(employer, token, totalAmount)` 三元组 |
| 跨租户防护 | 无 | `req.token != payrolls[root].token → TokenMismatch()` |
| claim 步骤 | 8 步 | 9 步（新增步骤 5：token 一致性检查） |

### TDD 流程

#### RED（测试先行）

**新增测试：**

1. **`test_MultiTenant_Isolation`**：hrA 以 USDT 存款，hrB 以独立部署的 USDC 存款，双方员工各自持有正确 Merkle Proof，独立完成提款，互不干扰，断言各自余额精准到账。

2. **`test_RevertIf_CrossTenantTokenAttack`**：攻击者持有 hrA（USDT）Merkle Root 的有效 Proof，但将 `req.token` 篡改为 USDC，期望合约抛出 `TokenMismatch()`。

**修改测试：**
- `setUp()`：`new StealthPayVault()` 无参数构造（移除 Owner 地址）
- `test_DepositForPayroll`、`test_NativeETH_Flow`：从 `vault.activeRoots(root)` 改为 `vault.payrolls(root)` 结构体访问

#### GREEN（合约重构）

**移除：**
```solidity
// import "@openzeppelin/contracts/access/Ownable.sol";
// contract StealthPayVault is ReentrancyGuard, Ownable
// constructor(address initialOwner) Ownable(initialOwner)
// modifier onlyOwner on depositForPayroll
// mapping(bytes32 => bool) public activeRoots;
```

**新增：**
```solidity
struct PayrollRecord {
    address employer;    // 调用 depositForPayroll 的 HR 地址
    address token;       // 本批薪资代币（address(0) = ETH）
    uint256 totalAmount; // 存入总额
}

mapping(bytes32 => PayrollRecord) public payrolls;

error TokenMismatch(); // 请求代币与 root 绑定代币不一致（跨租户攻击防护）
```

**`depositForPayroll` 变更：**
```solidity
// 旧：onlyOwner，activeRoots[merkleRoot] = true
// 新：Permissionless，payrolls[merkleRoot] = PayrollRecord(msg.sender, token, totalAmount)
```

**`claim` 检查顺序（新增第 5 步）：**
```
deadline → isClaimed → fee ≤ amount → payrolls[root].employer != 0
→ req.token == payrolls[root].token  ← TokenMismatch（新增）
→ MerkleProof.verify → ECDSA.recover → isClaimed=true → 转账
```

#### 调试记录（遇到的坑）

**问题 1：Deploy.s.sol 构造参数未同步**
```
Error: wrong number of arguments for constructor
```
`script/Deploy.s.sol` 仍使用 `new StealthPayVault(deployer)`。移除 `Ownable` 后构造函数无参数，修复为 `new StealthPayVault()`。

**问题 2：Solidity 结构体 public getter 返回 tuple**
```
TypeError: Member "employer" not found in tuple(address,address,uint256)
```
Solidity 的 `public mapping(bytes32 => struct)` getter 返回的是位置元组，不能用 `.employer` 点访问。修复方式：
```solidity
// 错误：vault.payrolls(root).employer
// 正确：
(address emp, address tok,) = vault.payrolls(root);
```

**问题 3：Stack too deep（`test_MultiTenant_Isolation`）**
测试函数局部变量过多（hrA/hrB 各自的 stealth 密钥、证明路径、客户端等），导致 EVM 栈深度超出 16 的限制。
修复：在 `foundry.toml` 添加 `via_ir = true`（启用 Yul 中间代码，消除栈深度限制，代价是编译速度略慢）。

**问题 4：`vm.expectRevert` 拦截了 `vault.CLAIM_TYPEHASH()` staticcall**
`test_RevertIf_CrossTenantTokenAttack` 中，`_signClaimRequest` 辅助函数内部调用 `vault.CLAIM_TYPEHASH()` 来读取类型哈希。`vm.expectRevert` 挂钩的是"下一个外部调用"，导致它拦截了这个 staticcall 而非真正的 `vault.claim()` 调用，测试永远失败。
修复：将签名计算移至 `vm.expectRevert` 调用之前：
```solidity
// 先预计算签名
bytes memory attackSig = _signClaimRequest(req, stealthPkA);
// 再设置 expectRevert，然后调用 claim
vm.expectRevert(StealthPayVault.TokenMismatch.selector);
vault.claim(req, attackSig, proofA, rootA);
```

#### 验证 GREEN

```
Ran 13 tests for test/StealthPayVault.t.sol:StealthPayVaultTest
[PASS] testFuzz_AllocationAndClaim(uint256,uint256) (runs: 256)
[PASS] test_ClaimWithValidSignature()
[PASS] test_DepositForPayroll()
[PASS] test_GasCost_Claim()
[PASS] test_MultiTenant_Isolation()              ✅ 新增
[PASS] test_NativeETH_Flow()
[PASS] test_RevertIf_CrossTenantTokenAttack()    ✅ 新增
[PASS] test_RevertIf_ExpiredDeadline()
[PASS] test_RevertIf_InvalidMerkleProof()
[PASS] test_RevertIf_InvalidRoot()
[PASS] test_RevertIf_SignatureMalleability()
[PASS] test_RevertIf_TamperedPayload()
[PASS] test_RevertIf_WrongSigner()
13 passed; 0 failed
```

---

## 最终状态总览

| 层 | 文件 | 测试数 | 状态 |
|----|------|--------|------|
| 合约 | `src/StealthPayVault.sol` | 13（含 256 轮 fuzz） | ✅ 全绿 |
| 合约 Mock | `src/mocks/ERC20Mock.sol` | — | ✅ 编译通过 |
| 部署脚本 | `script/Deploy.s.sol` | — | ✅ Sepolia 已部署 |
| SDK | `sdk/src/StealthKey.ts` | 3 | ✅ 全绿 |
| 本地 E2E | `sdk/test/e2e.integration.test.ts` | 1 | ✅ 全绿（Anvil） |
| 测试网脚本 | `sdk/scripts/testnet-e2e.ts` | — | ✅ Sepolia 全链路验证通过 |

---

## 阶段 16：Next.js 可视化演示门户（example/）

### 目标
创建独立子目录 `example/`，提供浏览器可视化演示，让 HR 和员工通过 UI 与 Sepolia 上的
StealthPayVault 合约交互。

### 关键技术决策
| 问题 | 决策 | 原因 |
|------|------|------|
| SDK 导入 | 复制 `StealthKey.ts` 到 `example/src/lib/` | 父 SDK 是 ESM-only，Next.js 有 CJS/ESM 混合问题 |
| Merkle Tree | 浏览器端 viem 手算单叶 | `@openzeppelin/merkle-tree` 依赖 Node.js crypto，不支持浏览器 |
| Mock DB | `src/lib/db.ts` 内存数组 + db.json 文件持久化 | 最简单，无外部依赖 |
| 钱包连接 | viem `custom(window.ethereum)` | 无需额外库 |
| 员工身份 | `personal_sign` 签名哈希作为 metaPrivKey | 确定性推导，不用管理密钥 |
| 脚手架 | 手动创建文件（无 npx/npm） | 本机未安装 Node.js |

### 文件结构
```
example/
├── .env.local.example        — 环境变量模板
├── package.json              — next@15, viem, @noble/curves, @noble/hashes
├── src/
│   ├── app/
│   │   ├── layout.tsx        — Root layout（Tailwind 深色主题）
│   │   ├── page.tsx          — 首页：HR / Employee 两大入口
│   │   ├── hr/page.tsx       — HR 控制台（approve + depositForPayroll）
│   │   ├── employee/page.tsx — 员工提取端（scan + signTypedData + relayer）
│   │   └── api/
│   │       ├── db/route.ts       — GET/POST/PATCH mock DB API
│   │       └── relayer/route.ts  — POST → Sepolia claim tx
│   └── lib/
│       ├── stealthKey.ts     — 从父 SDK 复制（纯 ES 密码学）
│       ├── merkle.ts         — 浏览器兼容单叶 Merkle helper
│       ├── vaultAbi.ts       — 合约 ABI + ERC20 ABI 常量
│       ├── constants.ts      — 合约地址、链配置
│       └── db.ts             — 共享 in-memory + db.json DB 工具
└── db.json                   — 运行时写入，已加入 .gitignore
```

### HR 流程
1. 连接 MetaMask（Sepolia）
2. 生成随机 ephemeralPrivKey（32 字节）
3. 推导 ephemeralPublicKey 和 stealthAddress（ECDH）
4. 计算单叶 Merkle root
5. `USDT.approve(vault, amount)` → 等 receipt
6. `vault.depositForPayroll(root, USDT, amount)` → 等 receipt
7. POST `/api/db` 存储记录

### 员工流程
1. 连接 MetaMask
2. `personal_sign("StealthPay Identity v1")` → `metaPrivKey = keccak256(sig)`
3. `metaPubKey = getMetaPublicKey(metaPrivKey)` → 显示供 HR 使用
4. GET `/api/db?metaPubKey=` → 待提取记录列表
5. 对每条：ECDH 恢复 stealthPrivKey
6. `privateKeyToAccount(stealthPrivKey).signTypedData(ClaimRequest)` — 无 Gas
7. POST `/api/relayer` → Relayer 代发 `vault.claim()`

### 结果
- 所有文件已创建，结构完整
- 需运行 `cd example && npm install` 安装依赖后 `npm run dev`
- 配置 `.env.local` 后可在 http://localhost:3000 演示完整流程
