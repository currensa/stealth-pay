/**
 * testnet-e2e.ts — StealthPayVault Sepolia 全链路测试脚本
 *
 * 用法：
 *   1. 在 sdk/.env 中填写 PRIVATE_KEY 和 SEPOLIA_RPC_URL
 *   2. 将下方 VAULT_ADDRESS / USDT_ADDRESS 替换为 forge script 部署后打印的实际地址
 *   3. npx tsx sdk/scripts/testnet-e2e.ts
 *
 * 流程：
 *   [HR]      computeStealthAddress → depositForPayroll
 *   [Employee] recoverStealthPrivateKey → signTypedData (EIP-712)
 *   [Relayer]  claim(req, sig, proof, root)
 */

import 'dotenv/config';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { StandardMerkleTree } from '@openzeppelin/merkle-tree';
import {
  createPublicClient,
  createWalletClient,
  http,
  getAddress,
  parseEther,
  type Hex,
  type Address,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { sepolia } from 'viem/chains';
import {
  getMetaPublicKey,
  computeStealthAddress,
  recoverStealthPrivateKey,
} from '../src/StealthKey.js';

// ─── 路径 ──────────────────────────────────────────────────────────────────

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT  = resolve(__dirname, '../../'); // sdk/scripts/ → stealth-pay/

// ─── !! 部署后请替换为真实地址 !! ──────────────────────────────────────────

const VAULT_ADDRESS: Address = '0x0000000000000000000000000000000000000000'; // TODO: 填入 StealthPayVault 地址
const USDT_ADDRESS:  Address = '0x0000000000000000000000000000000000000000'; // TODO: 填入 ERC20Mock 地址

// ─── ABI（forge build 后从 out/ 读取）──────────────────────────────────────

const vaultArtifact = JSON.parse(
  readFileSync(resolve(REPO_ROOT, 'out/StealthPayVault.sol/StealthPayVault.json'), 'utf-8'),
);
const usdtArtifact = JSON.parse(
  readFileSync(resolve(REPO_ROOT, 'out/ERC20Mock.sol/ERC20Mock.json'), 'utf-8'),
);

// ─── 环境变量 ───────────────────────────────────────────────────────────────

const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex | undefined;
const RPC_URL     = process.env.SEPOLIA_RPC_URL as string | undefined;

if (!PRIVATE_KEY) throw new Error('Missing PRIVATE_KEY in .env');
if (!RPC_URL)     throw new Error('Missing SEPOLIA_RPC_URL in .env');

// ─── Viem 客户端 ────────────────────────────────────────────────────────────

const deployerAccount = privateKeyToAccount(PRIVATE_KEY);

const publicClient = createPublicClient({
  chain:     sepolia,
  transport: http(RPC_URL),
});

const walletClient = createWalletClient({
  account:   deployerAccount,
  chain:     sepolia,
  transport: http(RPC_URL),
});

// ─── 金额常量（ERC20Mock 精度 = 18）────────────────────────────────────────

const AMOUNT     = parseEther('5000'); // 5 000 USDT
const FEE_AMOUNT = parseEther('50');   //    50 USDT（Relayer 手续费）

// ─── Main ───────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  console.log('=== StealthPay Sepolia E2E ===');
  console.log(`Deployer / HR / Relayer : ${deployerAccount.address}`);
  console.log(`Vault                   : ${VAULT_ADDRESS}`);
  console.log(`Mock USDT               : ${USDT_ADDRESS}`);

  // ── [本地密码学] 生成影子地址 ──────────────────────────────────────────────
  // 员工的 meta 私钥（测试网固定值，生产环境员工自持）
  const META_PRIV      = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a' as Hex;
  // HR 本月一次性临时私钥
  const EPHEMERAL_PRIV = '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef' as Hex;

  const metaPub      = getMetaPublicKey(META_PRIV);
  const ephemeralPub = getMetaPublicKey(EPHEMERAL_PRIV);
  const { stealthAddress } = computeStealthAddress(metaPub, EPHEMERAL_PRIV);
  console.log(`\nStealth address         : ${stealthAddress}`);

  // ── [构建 Merkle 树] ────────────────────────────────────────────────────────
  const tree = StandardMerkleTree.of(
    [[getAddress(stealthAddress), getAddress(USDT_ADDRESS), AMOUNT.toString()]],
    ['address', 'address', 'uint256'],
  );
  const merkleRoot  = tree.root as Hex;
  const merkleProof = tree.getProof(0) as Hex[];
  console.log(`Merkle root             : ${merkleRoot}`);

  // ── [链上交互 1] HR 发薪：approve + depositForPayroll ─────────────────────

  console.log('\n[1/4] Approving Mock USDT to Vault...');
  const approveTx = await walletClient.writeContract({
    address:      USDT_ADDRESS,
    abi:          usdtArtifact.abi,
    functionName: 'approve',
    args:         [VAULT_ADDRESS, AMOUNT],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveTx });
  console.log(`  tx: ${approveTx}`);

  console.log('[2/4] depositForPayroll...');
  const depositTx = await walletClient.writeContract({
    address:      VAULT_ADDRESS,
    abi:          vaultArtifact.abi,
    functionName: 'depositForPayroll',
    args:         [merkleRoot, getAddress(USDT_ADDRESS), AMOUNT],
  });
  await publicClient.waitForTransactionReceipt({ hash: depositTx });
  console.log(`  tx: ${depositTx}`);

  // ── [本地密码学] 员工恢复影子私钥并签名 ───────────────────────────────────

  const stealthPriv    = recoverStealthPrivateKey(META_PRIV, ephemeralPub) as Hex;
  const stealthAccount = privateKeyToAccount(stealthPriv);
  const deadline       = BigInt(Math.floor(Date.now() / 1000) + 3_600);

  const claimReq = {
    stealthAddress: stealthAccount.address as Address,
    token:          getAddress(USDT_ADDRESS),
    amount:         AMOUNT,
    recipient:      deployerAccount.address, // 收款至 deployer 地址
    feeAmount:      FEE_AMOUNT,
    deadline,
  };

  const signature = await walletClient.signTypedData({
    account:     stealthAccount,
    domain: {
      name:              'StealthPay',
      version:           '1',
      chainId:           sepolia.id,
      verifyingContract: VAULT_ADDRESS,
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
    message:     claimReq,
  });
  console.log('\n[3/4] Employee signed ClaimRequest (EIP-712, offline)');

  // ── [链上交互 2] Relayer 代发 claim ────────────────────────────────────────

  console.log('[4/4] Relayer calling claim...');
  const claimTx = await walletClient.writeContract({
    address:      VAULT_ADDRESS,
    abi:          vaultArtifact.abi,
    functionName: 'claim',
    args:         [claimReq, signature, merkleProof, merkleRoot],
  });
  await publicClient.waitForTransactionReceipt({ hash: claimTx });
  console.log(`  tx: ${claimTx}`);

  // ── [验证] ─────────────────────────────────────────────────────────────────

  console.log('\n✅ Testnet E2E 完成！');
  console.log(`Sepolia Explorer: https://sepolia.etherscan.io/tx/${claimTx}`);
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
