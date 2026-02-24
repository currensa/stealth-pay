/**
 * E2E 全链路集成测试（Merkle 架构 v2.0）
 *
 * 模拟真实世界中「HR 发薪 → 员工签名 → 中继器代发」的完整闭环：
 *
 * [角色 1] HR          → computeStealthAddress → buildMerkleTree → depositForPayroll（链上）
 * [角色 2] Employee    → recoverStealthPrivateKey → signTypedData（链下签名）
 * [角色 3] Relayer     → claim(req, sig, proof, root)（链上代发，自付 gas）
 *
 * 使用本地 Anvil 节点 + 真实编译产物（out/）进行全链路验证。
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { StandardMerkleTree } from '@openzeppelin/merkle-tree';
import {
  createPublicClient,
  createWalletClient,
  http,
  getAddress,
  type Hex,
  type Address,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { foundry } from 'viem/chains';
import {
  getMetaPublicKey,
  computeStealthAddress,
  recoverStealthPrivateKey,
} from '../src/StealthKey.js';

// ─── 路径 ──────────────────────────────────────────────────────────────────

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT  = resolve(__dirname, '../../');

// ─── 编译产物 ───────────────────────────────────────────────────────────────

const vaultArtifact = JSON.parse(
  readFileSync(resolve(REPO_ROOT, 'out/StealthPayVault.sol/StealthPayVault.json'), 'utf-8'),
);
const usdtArtifact = JSON.parse(
  readFileSync(resolve(REPO_ROOT, 'out/StealthPayVault.t.sol/MockUSDT.json'), 'utf-8'),
);

// ─── Anvil 默认账户（助记词：test test … junk）──────────────────────────────

const HR_PRIV       = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' as Hex;
const RELAYER_PRIV  = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' as Hex;
const META_PRIV     = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a' as Hex; // 员工 meta 私钥
const RECIPIENT_PRIV= '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6' as Hex; // 交易所账户

const hrAccount        = privateKeyToAccount(HR_PRIV);
const relayerAccount   = privateKeyToAccount(RELAYER_PRIV);
const recipientAddress = privateKeyToAccount(RECIPIENT_PRIV).address;

// ─── Viem 客户端 ────────────────────────────────────────────────────────────

const publicClient = createPublicClient({
  chain: foundry,
  transport: http('http://127.0.0.1:8545'),
});

const walletClient = createWalletClient({
  chain: foundry,
  transport: http('http://127.0.0.1:8545'),
});

// ─── 金额常量（MockUSDT 精度 = 6）──────────────────────────────────────────

const USDT_AMOUNT = 5_000n * 10n ** 6n; // 5 000 USDT
const FEE_AMOUNT  =    50n * 10n ** 6n; //    50 USDT（给 Relayer）

// ─── 全局状态 ───────────────────────────────────────────────────────────────

let anvilProcess: ChildProcess;
let vaultAddress: Address;
let usdtAddress:  Address;

// ─── beforeAll：启动 Anvil + 部署合约 ──────────────────────────────────────

beforeAll(async () => {
  // 1. 启动 Anvil
  anvilProcess = spawn('anvil', ['--port', '8545'], { stdio: ['ignore', 'pipe', 'pipe'] });

  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Anvil 启动超时')), 10_000);
    const onData = (d: Buffer) => {
      if (d.toString().includes('Listening on')) { clearTimeout(timer); resolve(); }
    };
    anvilProcess.stdout!.on('data', onData);
    anvilProcess.stderr!.on('data', onData);
    anvilProcess.on('error', (err) => { clearTimeout(timer); reject(err); });
  });

  // 2. 部署 MockUSDT
  const usdtHash = await walletClient.deployContract({
    abi:      usdtArtifact.abi,
    bytecode: usdtArtifact.bytecode.object as Hex,
    account:  hrAccount,
  });
  const usdtReceipt = await publicClient.waitForTransactionReceipt({ hash: usdtHash });
  usdtAddress = usdtReceipt.contractAddress!;

  // 3. 部署 StealthPayVault（owner = HR）
  const vaultHash = await walletClient.deployContract({
    abi:      vaultArtifact.abi,
    bytecode: vaultArtifact.bytecode.object as Hex,
    args:     [hrAccount.address],
    account:  hrAccount,
  });
  const vaultReceipt = await publicClient.waitForTransactionReceipt({ hash: vaultHash });
  vaultAddress = vaultReceipt.contractAddress!;
}, 30_000);

// ─── afterAll：关闭 Anvil ───────────────────────────────────────────────────

afterAll(() => {
  anvilProcess?.kill();
});

// ─── 测试 ───────────────────────────────────────────────────────────────────

describe('Complete Stealth Payroll Flow (Merkle v2)', () => {
  it(
    'HR depositForPayroll → 员工恢复影子私钥并签名 → Relayer claim → recipient 精准到账 4950，relayer 获得 50',
    async () => {
      // ── [角色 1] HR 发薪 ───────────────────────────────────────────────────

      // 员工上传 metaPubKey 给 HR（员工持有 META_PRIV，HR 只知道公钥）
      const metaPubKey = getMetaPublicKey(META_PRIV);

      // HR 生成本月一次性临时密钥对
      const ephemeralPriv = '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef' as Hex;
      const ephemeralPub  = getMetaPublicKey(ephemeralPriv);

      // HR 推导员工本月影子地址
      const { stealthAddress } = computeStealthAddress(metaPubKey, ephemeralPriv);
      const stealthAddr = getAddress(stealthAddress) as Address;

      // HR 构建 Merkle Tree（叶子：[stealthAddress, token, amount]）
      // StandardMerkleTree 叶子格式：keccak256(keccak256(abi.encode(values)))
      const tree = StandardMerkleTree.of(
        [[stealthAddr, getAddress(usdtAddress), USDT_AMOUNT.toString()]],
        ['address', 'address', 'uint256'],
      );
      const merkleRoot = tree.root as Hex;
      const merkleProof = tree.getProof(0) as Hex[];

      // HR 铸造 USDT → approve vault → depositForPayroll
      await walletClient.writeContract({
        address: usdtAddress, abi: usdtArtifact.abi,
        functionName: 'mint',
        args: [hrAccount.address, USDT_AMOUNT],
        account: hrAccount,
      });

      await walletClient.writeContract({
        address: usdtAddress, abi: usdtArtifact.abi,
        functionName: 'approve',
        args: [vaultAddress, USDT_AMOUNT],
        account: hrAccount,
      });

      const depositHash = await walletClient.writeContract({
        address: vaultAddress, abi: vaultArtifact.abi,
        functionName: 'depositForPayroll',
        args: [merkleRoot, getAddress(usdtAddress), USDT_AMOUNT],
        account: hrAccount,
      });
      await publicClient.waitForTransactionReceipt({ hash: depositHash });

      // ── [角色 2] 员工恢复影子私钥并签名 ───────────────────────────────────

      // 员工拿到 HR 公告的 ephemeralPub，推导影子私钥
      const stealthPriv    = recoverStealthPrivateKey(META_PRIV, ephemeralPub) as Hex;
      const stealthAccount = privateKeyToAccount(stealthPriv);

      // 双重验证：影子私钥对应的地址 == HR 计算的 stealthAddress
      expect(stealthAccount.address.toLowerCase()).toBe(stealthAddress.toLowerCase());

      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3_600);

      const claimReq = {
        stealthAddress: stealthAccount.address as Address,
        token:          getAddress(usdtAddress),
        amount:         USDT_AMOUNT,
        recipient:      recipientAddress,
        feeAmount:      FEE_AMOUNT,
        deadline,
      };

      // EIP-712 签名（本地签名，影子私钥）
      const signature = await walletClient.signTypedData({
        account: stealthAccount,
        domain: {
          name:              'StealthPay',
          version:           '1',
          chainId:           foundry.id,
          verifyingContract: vaultAddress,
        },
        types: {
          ClaimRequest: [
            { name: 'stealthAddress', type: 'address' },
            { name: 'token',          type: 'address' },
            { name: 'amount',         type: 'uint256' },
            { name: 'recipient',      type: 'address' },
            { name: 'feeAmount',      type: 'uint256' },
            { name: 'deadline',       type: 'uint256' },
          ],
        },
        primaryType: 'ClaimRequest',
        message: claimReq,
      });

      // ── [角色 3] Relayer 代发 ──────────────────────────────────────────────

      const claimHash = await walletClient.writeContract({
        address: vaultAddress, abi: vaultArtifact.abi,
        functionName: 'claim',
        args: [claimReq, signature, merkleProof, merkleRoot],
        account: relayerAccount,
      });
      await publicClient.waitForTransactionReceipt({ hash: claimHash });

      // ── 终极断言 ───────────────────────────────────────────────────────────

      const recipientBal = await publicClient.readContract({
        address: usdtAddress, abi: usdtArtifact.abi,
        functionName: 'balanceOf',
        args: [recipientAddress],
      }) as bigint;

      const relayerBal = await publicClient.readContract({
        address: usdtAddress, abi: usdtArtifact.abi,
        functionName: 'balanceOf',
        args: [relayerAccount.address],
      }) as bigint;

      expect(recipientBal).toBe(USDT_AMOUNT - FEE_AMOUNT); // 4 950 USDT
      expect(relayerBal).toBe(FEE_AMOUNT);                  //    50 USDT
    },
    60_000,
  );
});
