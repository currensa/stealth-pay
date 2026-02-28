export const VAULT_ADDRESS = process.env.NEXT_PUBLIC_VAULT_ADDRESS as `0x${string}`;
export const USDT_ADDRESS  = process.env.NEXT_PUBLIC_USDT_ADDRESS  as `0x${string}`;
export const SEPOLIA_CHAIN_ID = 11155111;

export const sepolia = {
  id: SEPOLIA_CHAIN_ID,
  name: 'Sepolia',
  network: 'sepolia',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: {
    default: { http: [process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ?? 'https://rpc.sepolia.org'] },
    public:  { http: ['https://rpc.sepolia.org'] },
  },
  blockExplorers: {
    default: { name: 'Etherscan', url: 'https://sepolia.etherscan.io' },
  },
} as const;
