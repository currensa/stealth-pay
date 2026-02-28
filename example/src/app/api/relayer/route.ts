import { NextRequest, NextResponse } from 'next/server';
import {
  createPublicClient,
  createWalletClient,
  http,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { vaultAbi } from '@/lib/vaultAbi';
import { VAULT_ADDRESS, SEPOLIA_CHAIN_ID, sepolia } from '@/lib/constants';
import { markClaimed } from '@/lib/db';

export interface ClaimRequest {
  stealthAddress: Hex;
  token: Hex;
  amount: string;        // decimal string of bigint
  recipient: Hex;
  feeAmount: string;     // decimal string of bigint
  deadline: string;      // decimal string of bigint (unix seconds)
}

export interface RelayerBody {
  req: ClaimRequest;
  signature: Hex;
  merkleProof: Hex[];
  root: Hex;
}

// POST /api/relayer
export async function POST(request: NextRequest) {
  const body = await request.json() as RelayerBody;
  const { req, signature, merkleProof, root } = body;

  const relayerKey = process.env.RELAYER_PRIVATE_KEY as Hex | undefined;
  const rpcUrl     = process.env.SEPOLIA_RPC_URL;

  if (!relayerKey || !rpcUrl) {
    return NextResponse.json(
      { error: 'Relayer not configured: missing RELAYER_PRIVATE_KEY or SEPOLIA_RPC_URL' },
      { status: 500 },
    );
  }

  if (!VAULT_ADDRESS) {
    return NextResponse.json(
      { error: 'NEXT_PUBLIC_VAULT_ADDRESS not set' },
      { status: 500 },
    );
  }

  const account = privateKeyToAccount(relayerKey);

  const publicClient = createPublicClient({
    chain: { ...sepolia, id: SEPOLIA_CHAIN_ID },
    transport: http(rpcUrl),
  });

  const walletClient = createWalletClient({
    account,
    chain: { ...sepolia, id: SEPOLIA_CHAIN_ID },
    transport: http(rpcUrl),
  });

  // Reconstruct typed ClaimRequest with bigint values
  const claimReq = {
    stealthAddress: req.stealthAddress,
    token:          req.token,
    amount:         BigInt(req.amount),
    recipient:      req.recipient,
    feeAmount:      BigInt(req.feeAmount),
    deadline:       BigInt(req.deadline),
  };

  try {
    const txHash = await walletClient.writeContract({
      address: VAULT_ADDRESS,
      abi: vaultAbi,
      functionName: 'claim',
      args: [claimReq, signature, merkleProof, root],
    });

    // Wait for confirmation
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });

    if (receipt.status !== 'success') {
      return NextResponse.json({ error: 'Transaction reverted', txHash }, { status: 400 });
    }

    // Mark as claimed in DB (direct call, no HTTP round-trip)
    markClaimed(req.stealthAddress, txHash);

    return NextResponse.json({ ok: true, txHash });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
