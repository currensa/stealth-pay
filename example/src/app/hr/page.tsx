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

type Status = 'idle' | 'checking' | 'approving' | 'depositing' | 'saving' | 'done' | 'error';

/** 链上存款成功后、DB 写入前的中间态，用于 DB 失败重试 */
interface PendingRecord {
  metaPubKey: string;
  stealthAddress: string;
  ephemeralPublicKey: string;
  merkleRoot: string;
  amount: string;
  token: string;
  depositTxHash: string;
}

const STATUS_LABEL: Record<Status, string> = {
  idle:       '',
  checking:   '🔍 查询 allowance…',
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
  const [account, setAccount]       = useState<Hex | null>(null);
  const [metaPubKey, setMetaPubKey] = useState('');
  const [amountStr, setAmountStr]   = useState('');
  const [status, setStatus]         = useState<Status>('idle');
  const [txHash, setTxHash]         = useState('');
  const [errorMsg, setErrorMsg]     = useState('');
  // 链上成功但 DB 失败时保存的中间态，供重试
  const [pendingRecord, setPendingRecord] = useState<PendingRecord | null>(null);

  // ── 连接钱包 ────────────────────────────────────────────────────────────────
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
      if (parseInt(chainIdHex, 16) !== SEPOLIA_CHAIN_ID) await switchToSepolia();
      setAccount(addr);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : String(err));
    }
  }

  // ── DB 写入（可独立重试）────────────────────────────────────────────────────
  async function saveToDb(record: PendingRecord) {
    setStatus('saving');
    setErrorMsg('');
    try {
      const res = await fetch('/api/db', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          metaPubKey:        record.metaPubKey,
          stealthAddress:    record.stealthAddress,
          ephemeralPublicKey:record.ephemeralPublicKey,
          merkleRoot:        record.merkleRoot,
          amount:            record.amount,
          token:             record.token,
        }),
      });
      if (!res.ok) throw new Error(`DB 写入失败（${res.status}）`);
      setPendingRecord(null);
      setTxHash(record.depositTxHash);
      setStatus('done');
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : String(err));
      setStatus('error');
    }
  }

  // ── 执行发薪 ────────────────────────────────────────────────────────────────
  async function handleDeposit() {
    setErrorMsg('');
    setPendingRecord(null);
    setStatus('idle');

    const validPubKey = /^0x(04[0-9a-fA-F]{128}|0[23][0-9a-fA-F]{64})$/.test(metaPubKey);
    if (!validPubKey) {
      setErrorMsg('Meta 公钥格式错误。请先到「员工领薪」页连接钱包，复制蓝色框里的 0x04 开头公钥（132 字符）。');
      return;
    }
    if (!amountStr || isNaN(Number(amountStr)) || Number(amountStr) <= 0) {
      setErrorMsg('请输入有效金额');
      return;
    }
    if (!account) return;

    try {
      const chainIdHex: string = await window.ethereum.request({ method: 'eth_chainId' });
      if (parseInt(chainIdHex, 16) !== SEPOLIA_CHAIN_ID) await switchToSepolia();

      const walletClient = createWalletClient({
        account,
        chain: { ...sepolia, id: SEPOLIA_CHAIN_ID },
        transport: custom(window.ethereum),
      });
      const publicClient = createPublicClient({
        chain: { ...sepolia, id: SEPOLIA_CHAIN_ID },
        transport: http(process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ?? 'https://rpc.sepolia.org'),
      });

      // 临时密钥对
      const ephemeralPrivBytes = crypto.getRandomValues(new Uint8Array(32));
      const ephemeralPrivHex   = ('0x' + Array.from(ephemeralPrivBytes)
        .map(b => b.toString(16).padStart(2, '0')).join('')) as Hex;

      const { secp256k1 }  = await import('@noble/curves/secp256k1');
      const { bytesToHex } = await import('@noble/hashes/utils');
      const ephemeralPubBytes  = secp256k1.getPublicKey(ephemeralPrivBytes, false);
      const ephemeralPublicKey = ('0x' + bytesToHex(ephemeralPubBytes)) as Hex;

      const { stealthAddress } = computeStealthAddress(metaPubKey, ephemeralPrivHex);
      const amount     = parseUnits(amountStr, 18);
      const merkleRoot = computeSingleLeafRoot(stealthAddress as Hex, USDT_ADDRESS, amount);

      // ── Step 1: approve（先查 allowance，已够则跳过）────────────────────────
      setStatus('checking');
      const allowance = await publicClient.readContract({
        address: USDT_ADDRESS,
        abi: erc20Abi,
        functionName: 'allowance',
        args: [account, VAULT_ADDRESS],
      });

      if (allowance < amount) {
        setStatus('approving');
        const approveTx = await walletClient.writeContract({
          address: USDT_ADDRESS,
          abi: erc20Abi,
          functionName: 'approve',
          args: [VAULT_ADDRESS, amount],
        });
        await publicClient.waitForTransactionReceipt({ hash: approveTx });
      }

      // ── Step 2: depositForPayroll ───────────────────────────────────────────
      setStatus('depositing');
      const depositTx = await walletClient.writeContract({
        address: VAULT_ADDRESS,
        abi: vaultAbi,
        functionName: 'depositForPayroll',
        args: [merkleRoot, USDT_ADDRESS, amount],
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash: depositTx });
      if (receipt.status !== 'success') throw new Error('depositForPayroll 交易失败');

      // 链上已成功，先保存中间态（DB 失败时用于重试）
      const record: PendingRecord = {
        metaPubKey,
        stealthAddress,
        ephemeralPublicKey,
        merkleRoot,
        amount: amount.toString(),
        token:  USDT_ADDRESS,
        depositTxHash: depositTx,
      };
      setPendingRecord(record);

      // ── Step 3: 写入 DB ─────────────────────────────────────────────────────
      await saveToDb(record);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : String(err));
      setStatus('error');
    }
  }

  const isBusy = ['checking', 'approving', 'depositing', 'saving'].includes(status);

  return (
    <main className="mx-auto max-w-2xl px-6 py-16">
      <Link href="/" className="mb-8 inline-block text-sm text-gray-500 hover:text-gray-300">
        ← 返回首页
      </Link>

      <h1 className="mb-2 text-3xl font-bold text-white">HR 发薪控制台</h1>
      <p className="mb-10 text-gray-400">连接 HR 钱包，输入员工 Meta 公钥和金额，完成链上发薪</p>

      {!account ? (
        <>
          <button
            onClick={connectWallet}
            className="w-full rounded-xl bg-indigo-600 px-6 py-3 font-semibold text-white transition hover:bg-indigo-500"
          >
            连接 HR 钱包（MetaMask）
          </button>
          {errorMsg && (
            <div className="mt-4 rounded-lg border border-red-700 bg-red-900/30 p-4 text-sm text-red-300">
              {errorMsg}
            </div>
          )}
        </>
      ) : (
        <div className="space-y-6">
          {/* Account badge */}
          <div className="flex items-center justify-between rounded-xl border border-gray-800 bg-gray-900 px-5 py-4">
            <div>
              <p className="text-xs text-gray-500">当前 HR 账户（Sepolia）</p>
              <p className="mt-1 break-all font-mono text-sm text-gray-200">{account}</p>
            </div>
            <button
              onClick={() => { setAccount(null); setStatus('idle'); setErrorMsg(''); setPendingRecord(null); }}
              className="ml-4 shrink-0 text-xs text-gray-500 hover:text-gray-300"
            >
              切换
            </button>
          </div>

          {/* Payroll form */}
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
                disabled={isBusy}
                className="w-full rounded-lg border border-gray-700 bg-gray-800 px-4 py-2.5 text-sm text-gray-100 placeholder-gray-600 focus:border-indigo-500 focus:outline-none disabled:opacity-50"
              />
            </div>

            <div>
              <label className="mb-1 block text-sm font-medium text-gray-300">发薪金额（USDT）</label>
              <input
                type="number"
                value={amountStr}
                onChange={e => setAmountStr(e.target.value)}
                placeholder="例：1000"
                min="0"
                disabled={isBusy}
                className="w-full rounded-lg border border-gray-700 bg-gray-800 px-4 py-2.5 text-sm text-gray-100 placeholder-gray-600 focus:border-indigo-500 focus:outline-none disabled:opacity-50"
              />
            </div>

            {/* 进度指示 */}
            <div className="flex gap-2 text-xs">
              {(['checking', 'approving', 'depositing', 'saving'] as Status[]).map((s, i) => (
                <div key={s} className={`flex items-center gap-1 ${
                  status === s ? 'text-indigo-400' :
                  ['done'].includes(status) || (
                    ['checking','approving','depositing','saving'].indexOf(status) >
                    ['checking','approving','depositing','saving'].indexOf(s)
                  ) ? 'text-emerald-500' : 'text-gray-600'
                }`}>
                  {i > 0 && <span className="text-gray-700">→</span>}
                  <span>{['allowance', 'approve', 'deposit', 'DB'][i]}</span>
                </div>
              ))}
            </div>

            <button
              onClick={handleDeposit}
              disabled={isBusy}
              className="w-full rounded-xl bg-indigo-600 px-6 py-3 font-semibold text-white transition hover:bg-indigo-500 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {isBusy ? STATUS_LABEL[status] : '执行发薪'}
            </button>

            {/* 成功 */}
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

            {/* 链上成功但 DB 失败：显示恢复面板 */}
            {status === 'error' && pendingRecord && (
              <div className="rounded-lg border border-yellow-700 bg-yellow-900/20 p-4 text-sm">
                <p className="font-semibold text-yellow-300">
                  ⚠️ 链上存款已成功，但 DB 记录写入失败
                </p>
                <p className="mt-1 text-gray-400">
                  薪资已锁定在合约中（员工可提取），但服务端未记录临时公钥，员工侧暂时扫不到。
                  请点击下方重试，或保存以下信息手动恢复：
                </p>
                <div className="mt-3 space-y-1 break-all font-mono text-xs text-gray-500">
                  <p><span className="text-gray-400">depositTx:</span> {pendingRecord.depositTxHash}</p>
                  <p><span className="text-gray-400">stealthAddress:</span> {pendingRecord.stealthAddress}</p>
                  <p><span className="text-gray-400">ephemeralPubKey:</span> {pendingRecord.ephemeralPublicKey}</p>
                  <p><span className="text-gray-400">merkleRoot:</span> {pendingRecord.merkleRoot}</p>
                </div>
                <button
                  onClick={() => saveToDb(pendingRecord)}
                  className="mt-3 rounded-lg bg-yellow-700 px-4 py-1.5 text-sm font-semibold text-white hover:bg-yellow-600"
                >
                  重试写入 DB
                </button>
              </div>
            )}

            {/* 普通错误（无 pendingRecord）*/}
            {errorMsg && !pendingRecord && (
              <div className="rounded-lg border border-red-700 bg-red-900/30 p-4 text-sm text-red-300">
                {errorMsg}
              </div>
            )}
          </div>
        </div>
      )}

      <section className="mt-10 space-y-2 text-sm text-gray-500">
        <p className="font-medium text-gray-400">执行步骤：</p>
        <ol className="list-inside list-decimal space-y-1 pl-2">
          <li>连接 MetaMask HR 账户（Sepolia），网络不对自动切换</li>
          <li>查询当前 allowance，已足够则跳过 approve（避免重复签名）</li>
          <li>ECDH 推导 <code className="text-gray-300">stealthAddress</code></li>
          <li><code className="text-gray-300">USDT.approve(vault, amount)</code>（仅 allowance 不足时）</li>
          <li><code className="text-gray-300">vault.depositForPayroll(root, USDT, amount)</code></li>
          <li>写入服务端 DB（失败时可独立重试，不影响链上资金）</li>
        </ol>
      </section>
    </main>
  );
}
