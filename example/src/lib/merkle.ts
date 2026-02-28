import { keccak256, encodeAbiParameters, type Address, type Hex } from 'viem';

/**
 * 计算单叶 Merkle root（root = leaf，proof = []）
 *
 * 叶子格式与合约一致：
 *   keccak256(bytes.concat(keccak256(abi.encode(stealthAddress, token, amount))))
 * 即对 abi.encode 结果做双重 keccak256（OZ 标准叶子哈希）。
 */
export function computeSingleLeafRoot(
  stealthAddress: Address,
  token: Address,
  amount: bigint,
): Hex {
  const innerHash = keccak256(encodeAbiParameters(
    [{ type: 'address' }, { type: 'address' }, { type: 'uint256' }],
    [stealthAddress, token, amount],
  ));
  // bytes.concat(bytes32) → treated as raw 32 bytes; keccak256 of that
  return keccak256(innerHash);
}

/** 单叶树的 Merkle proof 为空数组 */
export const EMPTY_PROOF: Hex[] = [];
