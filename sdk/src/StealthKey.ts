/**
 * StealthKey SDK
 *
 * ECDH 隐身地址推导，实现 EIP-5564 精神的链下密钥协议。
 *
 * 流程：
 *   员工：metaPrivKey → metaPubKey (公开给 HR)
 *   HR  ：ephemeralPrivKey + metaPubKey → stealthAddress / stealthPubKey
 *   员工：metaPrivKey + ephemeralPubKey → stealthPrivKey (可签名提款)
 *
 * 核心数学：
 *   sharedSecret = ECDH(privA, pubB) = privA · pubB = privB · pubA
 *   h            = keccak256(compress(sharedSecret)) mod n
 *   stealthPub   = metaPub + h·G          (点加法)
 *   stealthPriv  = (metaPriv + h) mod n   (标量加法)
 */

import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak_256 } from '@noble/hashes/sha3';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';

// secp256k1 曲线阶（群的阶 n）
const CURVE_ORDER: bigint = secp256k1.CURVE.n;

// ─── 内部工具 ────────────────────────────────────────────────────────────────

function strip0x(hex: string): string {
  return hex.startsWith('0x') ? hex.slice(2) : hex;
}

/** 任意长度 hex → 固定 32 字节 Uint8Array */
function to32Bytes(hex: string): Uint8Array {
  return hexToBytes(strip0x(hex).padStart(64, '0'));
}

/**
 * ECDH 共享密钥：scalar × point → 压缩字节（33 B）
 * 两端计算结果相同：ephemPriv · metaPub = metaPriv · ephemPub
 */
function sharedSecret(scalarHex: string, pubHex: string): Uint8Array {
  const point  = secp256k1.ProjectivePoint.fromHex(strip0x(pubHex));
  const scalar = BigInt('0x' + strip0x(scalarHex).padStart(64, '0'));
  return point.multiply(scalar).toRawBytes(true); // compressed 33 B
}

/** keccak256(sharedSecret) → 曲线标量 h（mod n） */
function sharedSecretToScalar(secret: Uint8Array): bigint {
  return BigInt('0x' + bytesToHex(keccak_256(secret))) % CURVE_ORDER;
}

/** 未压缩公钥 → 以太坊地址（小写 hex，含 0x 前缀） */
function pubBytesToAddress(uncompressed: Uint8Array): string {
  // 去掉 0x04 前缀，对 64 字节 x||y 做 keccak256，取最后 20 字节
  const hash = keccak_256(uncompressed.slice(1));
  return '0x' + bytesToHex(hash).slice(24);
}

// ─── 公开 API ────────────────────────────────────────────────────────────────

/**
 * 员工端：根据 meta 私钥生成 meta 公钥（未压缩格式，0x04 前缀）。
 * 员工将此公钥提交给 HR，HR 永远看不到私钥。
 */
export function getMetaPublicKey(metaPrivateKey: string): string {
  const privBytes = to32Bytes(metaPrivateKey);
  const pubBytes  = secp256k1.getPublicKey(privBytes, false); // 65 B uncompressed
  return '0x' + bytesToHex(pubBytes);
}

/**
 * HR 端：利用员工的 metaPublicKey 和本期临时私钥，
 * 计算员工本月的影子地址（stealthAddress）和对应公钥。
 *
 * @param metaPublicKey     员工提交的 meta 公钥（压缩或未压缩）
 * @param ephemeralPrivateKey HR 生成的一次性临时私钥（每次发薪随机生成）
 */
export function computeStealthAddress(
  metaPublicKey: string,
  ephemeralPrivateKey: string,
): { stealthAddress: string; stealthPublicKey: string } {
  // 1. ECDH：共享密钥 = ephemeralPriv · metaPub
  const secret = sharedSecret(ephemeralPrivateKey, metaPublicKey);

  // 2. h = keccak256(secret) mod n
  const h = sharedSecretToScalar(secret);

  // 3. stealthPub = metaPub + h·G（椭圆曲线点加法）
  const metaPoint    = secp256k1.ProjectivePoint.fromHex(strip0x(metaPublicKey));
  const stealthPoint = metaPoint.add(secp256k1.ProjectivePoint.BASE.multiply(h));
  const stealthPub   = stealthPoint.toRawBytes(false); // uncompressed 65 B

  return {
    stealthPublicKey: '0x' + bytesToHex(stealthPub),
    stealthAddress:   pubBytesToAddress(stealthPub),
  };
}

/**
 * 员工端：利用 meta 私钥和 HR 发布的临时公钥，
 * 恢复出能签名提款的影子私钥。
 *
 * @param metaPrivateKey    员工的 meta 私钥
 * @param ephemeralPublicKey HR 在链上/数据库中公布的临时公钥
 */
export function recoverStealthPrivateKey(
  metaPrivateKey: string,
  ephemeralPublicKey: string,
): string {
  // 1. ECDH：共享密钥 = metaPriv · ephemeralPub（与 HR 侧结果相同）
  const secret = sharedSecret(metaPrivateKey, ephemeralPublicKey);

  // 2. h = keccak256(secret) mod n
  const h = sharedSecretToScalar(secret);

  // 3. stealthPriv = (metaPriv + h) mod n（标量加法）
  const metaPrivBigInt  = BigInt('0x' + strip0x(metaPrivateKey).padStart(64, '0'));
  const stealthPrivBigInt = (metaPrivBigInt + h) % CURVE_ORDER;

  return '0x' + stealthPrivBigInt.toString(16).padStart(64, '0');
}
