import { describe, it, expect } from 'vitest';
import { getRandomValues } from 'node:crypto';
import { privateKeyToAccount } from 'viem/accounts';
import {
  getMetaPublicKey,
  computeStealthAddress,
  recoverStealthPrivateKey,
} from '../src/StealthKey.js';

/** 生成随机的 32 字节私钥 (hex) */
function randomPrivKey(): `0x${string}` {
  const bytes = new Uint8Array(32);
  getRandomValues(bytes);
  return `0x${Buffer.from(bytes).toString('hex')}`;
}

describe('StealthKey SDK — ECDH 隐身密钥推导', () => {
  it('员工推导的影子私钥与 HR 计算的影子地址完全吻合', () => {
    // ── 员工端：生成 meta 密钥对 ──
    const metaPrivKey = randomPrivKey();
    const metaPubKey  = getMetaPublicKey(metaPrivKey);

    // ── HR 端：生成本月临时密钥对，计算员工影子地址 ──
    const ephemeralPrivKey = randomPrivKey();
    const ephemeralPubKey  = getMetaPublicKey(ephemeralPrivKey); // ephemeral public key

    const { stealthAddress, stealthPublicKey } = computeStealthAddress(
      metaPubKey,
      ephemeralPrivKey,
    );

    // ── 员工端：持有 metaPrivKey + HR 告知的 ephemeralPubKey，恢复影子私钥 ──
    const stealthPrivKey = recoverStealthPrivateKey(metaPrivKey, ephemeralPubKey);

    // ── 断言 1：影子私钥派生的公钥 == HR 计算的影子公钥 ──
    const derivedPubKey = getMetaPublicKey(stealthPrivKey);
    expect(derivedPubKey.toLowerCase()).toBe(
      stealthPublicKey.toLowerCase(),
      '员工推导的 stealthPubKey 应与 HR 计算的完全一致',
    );

    // ── 断言 2：影子私钥派生的以太坊地址 == HR 打算打款的 stealthAddress ──
    const derivedAddress = privateKeyToAccount(stealthPrivKey).address;
    expect(derivedAddress.toLowerCase()).toBe(
      stealthAddress.toLowerCase(),
      '影子私钥对应的以太坊地址应与 HR 计算的 stealthAddress 完全一致',
    );
  });

  it('不同 ephemeral key 生成不同的影子地址（一次性隐私特性）', () => {
    const metaPubKey = getMetaPublicKey(randomPrivKey());

    const { stealthAddress: addr1 } = computeStealthAddress(metaPubKey, randomPrivKey());
    const { stealthAddress: addr2 } = computeStealthAddress(metaPubKey, randomPrivKey());

    expect(addr1.toLowerCase()).not.toBe(
      addr2.toLowerCase(),
      '不同临时密钥必须生成不同影子地址',
    );
  });

  it('getMetaPublicKey 输出为未压缩公钥（0x04 前缀，130 hex 字符）', () => {
    const pub = getMetaPublicKey(randomPrivKey());
    expect(pub).toMatch(/^0x04[0-9a-f]{128}$/i);
  });
});
