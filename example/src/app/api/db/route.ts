import { NextRequest, NextResponse } from 'next/server';
import { readDb, writeDb, type PayrollRecord } from '@/lib/db';

export type { PayrollRecord };

// GET /api/db?metaPubKey=0x...  — returns unclaimed records for that key
// GET /api/db                   — returns all records (debug)
export async function GET(request: NextRequest) {
  const metaPubKey = request.nextUrl.searchParams.get('metaPubKey');
  const records = readDb();

  if (!metaPubKey) {
    return NextResponse.json(records);
  }

  const filtered = records.filter(
    r => r.metaPubKey.toLowerCase() === metaPubKey.toLowerCase() && !r.claimed,
  );
  return NextResponse.json(filtered);
}

// POST /api/db  — add a new payroll record
export async function POST(request: NextRequest) {
  const body = await request.json() as Omit<PayrollRecord, 'claimed' | 'createdAt'>;
  const records = readDb();

  const newRecord: PayrollRecord = {
    ...body,
    claimed: false,
    createdAt: Date.now(),
  };

  records.push(newRecord);
  writeDb(records);

  return NextResponse.json({ ok: true, record: newRecord }, { status: 201 });
}

// PATCH /api/db  — mark a record as claimed
export async function PATCH(request: NextRequest) {
  const { stealthAddress, txHash } = await request.json() as { stealthAddress: string; txHash: string };
  const records = readDb();

  const idx = records.findIndex(
    r => r.stealthAddress.toLowerCase() === stealthAddress.toLowerCase(),
  );
  if (idx === -1) {
    return NextResponse.json({ error: 'record not found' }, { status: 404 });
  }

  records[idx].claimed = true;
  records[idx].txHash  = txHash;
  writeDb(records);

  return NextResponse.json({ ok: true });
}
