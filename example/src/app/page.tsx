import Link from "next/link";

export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-12 px-6 py-24">
      {/* Logo / Title */}
      <div className="text-center">
        <h1 className="text-5xl font-bold tracking-tight text-white">
          Stealth<span className="text-indigo-400">Pay</span>
        </h1>
        <p className="mt-3 text-lg text-gray-400">
          Privacy-preserving payroll on Sepolia testnet
        </p>
      </div>

      {/* Role buttons */}
      <div className="flex w-full max-w-2xl flex-col gap-6 sm:flex-row">
        <Link
          href="/hr"
          className="flex flex-1 flex-col items-center justify-center gap-3 rounded-2xl border border-indigo-700 bg-indigo-900/40 p-10 transition hover:bg-indigo-800/60 hover:border-indigo-500"
        >
          <span className="text-4xl">🏢</span>
          <span className="text-2xl font-semibold text-indigo-300">HR 发薪</span>
          <span className="text-sm text-gray-400 text-center">
            生成隐身地址，存入薪资，注册 Merkle Root
          </span>
        </Link>

        <Link
          href="/employee"
          className="flex flex-1 flex-col items-center justify-center gap-3 rounded-2xl border border-emerald-700 bg-emerald-900/40 p-10 transition hover:bg-emerald-800/60 hover:border-emerald-500"
        >
          <span className="text-4xl">👤</span>
          <span className="text-2xl font-semibold text-emerald-300">员工领薪</span>
          <span className="text-sm text-gray-400 text-center">
            连接钱包，签名授权，通过 Relayer 无 Gas 提款
          </span>
        </Link>
      </div>

      {/* Footer note */}
      <p className="text-xs text-gray-600">
        Sepolia testnet · StealthPayVault demo · not for production use
      </p>
    </main>
  );
}
