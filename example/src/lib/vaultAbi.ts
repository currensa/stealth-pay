export const vaultAbi = [
  {
    "type": "constructor",
    "inputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "CLAIM_TYPEHASH",
    "inputs": [],
    "outputs": [{ "name": "", "type": "bytes32", "internalType": "bytes32" }],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "DOMAIN_SEPARATOR",
    "inputs": [],
    "outputs": [{ "name": "", "type": "bytes32", "internalType": "bytes32" }],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "batchClaim",
    "inputs": [
      {
        "name": "reqs",
        "type": "tuple[]",
        "internalType": "struct StealthPayVault.ClaimRequest[]",
        "components": [
          { "name": "stealthAddress", "type": "address", "internalType": "address" },
          { "name": "token", "type": "address", "internalType": "address" },
          { "name": "amount", "type": "uint256", "internalType": "uint256" },
          { "name": "recipient", "type": "address", "internalType": "address" },
          { "name": "feeAmount", "type": "uint256", "internalType": "uint256" },
          { "name": "deadline", "type": "uint256", "internalType": "uint256" }
        ]
      },
      { "name": "signatures", "type": "bytes[]", "internalType": "bytes[]" },
      { "name": "proofs", "type": "bytes32[][]", "internalType": "bytes32[][]" },
      { "name": "roots", "type": "bytes32[]", "internalType": "bytes32[]" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "claim",
    "inputs": [
      {
        "name": "req",
        "type": "tuple",
        "internalType": "struct StealthPayVault.ClaimRequest",
        "components": [
          { "name": "stealthAddress", "type": "address", "internalType": "address" },
          { "name": "token", "type": "address", "internalType": "address" },
          { "name": "amount", "type": "uint256", "internalType": "uint256" },
          { "name": "recipient", "type": "address", "internalType": "address" },
          { "name": "feeAmount", "type": "uint256", "internalType": "uint256" },
          { "name": "deadline", "type": "uint256", "internalType": "uint256" }
        ]
      },
      { "name": "signature", "type": "bytes", "internalType": "bytes" },
      { "name": "merkleProof", "type": "bytes32[]", "internalType": "bytes32[]" },
      { "name": "root", "type": "bytes32", "internalType": "bytes32" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "depositForPayroll",
    "inputs": [
      { "name": "merkleRoot", "type": "bytes32", "internalType": "bytes32" },
      { "name": "token", "type": "address", "internalType": "address" },
      { "name": "totalAmount", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "isClaimed",
    "inputs": [{ "name": "", "type": "address", "internalType": "address" }],
    "outputs": [{ "name": "", "type": "bool", "internalType": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "payrolls",
    "inputs": [{ "name": "", "type": "bytes32", "internalType": "bytes32" }],
    "outputs": [
      { "name": "employer", "type": "address", "internalType": "address" },
      { "name": "token", "type": "address", "internalType": "address" },
      { "name": "totalAmount", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "Claimed",
    "inputs": [
      { "name": "token", "type": "address", "indexed": true, "internalType": "address" },
      { "name": "stealthAddress", "type": "address", "indexed": true, "internalType": "address" },
      { "name": "recipient", "type": "address", "indexed": true, "internalType": "address" },
      { "name": "net", "type": "uint256", "indexed": false, "internalType": "uint256" }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PayrollDeposited",
    "inputs": [
      { "name": "merkleRoot", "type": "bytes32", "indexed": true, "internalType": "bytes32" },
      { "name": "employer", "type": "address", "indexed": true, "internalType": "address" },
      { "name": "token", "type": "address", "indexed": true, "internalType": "address" },
      { "name": "totalAmount", "type": "uint256", "indexed": false, "internalType": "uint256" }
    ],
    "anonymous": false
  },
  { "type": "error", "name": "AlreadyClaimed", "inputs": [] },
  { "type": "error", "name": "ArrayLengthMismatch", "inputs": [] },
  { "type": "error", "name": "ECDSAInvalidSignature", "inputs": [] },
  {
    "type": "error",
    "name": "ECDSAInvalidSignatureLength",
    "inputs": [{ "name": "length", "type": "uint256", "internalType": "uint256" }]
  },
  {
    "type": "error",
    "name": "ECDSAInvalidSignatureS",
    "inputs": [{ "name": "s", "type": "bytes32", "internalType": "bytes32" }]
  },
  { "type": "error", "name": "EthAmountMismatch", "inputs": [] },
  { "type": "error", "name": "EthTransferFailed", "inputs": [] },
  { "type": "error", "name": "FeeExceedsAmount", "inputs": [] },
  { "type": "error", "name": "InvalidMerkleProof", "inputs": [] },
  { "type": "error", "name": "InvalidRoot", "inputs": [] },
  { "type": "error", "name": "InvalidSignature", "inputs": [] },
  { "type": "error", "name": "ReentrancyGuardReentrantCall", "inputs": [] },
  {
    "type": "error",
    "name": "SafeERC20FailedOperation",
    "inputs": [{ "name": "token", "type": "address", "internalType": "address" }]
  },
  { "type": "error", "name": "SignatureExpired", "inputs": [] },
  { "type": "error", "name": "TokenMismatch", "inputs": [] }
] as const;

export const erc20Abi = [
  {
    "type": "function",
    "name": "approve",
    "inputs": [
      { "name": "spender", "type": "address" },
      { "name": "amount", "type": "uint256" }
    ],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "allowance",
    "inputs": [
      { "name": "owner", "type": "address" },
      { "name": "spender", "type": "address" }
    ],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "balanceOf",
    "inputs": [{ "name": "account", "type": "address" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "decimals",
    "inputs": [],
    "outputs": [{ "name": "", "type": "uint8" }],
    "stateMutability": "view"
  }
] as const;
