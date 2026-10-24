"use server";

import { getAccess } from "@/lib/auth/session";
import { loadReference } from "@/lib/db/reference";
import { dmyToIso } from "@/lib/format";
import { coa } from "@/lib/rules/coa";
import { MAX_XLSX_BYTES, readWorkbook, XlsxError } from "@/lib/db/import/xlsx";
import { parseOpeningWorkbook, planOpeningImport, type ImportIssue } from "@/lib/db/import/opening";

/**
 * นำเข้ายอดตั้งต้น — **รอบนี้พรีวิวอย่างเดียว ไม่เขียนอะไรลงฐานข้อมูล**
 *
 * อ่านไฟล์ → ตรวจทั้งไฟล์ → ส่งสิ่งที่ "จะลง" กลับมาให้ผู้ใช้ดู · ไม่เก็บไฟล์ ไม่เรียก `fn_post_entry`
 * (ลงจริงต้องมีประเภทรายการ "ยอดตั้งต้น" ในตารางกฎ + หลักยึดฝั่ง DB ก่อน · ดู `OPENING_POSTING_READY`)
 *
 * ผู้ถือและบัญชีธนาคารอ่านจาก DB ตาม session ของผู้ใช้ (RLS) — ไม่รับจากไฟล์หรือจากหน้าจอ
 */

export type PreviewJournalLine = { code: string; name: string; bank: string | null; debit: number; credit: number };
export type PreviewOwner = {
  ownerName: string;
  assets: number;
  liabilities: number;
  equity: number;
  lines: PreviewJournalLine[];
};
export type PreviewLot = { ownerName: string; kind: string; name: string; boughtOn: string; units: number; cost: number; coaCode: string };

export type OpeningPreview =
  | {
      ok: true;
      cutoff: string;
      fingerprint: string;
      owners: PreviewOwner[];
      lots: PreviewLot[];
      warnings: string[];
      totals: { owners: number; assets: number; liabilities: number; equity: number; lines: number };
    }
  | { ok: false; message: string; issues: ImportIssue[] };

const fail = (message: string, issues: ImportIssue[] = []): OpeningPreview => ({ ok: false, message, issues });

export async function previewOpeningImport(formData: FormData): Promise<OpeningPreview> {
  const access = await getAccess();
  if (!access.user) return fail("เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่");
  if (!access.permissions.has("settings.manage")) return fail("ไม่มีสิทธิ์นำเข้ายอดตั้งต้น (ต้องมีสิทธิ์ตั้งค่าระบบ)");

  const cutoff = dmyToIso(String(formData.get("cutoff") ?? ""));
  if (!cutoff) return fail("วันตัดยอดอ่านไม่ได้ — ใส่เป็น วว/ดด/ปปปป เช่น 31/10/2026 (ระบบไม่เดาวันให้)");

  const file = formData.get("file");
  if (!(file instanceof File) || file.size === 0) return fail("ยังไม่ได้เลือกไฟล์ — เลือกไฟล์ Excel (.xlsx) ของยอดตั้งต้น");
  if (!/\.xlsx$/i.test(file.name)) return fail("รับเฉพาะไฟล์ .xlsx (ไฟล์ที่บันทึกจาก Excel) — ไฟล์ .xls / .csv ยังไม่รองรับ");
  if (file.size > MAX_XLSX_BYTES) return fail(`ไฟล์ใหญ่เกินไป (เกิน ${MAX_XLSX_BYTES / 1024 / 1024} MB) — ไฟล์ยอดตั้งต้นจริงเล็กกว่านี้มาก`);

  const ref = await loadReference();
  if (!ref.ok) return fail(`โหลดรายชื่อผู้ถือ/บัญชีธนาคารไม่ได้ (${ref.error}) — ตรวจไฟล์ไม่ได้ถ้าไม่รู้ว่าผู้ถือคือใคร`);

  let wb;
  try {
    wb = readWorkbook(new Uint8Array(await file.arrayBuffer()));
  } catch (e) {
    return fail(e instanceof XlsxError ? e.message : "เปิดไฟล์ไม่ได้ — ไฟล์อาจเสียหรือไม่ใช่ Excel");
  }

  const result = parseOpeningWorkbook(wb, {
    owners: ref.ref.owners.map((o) => ({ id: o.id, name: o.name, status: o.status })),
    banks: ref.ref.banks.map((b) => ({ id: b.id, ownerId: b.ownerId, name: b.name, isActive: b.isActive })),
    cutoff,
  });
  if (!result.ok) {
    return fail(`ไฟล์นี้ยังนำเข้าไม่ได้ — พบปัญหา ${result.issues.length} จุด ไม่มีอะไรถูกบันทึก แก้ไฟล์แล้วอัปโหลดใหม่ทั้งไฟล์`, result.issues);
  }

  // รอบนี้ยังไม่ลงสมุด จึงยังไม่มี "ชุดเดิมในสมุด" ให้เทียบ — แผนจึงเป็น "ใหม่ทั้งหมด" เสมอ
  const plan = planOpeningImport(result.parsed, [], new Map());
  const bankName = new Map(ref.ref.banks.map((b) => [b.id, b.name]));
  return {
    ok: true,
    cutoff,
    fingerprint: plan.fingerprint,
    warnings: result.parsed.warnings,
    owners: result.parsed.journals.map((j) => ({
      ownerName: j.ownerName,
      assets: j.assets,
      liabilities: j.liabilities,
      equity: j.equity,
      lines: j.lines.map((l) => ({
        code: l.coaCode,
        name: coa(l.coaCode).nameTh,
        bank: l.bankAccountId ? bankName.get(l.bankAccountId) ?? null : null,
        debit: l.debit,
        credit: l.credit,
      })),
    })),
    lots: result.parsed.lots.map((l) => ({
      ownerName: l.ownerName,
      kind: l.kind,
      name: l.name,
      boughtOn: l.boughtOn,
      units: l.units,
      cost: l.cost,
      coaCode: l.coaCode,
    })),
    totals: { ...plan.totals, lines: result.parsed.journals.reduce((t, j) => t + j.lines.length, 0) },
  };
}
