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
  idle:       '',
  approving:  '⏳ 等待 approve 确认…',
  depositing: '⏳ 等待 depositForPayroll 确认…',
  saving:     '💾 保存记录中…',
  done:       '✅ 发薪成功！',
  error:      '❌ 出错了',
};

async function switchToSepolia() {
  await window.ethereum.request({
    method: 'wallet_switchEthereumChain',
    params: [{ chainId: `0x${SEPOLIA_CHAIN_ID.toString(16)}` }],
  });
}

export default function HRPage() {
  const [account, setAccount]   = useState<Hex | null>(null);
  const [metaPubKey, setMetaPubKey] = useState('');
  const [amountStr, setAmountStr]   = useState('');
  const [status, setStatus]         = useState<Status>('idle');
  const [txHash, setTxHash]         = useState('');
  const [errorMsg, setErrorMsg]     = useState('');

  // ── Step 1: connect wallet ──────────────────────────────────────────────────
  async function connectWallet() {
    setErrorMsg('');
    if (!window.ethereum) {
      setErrorMsg('未检测到 MetaMask，请安装后重试');
      return;
    }
    try {
      const accounts: string[] = await window.ethereum.request({ method: 'eth_requestAccounts' });
      const addr = accounts[0] as Hex;

      const chainIdHex: string = await window.ethereum.request({ method: 'eth_chainId' });
      if (parseInt(chainIdHex, 16) !== SEPOLIA_CHAIN_ID) {
        await switchToSepolia();
      }

      setAccount(addr);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : String(err));
    }
  }

  // ── Step 2: payroll ─────────────────────────────────────────────────────────
  async function handleDeposit() {
    setErrorMsg('');
    setStatus('idle');

    // 非压缩公钥 0x04 + 128 hex = 132 chars；压缩 0x02/0x03 + 64 hex = 68 chars
    const validPubKey = /^0x(04[0-9a-fA-F]{128}|0[23][0-9a-fA-F]{64})$/.test(metaPubKey);
    if (!validPubKey) {
      setErrorMsg(
        'Meta 公钥格式错误。请先到「员工领薪」页连接钱包，复制蓝色框里显示的 0x04 开头的公钥（132 字符）后粘贴到此处。',
      );
      return;
    }
    if (!amountStr || isNaN(Number(amountStr)) || Number(amountStr) <= 0) {
      setErrorMsg('请输入有效金额');
      return;
    }
    if (!account) return;

    try {
      // 确认网络未被切换
      const chainIdHex: string = await window.ethereum.request({ method: 'eth_chainId' });
      if (parseInt(chainIdHex, 16) !== SEPOLIA_CHAIN_ID) {
        await switchToSepolia();
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

      // 随机临时私钥（32 bytes）
      const ephemeralPrivBytes = crypto.getRandomValues(new Uint8Array(32));
      const ephemeralPrivHex = ('0x' + Array.from(ephemeralPrivBytes)
        .map(b => b.toString(16).padStart(2, '0')).join('')) as Hex;

      // 临时公钥（员工扫描用）
      const { secp256k1 } = await import('@noble/curves/secp256k1');
      const { bytesToHex } = await import('@noble/hashes/utils');
      const ephemeralPubBytes  = secp256k1.getPublicKey(ephemeralPrivBytes, false);
      const ephemeralPublicKey = ('0x' + bytesToHex(ephemeralPubBytes)) as Hex;

      // ECDH → stealthAddress
      const { stealthAddress } = computeStealthAddress(metaPubKey, ephemeralPrivHex);

      // ERC20Mock 使用 18 位精度（OZ 默认）
      const amount = parseUnits(amountStr, 18);

      // 单叶 Merkle root
      const merkleRoot = computeSingleLeafRoot(stealthAddress as Hex, USDT_ADDRESS, amount);

      // Approve
      setStatus('approving');
      const approveTx = await walletClient.writeContract({
        address: USDT_ADDRESS,
        abi: erc20Abi,
        functionName: 'approve',
        args: [VAULT_ADDRESS, amount],
      });
      await publicClient.waitForTransactionReceipt({ hash: approveTx });

      // DepositForPayroll
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

      // 写入 DB
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
        连接 HR 钱包，输入员工 Meta 公钥和金额，完成链上发薪
      </p>

      {/* Step 1 — connect wallet */}
      {!account ? (
        <button
          onClick={connectWallet}
          className="w-full rounded-xl bg-indigo-600 px-6 py-3 font-semibold text-white transition hover:bg-indigo-500"
        >
          连接 HR 钱包（MetaMask）
        </button>
      ) : (
        <div className="space-y-6">
          {/* Account badge */}
          <div className="flex items-center justify-between rounded-xl border border-gray-800 bg-gray-900 px-5 py-4">
            <div>
              <p className="text-xs text-gray-500">当前 HR 账户（Sepolia）</p>
              <p className="mt-1 break-all font-mono text-sm text-gray-200">{account}</p>
            </div>
            <button
              onClick={() => { setAccount(null); setStatus('idle'); setErrorMsg(''); }}
              className="ml-4 shrink-0 text-xs text-gray-500 hover:text-gray-300"
            >
              切换
            </button>
          </div>

          {/* Step 2 — payroll form */}
          <div className="space-y-5 rounded-2xl border border-gray-800 bg-gray-900 p-8">
            <div>
              <label className="mb-1 block text-sm font-medium text-gray-300">
                员工 Meta 公钥
                <span className="ml-2 text-xs text-gray-500">（从员工领薪页复制，0x04 开头，132 字符）</span>
              </label>
              <input
                type="text"
                value={metaPubKey}
                onChange={e => setMetaPubKey(e.target.value.trim())}
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
        </div>
      )}

      {/* Top-level connect error */}
      {!account && errorMsg && (
        <div className="mt-4 rounded-lg border border-red-700 bg-red-900/30 p-4 text-sm text-red-300">
          {errorMsg}
        </div>
      )}

      <section className="mt-10 space-y-2 text-sm text-gray-500">
        <p className="font-medium text-gray-400">执行步骤：</p>
        <ol className="list-inside list-decimal space-y-1 pl-2">
          <li>连接 MetaMask HR 账户（Sepolia），网络不对会自动提示切换</li>
          <li>生成随机 32 字节 <code className="text-gray-300">ephemeralPrivKey</code></li>
          <li>ECDH 推导 <code className="text-gray-300">stealthAddress</code>（只有员工能还原私钥）</li>
          <li>计算单叶 Merkle root</li>
          <li><code className="text-gray-300">USDT.approve(vault, amount)</code></li>
          <li><code className="text-gray-300">vault.depositForPayroll(root, USDT, amount)</code></li>
          <li>记录保存到服务端 DB（员工扫描用）</li>
        </ol>
      </section>
    </main>
  );
}
