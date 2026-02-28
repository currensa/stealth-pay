'use client';

import { useState } from 'react';
import Link from 'next/link';
import {
  createWalletClient,
  createPublicClient,
  custom,
  http,
  parseUnits,
  type Hex,
} from 'viem';
import { computeStealthAddress } from '@/lib/stealthKey';
import { computeSingleLeafRoot } from '@/lib/merkle';
import { vaultAbi, erc20Abi } from '@/lib/vaultAbi';
import { VAULT_ADDRESS, USDT_ADDRESS, SEPOLIA_CHAIN_ID, sepolia } from '@/lib/constants';

declare global {
  interface Window {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ethereum?: any;
  }
}

type Status = 'idle' | 'approving' | 'depositing' | 'saving' | 'done' | 'error';

const STATUS_LABEL: Record<Status, string> = {
  idle:      '',
  approving: '⏳ 等待 approve 确认…',
  depositing:'⏳ 等待 depositForPayroll 确认…',
  saving:    '💾 保存记录中…',
  done:      '✅ 发薪成功！',
  error:     '❌ 出错了',
};

export default function HRPage() {
  const [metaPubKey, setMetaPubKey] = useState('');
  const [amountStr, setAmountStr]   = useState('');
  const [status, setStatus]         = useState<Status>('idle');
  const [txHash, setTxHash]         = useState<string>('');
  const [errorMsg, setErrorMsg]     = useState('');

  async function handleDeposit() {
    setErrorMsg('');
    setStatus('idle');

    if (!metaPubKey.startsWith('0x') || metaPubKey.length < 10) {
      setErrorMsg('请输入有效的 Meta 公钥（0x04... 开头）');
      return;
    }
    if (!amountStr || isNaN(Number(amountStr)) || Number(amountStr) <= 0) {
      setErrorMsg('请输入有效金额');
      return;
    }
    if (!window.ethereum) {
      setErrorMsg('未检测到 MetaMask，请安装后重试');
      return;
    }

    try {
      // 1. 连接钱包
      const accounts: string[] = await window.ethereum.request({ method: 'eth_requestAccounts' });
      const account = accounts[0] as Hex;

      const chainIdHex: string = await window.ethereum.request({ method: 'eth_chainId' });
      if (parseInt(chainIdHex, 16) !== SEPOLIA_CHAIN_ID) {
        setErrorMsg(`请切换到 Sepolia 测试网（chain ID ${SEPOLIA_CHAIN_ID}）`);
        return;
      }

      const walletClient = createWalletClient({
        account,
        chain: { ...sepolia, id: SEPOLIA_CHAIN_ID },
        transport: custom(window.ethereum),
      });
      const publicClient = createPublicClient({
        chain: { ...sepolia, id: SEPOLIA_CHAIN_ID },
        transport: http(process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ?? 'https://rpc.sepolia.org'),
      });

      // 2. 随机临时私钥（32 bytes）
      const ephemeralPrivBytes = crypto.getRandomValues(new Uint8Array(32));
      const ephemeralPrivHex   = ('0x' + Array.from(ephemeralPrivBytes)
        .map(b => b.toString(16).padStart(2, '0')).join('')) as Hex;

      // 3. 计算临时公钥（员工扫描用）
      const { secp256k1 } = await import('@noble/curves/secp256k1');
      const { bytesToHex } = await import('@noble/hashes/utils');
      const ephemeralPubBytes    = secp256k1.getPublicKey(ephemeralPrivBytes, false); // 65B uncompressed
      const ephemeralPublicKey   = ('0x' + bytesToHex(ephemeralPubBytes)) as Hex;

      // 4. ECDH → stealthAddress
      const { stealthAddress } = computeStealthAddress(metaPubKey, ephemeralPrivHex);

      // 5. 金额（USDT = 6 decimals）
      const amount = parseUnits(amountStr, 6);

      // 6. 单叶 Merkle root
      const merkleRoot = computeSingleLeafRoot(stealthAddress as Hex, USDT_ADDRESS, amount);

      // 7. Approve
      setStatus('approving');
      const approveTx = await walletClient.writeContract({
        address: USDT_ADDRESS,
        abi: erc20Abi,
        functionName: 'approve',
        args: [VAULT_ADDRESS, amount],
      });
      await publicClient.waitForTransactionReceipt({ hash: approveTx });

      // 8. DepositForPayroll
      setStatus('depositing');
      const depositTx = await walletClient.writeContract({
        address: VAULT_ADDRESS,
        abi: vaultAbi,
        functionName: 'depositForPayroll',
        args: [merkleRoot, USDT_ADDRESS, amount],
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash: depositTx });
      if (receipt.status !== 'success') throw new Error('depositForPayroll 交易失败');
      setTxHash(depositTx);

      // 9. 写入 DB
      setStatus('saving');
      const res = await fetch('/api/db', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          metaPubKey,
          stealthAddress,
          ephemeralPublicKey,
          merkleRoot,
          amount: amount.toString(),
          token: USDT_ADDRESS,
        }),
      });
      if (!res.ok) throw new Error('写入 DB 失败');

      setStatus('done');
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : String(err));
      setStatus('error');
    }
  }

  const isBusy = status === 'approving' || status === 'depositing' || status === 'saving';

  return (
    <main className="mx-auto max-w-2xl px-6 py-16">
      <Link href="/" className="mb-8 inline-block text-sm text-gray-500 hover:text-gray-300">
        ← 返回首页
      </Link>

      <h1 className="mb-2 text-3xl font-bold text-white">HR 发薪控制台</h1>
      <p className="mb-10 text-gray-400">
        输入员工 Meta 公钥和金额，自动完成 ECDH 推导 → ERC-20 approve → depositForPayroll
      </p>

      <div className="space-y-5 rounded-2xl border border-gray-800 bg-gray-900 p-8">
        <div>
          <label className="mb-1 block text-sm font-medium text-gray-300">
            员工 Meta 公钥（0x04...）
          </label>
          <input
            type="text"
            value={metaPubKey}
            onChange={e => setMetaPubKey(e.target.value)}
            placeholder="0x04..."
            className="w-full rounded-lg border border-gray-700 bg-gray-800 px-4 py-2.5 text-sm text-gray-100 placeholder-gray-600 focus:border-indigo-500 focus:outline-none"
          />
        </div>

        <div>
          <label className="mb-1 block text-sm font-medium text-gray-300">
            发薪金额（USDT）
          </label>
          <input
            type="number"
            value={amountStr}
            onChange={e => setAmountStr(e.target.value)}
            placeholder="例：1000"
            min="0"
            className="w-full rounded-lg border border-gray-700 bg-gray-800 px-4 py-2.5 text-sm text-gray-100 placeholder-gray-600 focus:border-indigo-500 focus:outline-none"
          />
        </div>

        <button
          onClick={handleDeposit}
          disabled={isBusy}
          className="w-full rounded-xl bg-indigo-600 px-6 py-3 font-semibold text-white transition hover:bg-indigo-500 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {isBusy ? STATUS_LABEL[status] : '执行发薪'}
        </button>

        {status === 'done' && (
          <div className="rounded-lg border border-emerald-700 bg-emerald-900/30 p-4 text-sm">
            <p className="font-medium text-emerald-300">✅ 发薪完成！</p>
            <p className="mt-1 text-gray-400">
              Tx:{' '}
              <a
                href={`https://sepolia.etherscan.io/tx/${txHash}`}
                target="_blank"
                rel="noopener noreferrer"
                className="break-all text-indigo-400 hover:underline"
              >
                {txHash}
              </a>
            </p>
          </div>
        )}

        {errorMsg && (
          <div className="rounded-lg border border-red-700 bg-red-900/30 p-4 text-sm text-red-300">
            {errorMsg}
          </div>
        )}
      </div>

      <section className="mt-10 space-y-2 text-sm text-gray-500">
        <p className="font-medium text-gray-400">执行步骤：</p>
        <ol className="list-inside list-decimal space-y-1 pl-2">
          <li>连接 MetaMask（Sepolia）</li>
          <li>生成随机 32 字节 <code className="text-gray-300">ephemeralPrivKey</code></li>
          <li>ECDH 推导 <code className="text-gray-300">stealthAddress</code>（只有员工能还原私钥）</li>
          <li>计算单叶 Merkle root（合约验证用）</li>
          <li><code className="text-gray-300">USDT.approve(vault, amount)</code></li>
          <li><code className="text-gray-300">vault.depositForPayroll(root, USDT, amount)</code></li>
          <li>记录保存到服务端 DB（员工扫描用）</li>
        </ol>
      </section>
    </main>
  );
}
