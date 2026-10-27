"use server";

import { revalidatePath } from "next/cache";
import { getAccess } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { loadReference } from "@/lib/db/reference";
import { dmyToIso } from "@/lib/format";
import { coa } from "@/lib/rules/coa";
import { refuseInactiveOwners } from "@/lib/db/post-entry";
import { MAX_XLSX_BYTES, readWorkbook, XlsxError, type Workbook } from "@/lib/db/import/xlsx";
import {
  detectCutoff,
  fingerprintOf,
  parseOpeningWorkbook,
  planOpeningImport,
  type ImportIssue,
  type ParsedOpening,
  type PlanAction,
} from "@/lib/db/import/opening";
import { canRegisterDirect } from "@/components/assets/asset-drafts";
import { assetCategoryOfCoa } from "@/lib/db/import/breakdown";
import { isPendingAssetId, prepareOpeningPosting, type OpeningProblem, type OwnerEvidence } from "@/lib/db/import/opening-post";
import { runOpeningImport, supabaseOpeningStore, type OpeningStore, type OwnerOutcome } from "@/lib/db/import/opening-run";
import type { Reference } from "@/lib/db/reference-types";

/**
 * นำเข้ายอดตั้งต้น — สองขั้น: **ตรวจ + ดูตัวอย่าง** (`previewOpeningImport`, ไม่เขียนอะไร) แล้ว **ยืนยันลงสมุด** (`confirmOpeningImport`)
 *
 * การลงจริงไม่ได้เขียนตารางเอง และไม่ได้ประกอบบรรทัดบัญชีที่นี่:
 *   - บรรทัดบัญชีมาจาก `buildPosting()` (ผ่าน `prepareOpeningPosting`) — หมวด `opn.*` จากตารางกฎ
 *   - การเขียนทั้งหมดไปผ่านประตู `fn_reimport_opening(owner, payload)` ของ DB ซึ่งอ่านชุดเดิมจากสมุดเอง เทียบเนื้อหา
 *     กลับรายการชุดเดิม ลงชุดใหม่ ในธุรกรรมเดียวต่อผู้ถือ (ห้าม DELETE · เนื้อเหมือนเดิม = ไม่เขียนอะไร)
 *
 * ขั้นยืนยัน **อ่านไฟล์ใหม่ทั้งหมดที่ server** (ไม่รับบรรทัดบัญชีจาก browser) แล้วเทียบ "รหัสตรวจเนื้อหา"
 * กับที่ผู้ใช้เห็นในหน้าตัวอย่าง — ไฟล์หรือวันตัดยอดเปลี่ยนไประหว่างนั้น = ปฏิเสธ
 *
 * ผู้ถือและบัญชีธนาคารอ่านจาก DB ตาม session ของผู้ใช้ (RLS) — ไม่รับจากไฟล์หรือจากหน้าจอ
 *
 * **ชีท "แจกแจงทรัพย์"** (ทรัพย์รายชิ้น · ต้นทุนรายชิ้น) รับได้ทั้งในไฟล์ยอดตั้งต้นเอง หรือแนบเป็นไฟล์แยกในช่อง `breakdownFile`
 * (ต้องมีทางใดทางหนึ่ง) · ทรัพย์ที่ยังไม่มีในทะเบียนจะถูกลงทะเบียนก่อน (ผ่าน `fn_apply_asset_draft` ทางเดียวกับหน้าทะเบียนทรัพย์)
 * แต่ **หลังจากตรวจทุกอย่างผ่านหมดแล้วเท่านั้น** (ลองประกอบรายการด้วย `buildPosting()` ตัวจริงมาก่อน) — ปัญหาที่รู้ล่วงหน้า
 * (ขาดหลักฐานนิติบุคคล · ยอดไม่ตรง ฯลฯ) จึงไม่ทิ้งทรัพย์เปล่าไว้ในทะเบียน
 */

export type PreviewJournalLine = { code: string; name: string; bank: string | null; debit: number; credit: number };
export type PreviewOwner = {
  ownerName: string;
  assets: number;
  liabilities: number;
  equity: number;
  lines: PreviewJournalLine[];
};
export type PreviewLot = {
  ownerName: string;
  kind: string;
  name: string;
  boughtOn: string;
  units: number;
  /** ต้นทุนเป็นบาท */
  cost: number;
  coaCode: string;
  currency: string;
  /** อัตราที่ใช้ (ล็อตสกุลต่างประเทศ) */
  fxRate: number | null;
  /** ยอดในสกุลเดิม (ล็อตสกุลต่างประเทศ) */
  amountOriginal: number | null;
  /** ทรัพย์ที่ล็อตนี้จะผูก — null = ยังหาไม่เจอ (ดู blockers) */
  assetLabel: string | null;
};
export type PreviewAsset = {
  ownerName: string;
  name: string;
  coaCode: string;
  coaName: string;
  cost: number;
  renovation: number;
  /** ทรัพย์ในทะเบียนที่จะผูก (รหัส · ชื่อ) · null = จะลงทะเบียนใหม่ */
  existing: string | null;
  /** "รหัสทรัพย์" ที่กรอกไว้แต่ไม่พบในทะเบียน (ระบบออกรหัสให้เอง ไม่ใช้รหัสที่พิมพ์) */
  typedCode: string | null;
  /** true = บัญชีนี้ไม่ใช่การลงทุน (เช่น เงินมัดจำจ่าย) ไม่ลงทะเบียนทรัพย์ — ลงเป็นบรรทัดรวมต่อบัญชี ชื่อรายการอยู่ใน memo */
  noAsset: boolean;
};
export type PreviewPlanItem = { ownerId: string; ownerName: string; action: PlanAction; note?: string };
export type PreviewEvidenceOwner = { id: string; name: string };

export type OpeningPreview =
  | {
      ok: true;
      cutoff: string;
      /** วันตัดยอดมาจากหัวชีทในไฟล์ (ผู้ใช้ไม่ได้ระบุ) */
      cutoffFromFile: boolean;
      fingerprint: string;
      owners: PreviewOwner[];
      lots: PreviewLot[];
      /** ทรัพย์รายชิ้นจากชีทแจกแจง — แต่ละชิ้นจะได้บรรทัดบัญชีของตัวเองพร้อม asset_id */
      assets: PreviewAsset[];
      warnings: string[];
      /** สิ่งที่ทำให้ยังกดยืนยันไม่ได้ (ผู้ถือ + ข้อความ) · ว่าง = พร้อมลงสมุด */
      blockers: OpeningProblem[];
      /** ผู้ถือที่เป็นนิติบุคคล — ต้องแนบหลักฐาน + ระบุผู้ติดต่อก่อนยืนยัน */
      evidenceOwners: PreviewEvidenceOwner[];
      /** สิ่งที่ครั้งนี้จะเกิดต่อผู้ถือ (เทียบกับยอดตั้งต้นที่อยู่ในสมุดตอนนี้) · null = อ่านสมุดไม่ได้ ไม่รู้ */
      plan: PreviewPlanItem[] | null;
      planError: string | null;
      /** บัญชีนี้มีสิทธิ์ลงสมุดหรือไม่ (ledger.approve) */
      canPost: boolean;
      totals: { owners: number; assets: number; liabilities: number; equity: number; lines: number };
    }
  | { ok: false; message: string; issues: ImportIssue[] };

export type OpeningConfirmOutcome =
  | { ok: true; results: OwnerOutcome[]; cutoff: string }
  | { ok: false; message: string; issues?: ImportIssue[]; problems?: OpeningProblem[]; results?: OwnerOutcome[] };

const failPreview = (message: string, issues: ImportIssue[] = []): OpeningPreview => ({ ok: false, message, issues });
const failConfirm = (message: string, extra: Partial<Extract<OpeningConfirmOutcome, { ok: false }>> = {}): OpeningConfirmOutcome => ({
  ok: false,
  message,
  ...extra,
});

/* ---------------------------------------------------------------- อ่านไฟล์ (ใช้ร่วมกันทั้งสองขั้น) */

type Read =
  | { ok: true; ref: Reference; parsed: ParsedOpening; cutoffFromFile: boolean }
  | { ok: false; message: string; issues: ImportIssue[] };

async function readInput(formData: FormData): Promise<Read> {
  const bad = (message: string, issues: ImportIssue[] = []): Read => ({ ok: false, message, issues });

  const file = formData.get("file");
  if (!(file instanceof File) || file.size === 0) return bad("ยังไม่ได้เลือกไฟล์ — เลือกไฟล์ Excel (.xlsx) ของยอดตั้งต้น");
  if (!/\.xlsx$/i.test(file.name)) return bad("รับเฉพาะไฟล์ .xlsx (ไฟล์ที่บันทึกจาก Excel) — ไฟล์ .xls / .csv ยังไม่รองรับ");
  if (file.size > MAX_XLSX_BYTES) return bad(`ไฟล์ใหญ่เกินไป (เกิน ${MAX_XLSX_BYTES / 1024 / 1024} MB) — ไฟล์ยอดตั้งต้นจริงเล็กกว่านี้มาก`);

  // ไฟล์แจกแจงทรัพย์ที่แนบแยก (ไม่บังคับ — ถ้าชีท "แจกแจงทรัพย์" อยู่ในไฟล์ยอดตั้งต้นแล้วไม่ต้องแนบ)
  const bfile = formData.get("breakdownFile");
  const hasBreakdownFile = bfile instanceof File && bfile.size > 0;
  if (hasBreakdownFile) {
    if (!/\.xlsx$/i.test(bfile.name)) return bad("ไฟล์แจกแจงทรัพย์รับเฉพาะ .xlsx (ไฟล์ที่บันทึกจาก Excel)");
    if (bfile.size > MAX_XLSX_BYTES) return bad(`ไฟล์แจกแจงทรัพย์ใหญ่เกินไป (เกิน ${MAX_XLSX_BYTES / 1024 / 1024} MB)`);
  }

  const ref = await loadReference();
  if (!ref.ok) return bad(`โหลดรายชื่อผู้ถือ/บัญชีธนาคารไม่ได้ (${ref.error}) — ตรวจไฟล์ไม่ได้ถ้าไม่รู้ว่าผู้ถือคือใคร`);

  let wb: Workbook;
  try {
    wb = readWorkbook(new Uint8Array(await file.arrayBuffer()));
  } catch (e) {
    return bad(e instanceof XlsxError ? e.message : "เปิดไฟล์ไม่ได้ — ไฟล์อาจเสียหรือไม่ใช่ Excel");
  }

  let breakdownWb: Workbook | null = null;
  if (hasBreakdownFile) {
    try {
      breakdownWb = readWorkbook(new Uint8Array(await bfile.arrayBuffer()));
    } catch (e) {
      return bad(e instanceof XlsxError ? `ไฟล์แจกแจงทรัพย์: ${e.message}` : "เปิดไฟล์แจกแจงทรัพย์ไม่ได้ — ไฟล์อาจเสียหรือไม่ใช่ Excel");
    }
  }

  // วันตัดยอด: ผู้ใช้ระบุ → ใช้ตามนั้น (ถ้าไม่ตรงกับในชีท parse จะปฏิเสธ) · เว้นว่าง → อ่านจากหัวชีท (ต้องตรงกันทุกชีท)
  const raw = String(formData.get("cutoff") ?? "").trim();
  let cutoff: string;
  let cutoffFromFile = false;
  if (raw === "") {
    const d = detectCutoff(wb);
    if (!d.ok) return bad(`อ่านวันตัดยอดจากไฟล์ไม่ได้ — พบปัญหา ${d.issues.length} จุด ไม่มีอะไรถูกบันทึก (หรือระบุวันตัดยอดเอง แต่ทุกชีทต้องเขียนวันเดียวกัน)`, d.issues);
    cutoff = d.cutoff;
    cutoffFromFile = true;
  } else {
    const iso = dmyToIso(raw);
    if (!iso) return bad("วันตัดยอดอ่านไม่ได้ — ใส่เป็น วว/ดด/ปปปป เช่น 31/10/2026 หรือเว้นว่างให้ระบบอ่านจากไฟล์ (ระบบไม่เดาวันให้)");
    cutoff = iso;
  }

  const result = parseOpeningWorkbook(
    wb,
    {
      owners: ref.ref.owners.map((o) => ({ id: o.id, name: o.name, status: o.status })),
      banks: ref.ref.banks.map((b) => ({ id: b.id, ownerId: b.ownerId, name: b.name, isActive: b.isActive, currency: b.currency })),
      cutoff,
    },
    breakdownWb
  );
  if (!result.ok) {
    return bad(`ไฟล์นี้ยังนำเข้าไม่ได้ — พบปัญหา ${result.issues.length} จุด ไม่มีอะไรถูกบันทึก แก้ไฟล์แล้วอัปโหลดใหม่ทั้งไฟล์`, result.issues);
  }
  return { ok: true, ref: ref.ref, parsed: result.parsed, cutoffFromFile };
}

async function openStore(ref: Reference, userId: string): Promise<{ ok: true; store: OpeningStore } | { ok: false; message: string }> {
  try {
    return { ok: true, store: supabaseOpeningStore(await createClient(), ref.coaCodeById, userId) };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
}

/* ---------------------------------------------------------------- ขั้นที่ 1 · ตรวจ + ตัวอย่าง */

export async function previewOpeningImport(formData: FormData): Promise<OpeningPreview> {
  const access = await getAccess();
  if (!access.user) return failPreview("เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่");
  if (!access.permissions.has("settings.manage")) return failPreview("ไม่มีสิทธิ์นำเข้ายอดตั้งต้น (ต้องมีสิทธิ์ตั้งค่าระบบ)");

  const read = await readInput(formData);
  if (!read.ok) return failPreview(read.message, read.issues);
  const { ref, parsed } = read;

  const opened = await openStore(ref, access.user.id);
  if (!opened.ok) return failPreview(opened.message);
  const store = opened.store;

  // ทรัพย์/อัตราแลกเปลี่ยนที่ล็อตต้องใช้ — อ่านสดจาก DB (อ่านไม่ได้ = กดยืนยันไม่ได้ ไม่ใช่เดา)
  const blockers: OpeningProblem[] = [];
  const lookups = await store.loadLookups(ref.owners.map((o) => o.id));
  let prepared: ReturnType<typeof prepareOpeningPosting> | null = null;
  if (!lookups.ok) {
    blockers.push({ message: `อ่านข้อมูลทรัพย์/อัตราแลกเปลี่ยนไม่ได้ (${lookups.error}) — ยังประกอบรายการลงสมุดไม่ได้` });
  } else {
    // createMissing: ทรัพย์ที่ยังไม่มีในทะเบียนไม่ใช่ปัญหาตอนดูตัวอย่าง (จะลงทะเบียนให้ตอนยืนยัน) แต่ต้องบอกผู้ใช้ให้ชัด
    prepared = prepareOpeningPosting(parsed, { ref, assets: lookups.assets, fxRates: lookups.fxRates, mode: "preview", createMissing: true });
    if (!prepared.ok) blockers.push(...prepared.problems);
    if (prepared.toCreate.length) {
      const names = prepared.toCreate.map((t) => t.item.name);
      if (!canRegisterDirect(access.permissions)) {
        blockers.push({
          message:
            `ต้องลงทะเบียนทรัพย์ใหม่ ${names.length} ชิ้นก่อนลงยอดตั้งต้น แต่บัญชีนี้ลงทะเบียนทรัพย์ตรงไม่ได้ (ต้องมีสิทธิ์จัดการทรัพย์และดูพอร์ตทั้งหมด) — ` +
            "ให้ผู้มีสิทธิ์ลงทะเบียนทรัพย์เหล่านี้ที่หน้าทะเบียนทรัพย์ก่อน หรือให้ผู้มีสิทธิ์เป็นคนนำเข้า",
        });
      }
    }
  }

  // เทียบกับยอดตั้งต้นที่อยู่ในสมุดตอนนี้ — ไว้บอกผู้ใช้ว่า "ใหม่ / ไม่เปลี่ยน / จะแทนที่ / จะถอน" (ประตูของ DB เป็นผู้ตัดสินจริง)
  let plan: PreviewPlanItem[] | null = null;
  let planError: string | null = null;
  const existing = await store.loadExisting();
  if (existing.ok) {
    const names = new Map(ref.owners.map((o) => [o.id, o.name]));
    plan = planOpeningImport(parsed, existing.entries, names).items.map((i) => ({
      ownerId: i.ownerId,
      ownerName: i.ownerName,
      action: i.action,
      note: i.note,
    }));
  } else {
    planError = existing.error;
  }

  const bankName = new Map(ref.banks.map((b) => [b.id, b.name]));
  const assetOfLot = prepared ? prepared.lotAssets : null;
  const evidenceOwners = prepared ? prepared.evidenceOwners : [];
  return {
    ok: true,
    cutoff: parsed.cutoff,
    cutoffFromFile: read.cutoffFromFile,
    fingerprint: fingerprintOf(parsed),
    warnings: parsed.warnings,
    blockers,
    evidenceOwners,
    plan,
    planError,
    canPost: access.permissions.has("ledger.approve"),
    owners: parsed.journals.map((j) => ({
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
    assets: parsed.assetItems.map((i) => {
      const a = prepared?.itemAssets.get(i);
      const noAsset = assetCategoryOfCoa(i.coaCode) === null;
      const isNew = !noAsset && (!a || isPendingAssetId(a.id));
      return {
        ownerName: i.ownerName,
        name: i.name,
        coaCode: i.coaCode,
        coaName: coa(i.coaCode).nameTh,
        cost: i.cost,
        renovation: i.renovation,
        existing: a && !isNew ? `${a.code} · ${a.name}` : null,
        typedCode: isNew ? i.assetCode : null,
        noAsset,
      };
    }),
    lots: parsed.lots.map((l) => {
      const a = assetOfLot?.get(l);
      return {
        ownerName: l.ownerName,
        kind: l.kind,
        name: l.name,
        boughtOn: l.boughtOn,
        units: l.units,
        cost: l.cost,
        coaCode: l.coaCode,
        currency: l.currency,
        fxRate: l.fxRate ?? null,
        amountOriginal: l.amountOriginal ?? null,
        assetLabel: a ? `${a.code} · ${a.name}` : null,
      };
    }),
    totals: {
      owners: parsed.journals.length,
      assets: parsed.journals.reduce((t, j) => t + j.assets, 0),
      liabilities: parsed.journals.reduce((t, j) => t + j.liabilities, 0),
      equity: parsed.journals.reduce((t, j) => t + j.equity, 0),
      lines: parsed.journals.reduce((t, j) => t + j.lines.length, 0),
    },
  };
}

/* ---------------------------------------------------------------- ขั้นที่ 2 · ยืนยันลงสมุด */

/** หลักฐาน/ผู้ติดต่อต่อผู้ถือ จาก browser — ตรวจรูปร่างก่อนใช้ (ไม่เชื่อชนิดข้อมูลที่ส่งมา) */
function readEvidence(raw: FormDataEntryValue | null, ref: Reference): { ok: true; evidence: Record<string, OwnerEvidence> } | { ok: false; message: string } {
  if (raw === null || raw === "") return { ok: true, evidence: {} };
  let parsed: unknown;
  try {
    parsed = JSON.parse(String(raw));
  } catch {
    return { ok: false, message: "ข้อมูลหลักฐานที่ส่งมาอ่านไม่ได้ — ยังไม่ได้บันทึกอะไร" };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { ok: false, message: "ข้อมูลหลักฐานที่ส่งมาผิดรูปแบบ — ยังไม่ได้บันทึกอะไร" };
  const out: Record<string, OwnerEvidence> = {};
  for (const [ownerId, v] of Object.entries(parsed as Record<string, unknown>)) {
    if (!ref.owners.some((o) => o.id === ownerId)) return { ok: false, message: "หลักฐานที่ส่งมาอ้างถึงผู้ถือที่ไม่มีในระบบ — ยังไม่ได้บันทึกอะไร" };
    const e = v as { attachments?: unknown; contactId?: unknown } | null;
    const attachments = Array.isArray(e?.attachments) ? e!.attachments.filter((x): x is string => typeof x === "string").slice(0, 50) : [];
    const contactId = typeof e?.contactId === "string" && e.contactId !== "" ? e.contactId : undefined;
    if (contactId && !ref.contacts.some((c) => c.id === contactId)) {
      return { ok: false, message: "ผู้ติดต่อที่เลือกไม่มีในระบบแล้ว — โหลดหน้าใหม่แล้วเลือกใหม่ · ยังไม่ได้บันทึกอะไร" };
    }
    out[ownerId] = { attachments, contactId };
  }
  return { ok: true, evidence: out };
}

export async function confirmOpeningImport(formData: FormData): Promise<OpeningConfirmOutcome> {
  const access = await getAccess();
  if (!access.user) return failConfirm("เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วลองอีกครั้ง ยังไม่ได้บันทึกอะไร");
  if (access.error) return failConfirm(`ตรวจสิทธิ์ไม่สำเร็จ ยังไม่ได้บันทึกอะไร (${access.error})`);
  if (!access.permissions.has("settings.manage")) return failConfirm("ไม่มีสิทธิ์นำเข้ายอดตั้งต้น (ต้องมีสิทธิ์ตั้งค่าระบบ) — ยังไม่ได้บันทึกอะไร");
  if (!access.permissions.has("ledger.approve")) {
    return failConfirm("บัญชีนี้ลงสมุดบัญชีโดยตรงไม่ได้ — ต้องมีสิทธิ์อนุมัติเข้าสมุด · ยังไม่ได้บันทึกอะไร");
  }

  // ต้องรู้ว่าผู้ใช้เห็นเนื้อหาอะไรในหน้าตัวอย่าง — ไม่มีรหัสตรวจ = ไม่รู้ว่ายืนยันอะไร
  const expected = String(formData.get("fingerprint") ?? "");
  if (!expected) return failConfirm("ไม่ได้รับรหัสตรวจเนื้อหาจากหน้าตัวอย่าง — ตรวจไฟล์และดูตัวอย่างก่อน แล้วค่อยยืนยัน · ยังไม่ได้บันทึกอะไร");

  const read = await readInput(formData);
  if (!read.ok) return failConfirm(`${read.message} · ยังไม่ได้บันทึกอะไร`, { issues: read.issues });
  const { ref, parsed } = read;
  if (fingerprintOf(parsed) !== expected) {
    return failConfirm("ไฟล์หรือวันตัดยอดที่ยืนยันไม่ตรงกับที่ตรวจและแสดงตัวอย่างไว้ — กดตรวจไฟล์และดูตัวอย่างใหม่อีกครั้ง · ยังไม่ได้บันทึกอะไร");
  }

  const ev = readEvidence(formData.get("evidence"), ref);
  if (!ev.ok) return failConfirm(ev.message);

  const opened = await openStore(ref, access.user.id);
  if (!opened.ok) return failConfirm(`${opened.message} · ยังไม่ได้บันทึกอะไร`);
  const store = opened.store;

  const lookups = await store.loadLookups(ref.owners.map((o) => o.id));
  if (!lookups.ok) return failConfirm(`อ่านข้อมูลทรัพย์/อัตราแลกเปลี่ยนไม่ได้ (${lookups.error}) · ยังไม่ได้บันทึกอะไร`);

  // engine ตัวจริง (buildPosting) — บังคับเอกสารนิติบุคคลครบ · ปัญหาใดๆ = ไม่เขียนอะไรเลยทั้งไฟล์
  // รอบแรกเป็น "ซ้อม": ทรัพย์ที่ยังไม่มีในทะเบียนใช้ตัวชั่วคราว เพื่อให้ทุกด่านของ buildPosting ทำงานก่อนที่จะเขียนอะไรลง DB
  const dry = prepareOpeningPosting(parsed, { ref, assets: lookups.assets, fxRates: lookups.fxRates, evidence: ev.evidence, mode: "post", createMissing: true });
  if (!dry.ok) {
    return failConfirm(`ลงสมุดไม่ได้ — พบปัญหา ${dry.problems.length} จุด ไม่มีอะไรถูกบันทึก แก้แล้วลองใหม่`, { problems: dry.problems });
  }

  // ลงทะเบียนทรัพย์ที่ยังไม่มี (ถ้ามี) แล้วอ่านทะเบียนใหม่ — รอบจริงต้องหาทรัพย์ครบทุกชิ้นจากทะเบียน ไม่ใช้ตัวชั่วคราว
  let assets = lookups.assets;
  if (dry.toCreate.length) {
    if (!canRegisterDirect(access.permissions)) {
      return failConfirm(
        `ต้องลงทะเบียนทรัพย์ใหม่ ${dry.toCreate.length} ชิ้นก่อนลงยอดตั้งต้น แต่บัญชีนี้ลงทะเบียนทรัพย์ตรงไม่ได้ (ต้องมีสิทธิ์จัดการทรัพย์และดูพอร์ตทั้งหมด) · ยังไม่ได้บันทึกอะไร`
      );
    }
    const requests = [];
    for (const t of dry.toCreate) {
      const cat = lookups.categories.find((c) => c.code === t.categoryCode);
      if (!cat) {
        return failConfirm(`ไม่พบหมวดทรัพย์ "${t.categoryCode}" ในฐานข้อมูล จึงลงทะเบียนทรัพย์ "${t.item.name}" ไม่ได้ · ยังไม่ได้บันทึกอะไร`);
      }
      requests.push({ ownerId: t.item.ownerId, name: t.item.name, categoryId: cat.id, classId: cat.classId });
    }
    const made = await store.createAssets(requests);
    if (!made.ok) {
      revalidatePath("/assets");
      return failConfirm(
        `${made.error} · ลงทะเบียนทรัพย์ไปแล้ว ${made.created.length} จาก ${requests.length} ชิ้น (ทรัพย์ที่ลงแล้วไม่มีต้นทุน ไม่กระทบงบ) — ยังไม่ได้ลงสมุดบัญชี · ` +
          "แก้เหตุแล้วอัปโหลดไฟล์เดิมซ้ำได้ ระบบจะใช้ทรัพย์ที่ลงทะเบียนไว้แล้วโดยจับคู่ด้วยชื่อ ไม่สร้างซ้ำ"
      );
    }
    revalidatePath("/assets");
    const again = await store.loadLookups(ref.owners.map((o) => o.id));
    if (!again.ok) {
      return failConfirm(`ลงทะเบียนทรัพย์แล้ว ${made.created.length} ชิ้น แต่อ่านทะเบียนใหม่ไม่ได้ (${again.error}) — ยังไม่ได้ลงสมุดบัญชี · อัปโหลดไฟล์เดิมซ้ำได้`);
    }
    assets = again.assets;
  }
  const prepared = prepareOpeningPosting(parsed, { ref, assets, fxRates: lookups.fxRates, evidence: ev.evidence, mode: "post" });
  if (!prepared.ok) {
    return failConfirm(
      `ลงสมุดไม่ได้ — พบปัญหา ${prepared.problems.length} จุด ไม่มีอะไรถูกบันทึกในสมุดบัญชี${dry.toCreate.length ? " (ทรัพย์ที่ลงทะเบียนไปแล้วอยู่ในทะเบียน ไม่มีต้นทุน ไม่กระทบงบ)" : ""} แก้แล้วลองใหม่`,
      { problems: prepared.problems }
    );
  }

  // ผู้ถือต้องใช้งานอยู่ (อ่านสดจาก DB ตอนนี้) — เช็คทุกใบที่จะส่ง
  for (const o of prepared.owners) {
    for (const entry of o.payload.entries) {
      const refused = refuseInactiveOwners(entry, ref.owners);
      if (refused) return failConfirm(refused);
    }
  }

  const run = await runOpeningImport(prepared.owners, store);
  revalidatePath("/ledger");
  revalidatePath("/dashboard");
  revalidatePath("/import");
  if (!run.allOk) {
    const failed = run.results.find((r) => r.status === "failed");
    return failConfirm(failed?.message ?? "ลงสมุดไม่สำเร็จ", { results: run.results });
  }
  return { ok: true, results: run.results, cutoff: parsed.cutoff };
}
