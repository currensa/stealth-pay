'use client';

import { useState } from 'react';
import Link from 'next/link';
import {
  keccak256,
  toBytes,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { recoverStealthPrivateKey, getMetaPublicKey } from '@/lib/stealthKey';
import { EMPTY_PROOF } from '@/lib/merkle';
import { SEPOLIA_CHAIN_ID } from '@/lib/constants';
import type { PayrollRecord } from '@/app/api/db/route';

declare global {
  interface Window {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ethereum?: any;
  }
}

type PageStatus = 'idle' | 'signing' | 'scanning' | 'claiming' | 'done' | 'error';

interface ClaimStatus {
  stealthAddress: string;
  status: 'pending' | 'success' | 'error';
  txHash?: string;
  error?: string;
}

const EIP712_DOMAIN = {
  name: 'StealthPay',
  version: '1',
  chainId: SEPOLIA_CHAIN_ID,
  verifyingContract: (process.env.NEXT_PUBLIC_VAULT_ADDRESS ?? '0x0000000000000000000000000000000000000000') as Hex,
} as const;

const CLAIM_TYPES = {
  ClaimRequest: [
    { name: 'stealthAddress', type: 'address' },
    { name: 'token',          type: 'address' },
    { name: 'amount',         type: 'uint256' },
    { name: 'recipient',      type: 'address' },
    { name: 'feeAmount',      type: 'uint256' },
    { name: 'deadline',       type: 'uint256' },
  ],
} as const;

/** Sign and return metaPrivKey from a wallet sign. Prompts the user once. */
async function deriveMetaPrivKey(addr: Hex): Promise<Hex> {
  const sig: Hex = await window.ethereum.request({
    method: 'personal_sign',
    params: ['StealthPay Identity v1', addr],
  });
  return keccak256(toBytes(sig));
}

export default function EmployeePage() {
  const [account, setAccount]     = useState<Hex | null>(null);
  const [metaPubKey, setMetaPubKey] = useState<string>('');
  const [records, setRecords]     = useState<PayrollRecord[]>([]);
  const [claimStatuses, setClaimStatuses] = useState<ClaimStatus[]>([]);
  const [pageStatus, setPageStatus] = useState<PageStatus>('idle');
  const [errorMsg, setErrorMsg]   = useState('');

  async function connectAndScan() {
    setErrorMsg('');
    if (!window.ethereum) {
      setErrorMsg('未检测到 MetaMask，请安装后重试');
      return;
    }

    try {
      // 1. 连接钱包
      setPageStatus('signing');
      const accounts: string[] = await window.ethereum.request({ method: 'eth_requestAccounts' });
      const addr = accounts[0] as Hex;
      setAccount(addr);

      // 检查网络
      const chainIdHex: string = await window.ethereum.request({ method: 'eth_chainId' });
      if (parseInt(chainIdHex, 16) !== SEPOLIA_CHAIN_ID) {
        setErrorMsg(`请切换到 Sepolia 测试网（chain ID ${SEPOLIA_CHAIN_ID}）`);
        setPageStatus('error');
        return;
      }

      // 2. 签名 → 确定性 metaPrivKey
      const metaPrivKey  = await deriveMetaPrivKey(addr);
      const derivedPubKey = getMetaPublicKey(metaPrivKey);
      setMetaPubKey(derivedPubKey);

      // 3. 扫描 DB
      setPageStatus('scanning');
      const res = await fetch(`/api/db?metaPubKey=${encodeURIComponent(derivedPubKey)}`);
      if (!res.ok) throw new Error('DB 查询失败');
      const data: PayrollRecord[] = await res.json();

      setRecords(data);
      setClaimStatuses(data.map(r => ({ stealthAddress: r.stealthAddress, status: 'pending' })));
      setPageStatus('idle');
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : String(err));
      setPageStatus('error');
    }
  }

  async function claimAll() {
    if (!account || records.length === 0) return;
    setErrorMsg('');
    setPageStatus('claiming');

    // Re-sign to get metaPrivKey (user must approve once more)
    let metaPrivKey: Hex;
    try {
      metaPrivKey = await deriveMetaPrivKey(account);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : String(err));
      setPageStatus('error');
      return;
    }

    const updatedStatuses = [...claimStatuses];

    for (let i = 0; i < records.length; i++) {
      const record = records[i];
      const idx = updatedStatuses.findIndex(s => s.stealthAddress === record.stealthAddress);

      try {
        // 恢复隐身私钥
        const stealthPrivKey = recoverStealthPrivateKey(metaPrivKey, record.ephemeralPublicKey) as Hex;
        const stealthAccount = privateKeyToAccount(stealthPrivKey);

        // 校验地址一致性（可选，帮助调试）
        if (stealthAccount.address.toLowerCase() !== record.stealthAddress.toLowerCase()) {
          throw new Error(`隐身地址不匹配：期望 ${record.stealthAddress}，实际 ${stealthAccount.address}`);
        }

        // 构造 ClaimRequest
        const deadline  = BigInt(Math.floor(Date.now() / 1000) + 3600); // +1 hour
        const amount    = BigInt(record.amount);
        const feeAmount = 0n;

        const claimReq = {
          stealthAddress: stealthAccount.address as Hex,
          token:          record.token as Hex,
          amount,
          recipient:      account,    // funds go to MetaMask account
          feeAmount,
          deadline,
        };

        // EIP-712 本地签名（隐身私钥，无需 MetaMask）
        const signature = await stealthAccount.signTypedData({
          domain: EIP712_DOMAIN,
          types: CLAIM_TYPES,
          primaryType: 'ClaimRequest',
          message: claimReq,
        });

        // POST /api/relayer
        const relayRes = await fetch('/api/relayer', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            req: {
              stealthAddress: claimReq.stealthAddress,
              token:          claimReq.token,
              amount:         claimReq.amount.toString(),
              recipient:      claimReq.recipient,
              feeAmount:      claimReq.feeAmount.toString(),
              deadline:       claimReq.deadline.toString(),
            },
            signature,
            merkleProof: EMPTY_PROOF,
            root:        record.merkleRoot as Hex,
          }),
        });

        const relayData = await relayRes.json();
        if (!relayRes.ok) throw new Error(relayData.error ?? '未知错误');

        updatedStatuses[idx] = {
          stealthAddress: record.stealthAddress,
          status: 'success',
          txHash: relayData.txHash,
        };
      } catch (err) {
        updatedStatuses[idx] = {
          stealthAddress: record.stealthAddress,
          status: 'error',
          error: err instanceof Error ? err.message : String(err),
        };
      }

      setClaimStatuses([...updatedStatuses]);
    }

    setPageStatus('done');
  }

  const pendingCount = claimStatuses.filter(s => s.status === 'pending').length;

  return (
    <main className="mx-auto max-w-2xl px-6 py-16">
      <Link href="/" className="mb-8 inline-block text-sm text-gray-500 hover:text-gray-300">
        ← 返回首页
      </Link>

      <h1 className="mb-2 text-3xl font-bold text-white">员工领薪端</h1>
      <p className="mb-10 text-gray-400">连接钱包，签名生成身份，查看并一键提取待领薪资</p>

      {!account ? (
        <button
          onClick={connectAndScan}
          disabled={pageStatus === 'signing' || pageStatus === 'scanning'}
          className="w-full rounded-xl bg-emerald-600 px-6 py-3 font-semibold text-white transition hover:bg-emerald-500 disabled:opacity-50"
        >
          {pageStatus === 'signing'  ? '⏳ 签名中…' :
           pageStatus === 'scanning' ? '⏳ 扫描记录中…' :
           '连接钱包并扫描薪资'}
        </button>
      ) : (
        <div className="space-y-6">
          {/* Account */}
          <div className="rounded-xl border border-gray-800 bg-gray-900 px-5 py-4">
            <p className="text-xs text-gray-500">当前账户</p>
            <p className="mt-1 break-all font-mono text-sm text-gray-200">{account}</p>
          </div>

          {/* Meta public key — share with HR */}
          {metaPubKey && (
            <div className="rounded-xl border border-indigo-800/50 bg-indigo-950/40 px-5 py-4">
              <p className="text-xs font-medium text-indigo-400">您的 Meta 公钥（分享给 HR）</p>
              <p className="mt-1 break-all font-mono text-xs text-gray-300">{metaPubKey}</p>
              <button
                onClick={() => navigator.clipboard.writeText(metaPubKey)}
                className="mt-2 text-xs text-indigo-400 hover:underline"
              >
                复制
              </button>
            </div>
          )}

          {/* Records */}
          {records.length === 0 ? (
            <div className="rounded-xl border border-gray-800 bg-gray-900 px-5 py-8 text-center text-gray-500">
              暂无待提取薪资记录
            </div>
          ) : (
            <div className="space-y-3">
              <div className="flex items-center justify-between">
                <p className="text-sm text-gray-400">找到 {records.length} 条薪资记录</p>
                {pendingCount > 0 && pageStatus !== 'claiming' && (
                  <button
                    onClick={claimAll}
                    className="rounded-lg bg-emerald-600 px-4 py-1.5 text-sm font-semibold text-white transition hover:bg-emerald-500"
                  >
                    一键提取全部（{pendingCount} 条）
                  </button>
                )}
                {pageStatus === 'claiming' && (
                  <span className="text-sm text-yellow-400">⏳ 提取中…</span>
                )}
              </div>

              {records.map((record, i) => {
                const cs = claimStatuses[i];
                return (
                  <div key={record.stealthAddress} className="rounded-xl border border-gray-800 bg-gray-900 p-5">
                    <div className="flex items-start justify-between gap-4">
                      <div className="min-w-0 flex-1">
                        <p className="text-sm text-gray-400">金额</p>
                        <p className="text-lg font-semibold text-white">
                          {(Number(record.amount) / 1e6).toFixed(2)} USDT
                        </p>
                        <p className="mt-2 break-all font-mono text-xs text-gray-600">
                          Stealth: {record.stealthAddress}
                        </p>
                      </div>
                      <div className="shrink-0 text-right">
                        {cs?.status === 'success' && (
                          <span className="rounded-full bg-emerald-900 px-2 py-0.5 text-xs text-emerald-400">✅ 已提取</span>
                        )}
                        {cs?.status === 'error' && (
                          <span className="rounded-full bg-red-900 px-2 py-0.5 text-xs text-red-400">❌ 失败</span>
                        )}
                        {cs?.status === 'pending' && (
                          <span className="rounded-full bg-gray-800 px-2 py-0.5 text-xs text-gray-400">待提取</span>
                        )}
                      </div>
                    </div>
                    {cs?.txHash && (
                      <a
                        href={`https://sepolia.etherscan.io/tx/${cs.txHash}`}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="mt-3 block break-all text-xs text-indigo-400 hover:underline"
                      >
                        Tx: {cs.txHash}
                      </a>
                    )}
                    {cs?.error && (
                      <p className="mt-2 text-xs text-red-400">{cs.error}</p>
                    )}
                  </div>
                );
              })}
            </div>
          )}

          <button onClick={connectAndScan} className="text-sm text-gray-500 hover:text-gray-300">
            重新扫描
          </button>
        </div>
      )}

      {errorMsg && (
        <div className="mt-6 rounded-lg border border-red-700 bg-red-900/30 p-4 text-sm text-red-300">
          {errorMsg}
        </div>
      )}

      <section className="mt-10 space-y-2 text-sm text-gray-500">
        <p className="font-medium text-gray-400">工作原理：</p>
        <ol className="list-inside list-decimal space-y-1 pl-2">
          <li>连接 MetaMask，<code className="text-gray-300">personal_sign(&quot;StealthPay Identity v1&quot;)</code></li>
          <li><code className="text-gray-300">keccak256(sig)</code> → 确定性 <code className="text-gray-300">metaPrivKey</code>（每次可重现）</li>
          <li>推导 <code className="text-gray-300">metaPubKey</code>，查询 DB</li>
          <li>对每条记录 ECDH 恢复 <code className="text-gray-300">stealthPrivKey</code></li>
          <li>构造 <code className="text-gray-300">ClaimRequest</code>，EIP-712 本地签名（隐身私钥，无需 MetaMask 确认）</li>
          <li>POST <code className="text-gray-300">/api/relayer</code> → Relayer 代发 Gas</li>
        </ol>
      </section>
    </main>
  );
}
