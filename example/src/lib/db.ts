/**
 * Shared in-memory + file-persisted mock DB for payroll records.
 * Used by both api/db/route.ts and api/relayer/route.ts.
 */
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join } from 'path';

const DB_PATH = join(process.cwd(), 'db.json');

export interface PayrollRecord {
  metaPubKey: string;
  stealthAddress: string;
  ephemeralPublicKey: string;
  merkleRoot: string;
  amount: string;       // bigint serialised as decimal string
  token: string;
  claimed: boolean;
  txHash?: string;
  createdAt: number;
}

let _cache: PayrollRecord[] | null = null;

export function readDb(): PayrollRecord[] {
  if (_cache) return _cache;
  if (!existsSync(DB_PATH)) return (_cache = []);
  try {
    _cache = JSON.parse(readFileSync(DB_PATH, 'utf8')) as PayrollRecord[];
    return _cache;
  } catch {
    return (_cache = []);
  }
}

export function writeDb(records: PayrollRecord[]): void {
  _cache = records;
  writeFileSync(DB_PATH, JSON.stringify(records, null, 2), 'utf8');
}

export function markClaimed(stealthAddress: string, txHash: string): boolean {
  const records = readDb();
  const idx = records.findIndex(
    r => r.stealthAddress.toLowerCase() === stealthAddress.toLowerCase(),
  );
  if (idx === -1) return false;
  records[idx].claimed = true;
  records[idx].txHash  = txHash;
  writeDb(records);
  return true;
}
