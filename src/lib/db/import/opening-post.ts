/**
 * ประกอบ "สิ่งที่จะลงสมุด" ของยอดตั้งต้น — **ทุกบรรทัดบัญชีมาจาก `buildPosting()`** ไม่ได้ประกอบในหน้าจอ
 *
 * ไฟล์นี้ไม่คิดคู่บัญชีเอง และไม่เขียน DB · มันทำสามอย่าง:
 *   1. แปลง "บรรทัดของไฟล์" (รหัสบัญชี + ยอด) เป็น `PostingInput` ของหมวด `opn.*` แล้วให้ engine ประกอบ
 *      ตารางเทียบรหัสบัญชี → หมวด **อ่านจากตารางกฎ** (`TX_TYPES` · หมวดที่แตะกำไรสะสม) ไม่พิมพ์ซ้ำในโค้ด (กฎเหล็กข้อ 5)
 *   2. ผูก **ทรัพย์** กับยอดหุ้น/ทอง/คริปโต และลงต่อทรัพย์หนึ่งใบ — ไม่งั้นด่านต้นทุนถัวเฉลี่ยของ DB
 *      ปฏิเสธการขายครั้งแรก (ต้นทุนในสมุดเป็นก้อนรวมที่ไม่รู้ว่าของทรัพย์ไหน)
 *   3. **เทียบกลับ** ว่าสิ่งที่ engine ประกอบมาตรงกับไฟล์ทุกรหัสบัญชี (รวมกำไรสะสมที่ engine เติมให้เป็นขาคู่)
 *      — ไม่ตรง = ปฏิเสธ ไม่ใช่ลงแล้วหวังว่าตรง
 *
 * หลักที่ยึด (บทเรียนข้อ 1, 3, 7):
 *  - รหัสบัญชีที่ตารางกฎยังไม่มีหมวด "ยอดยกมา" ให้ = **ปฏิเสธทั้งไฟล์** ไม่ข้าม ไม่ปัดเข้าบัญชีอื่น
 *    (ข้ามแล้วงบดุลของผู้ถือนั้นยังดุลเพราะกำไรสะสมถูกเติมน้อยลงตาม — **ยอดหายแล้วไม่มีใครรู้**)
 *  - ทรัพย์อ่านจากฐานข้อมูล (ผู้ถือ + รหัส/ชื่อ) ไม่เดา ไม่สร้างให้ ซ้ำกัน/ไม่พบ/สกุลไม่ตรง = ปฏิเสธ
 *  - อัตราแลกเปลี่ยนของล็อตต้องมีอยู่จริงในตารางอัตราและเท่ากับที่ประกาศ (DB ตรวจซ้ำที่ trigger)
 */

import { buildPosting, buildPostingDraft } from "@/lib/ledger/posting";
import { PostingError, type PostingInput, type PostingResult } from "@/lib/ledger/types";
import { RETAINED_EARNINGS_COA, coa } from "@/lib/rules/coa";
import { TX_TYPES, isOpeningBalanceSub, type SubCategory } from "@/lib/rules/tx-rules";
import { PayloadError, toPostEntryPayload, type PostEntryPayload } from "@/lib/db/post-entry";
import { makeResolver } from "@/lib/db/resolver";
import type { Reference } from "@/lib/db/reference-types";
import type { Lot, ParsedOpening } from "./opening";

/* ---------------------------------------------------------------- ชนิด */

/** ทรัพย์จาก `sri_os.assets` (คอลัมน์ที่เปิดให้อ่าน: ไม่มี ticker/units) */
export type OpeningAsset = { id: string; code: string; name: string; ownerId: string; status: string; currency: string };
/** อัตราจาก `sri_os.fx_rates` · บาทต่อหนึ่งหน่วย */
export type FxRateRow = { currency: string; rateDate: string; thbPerUnit: number };
/** หลักฐาน + ผู้ติดต่อของผู้ถือที่เป็นนิติบุคคล (กติกาเอกสาร `corporate_strict`) */
export type OwnerEvidence = { attachments: string[]; contactId?: string };

export type OpeningLotPayload = {
  asset_id: string;
  acquired_date: string;
  quantity: number;
  cost_thb: number;
  currency?: string;
  amount_original?: number;
  fx_rate?: number;
  fx_rate_date?: string;
  note?: string;
};

/** เนื้อหาที่ส่งเข้าประตู `fn_reimport_opening(owner, payload)` — สองช่องนี้เท่านั้นที่ประตูรับ */
export type OpeningGatePayload = { entries: PostEntryPayload[]; lots: OpeningLotPayload[] };

export type OwnerPosting = {
  ownerId: string;
  ownerName: string;
  payload: OpeningGatePayload;
  /** ไว้แสดงผล — ไม่ใช่ข้อมูลที่ส่งเข้า DB */
  lineCount: number;
};

export type OpeningProblem = { ownerName?: string; message: string };

export type PrepareEnv = {
  ref: Pick<Reference, "owners" | "banks">;
  assets: OpeningAsset[];
  fxRates: FxRateRow[];
  /** ownerId → หลักฐาน/ผู้ติดต่อ · ใช้เมื่อ `mode = post` กับผู้ถือที่เป็นนิติบุคคล */
  evidence?: Record<string, OwnerEvidence | undefined>;
  /**
   * `preview` = `buildPostingDraft()` (ยังไม่บังคับเอกสารนิติบุคคล — ผู้ใช้เห็นบรรทัดก่อนไปหาไฟล์)
   * `post`    = `buildPosting()` ตัวจริง — **ทางเดียวที่ใช้ตอนบันทึก**
   */
  mode: "preview" | "post";
};

export type PrepareResult =
  | { ok: true; owners: OwnerPosting[]; evidenceOwners: { id: string; name: string }[]; lotAssets: Map<Lot, OpeningAsset> }
  | { ok: false; problems: OpeningProblem[]; evidenceOwners: { id: string; name: string }[]; lotAssets: Map<Lot, OpeningAsset> };

/* ---------------------------------------------------------------- ตารางเทียบ (อ่านจากตารางกฎ) */

/**
 * รหัสบัญชี → หมวด "ยอดยกมา" · ตัดสินจากคู่บัญชีในตารางกฎ: หมวดที่แตะกำไรสะสม (`isOpeningBalanceSub`)
 * บัญชีที่หมวดนั้นลงคือ **ขาที่ไม่ใช่กำไรสะสม** (เช่น `opn.capital` ลง 3100)
 */
export function openingSubByAccount(): Map<string, SubCategory> {
  const type = TX_TYPES.find((t) => t.key === "opening");
  if (!type) throw new Error("ตารางกฎไม่มีประเภท 'opening' — sync ด้วย npm run sync:rules");
  const out = new Map<string, SubCategory>();
  for (const sub of type.subs) {
    if (!isOpeningBalanceSub(sub)) continue;
    const target = sub.dr === RETAINED_EARNINGS_COA ? sub.cr : sub.dr;
    if (out.has(target)) throw new Error(`ตารางกฎมีสองหมวดยอดยกมาที่ลงบัญชี ${target} (${out.get(target)!.code}, ${sub.code}) — เลือกให้ไม่ได้`);
    out.set(target, sub);
  }
  return out;
}

/* ---------------------------------------------------------------- ตัวช่วย */

const cents = (n: number) => Math.round(n * 100);
const norm = (s: string) => s.normalize("NFC").trim().toLowerCase();
const rateKey = (n: number) => n.toFixed(8);

type Resolved = { ok: true; asset: OpeningAsset } | { ok: false; message: string };

/** ทรัพย์ของล็อต: ผู้ถือเดียวกัน + รหัสหรือชื่อตรงกับ "ชื่อ/รหัส" ในชีท (ไม่เดา · ซ้ำ = ปฏิเสธ) */
function resolveAsset(lot: Lot, assets: OpeningAsset[]): Resolved {
  const key = norm(lot.name);
  const mine = assets.filter((a) => a.ownerId === lot.ownerId);
  const byCode = mine.filter((a) => norm(a.code) === key);
  const hits = byCode.length ? byCode : mine.filter((a) => norm(a.name) === key);
  const where = `ล็อต "${lot.name}" ของ ${lot.ownerName} (แถว ${lot.row})`;
  if (hits.length === 0) {
    return {
      ok: false,
      message:
        `${where}: ไม่พบทรัพย์ชื่อหรือรหัสนี้ของ ${lot.ownerName} ในระบบ — ต้องสร้างทรัพย์ก่อนแล้วอัปโหลดใหม่ ` +
        "(ยอดหุ้น/ทองต้องผูกกับทรัพย์รายตัว ไม่งั้นขายครั้งแรกจะถูกปฏิเสธ · ระบบไม่สร้างทรัพย์ให้เองและไม่เดาว่าเป็นตัวไหน) " +
        "ชื่อ/รหัสในชีทต้องตรงกับรหัสหรือชื่อของทรัพย์ทุกตัวอักษร",
    };
  }
  if (hits.length > 1) {
    return { ok: false, message: `${where}: มีทรัพย์ ${hits.length} รายการที่ชื่อ/รหัสตรงกัน (${hits.map((h) => h.code).join(", ")}) — เลือกให้ไม่ได้ ให้แก้รหัสทรัพย์ไม่ให้ซ้ำก่อน` };
  }
  const asset = hits[0];
  if (asset.status !== "active") {
    return { ok: false, message: `${where}: ทรัพย์ ${asset.code} สถานะ "${asset.status}" ไม่ใช่ที่ถืออยู่ — ลงยอดตั้งต้นเข้าทรัพย์ที่จำหน่ายแล้วไม่ได้` };
  }
  if (asset.currency !== lot.currency) {
    return {
      ok: false,
      message:
        `${where}: ทรัพย์ ${asset.code} เป็นสกุล ${asset.currency} แต่ล็อตในไฟล์เป็นสกุล ${lot.currency} — สกุลของล็อตต้องเป็นสกุลของทรัพย์ ` +
        "(ลงเป็นบาทเฉยๆ ต้นทุนบาทจะไม่มีใครรู้ว่ามาจากอัตราไหน)",
    };
  }
  return { ok: true, asset };
}

/**
 * วันของอัตราที่ล็อตสกุลต่างประเทศใช้ — ต้องเป็นแถวที่มีอยู่จริงใน `fx_rates` (DB บังคับด้วย foreign key)
 * และอัตราที่ผู้ใช้กรอกต้องเท่ากับอัตราที่ประกาศของวันนั้นพอดี
 *
 * ใช้อัตราของวันซื้อ · ถ้าวันซื้อไม่มีแถว ยอมใช้แถว **ก่อนหน้า** ไม่เกิน 10 วัน (วันหยุด) **เฉพาะเมื่ออัตราเท่ากับที่ผู้ใช้กรอก**
 * — ไม่เอาอัตราของตารางมาแทนค่าที่ผู้ใช้กรอก และไม่เอาอัตราของวันหลังวันซื้อ (DB ปฏิเสธ)
 */
function resolveRateDate(lot: Lot, fxRates: FxRateRow[]): { ok: true; date: string } | { ok: false; message: string } {
  const where = `ล็อต "${lot.name}" ของ ${lot.ownerName} (แถว ${lot.row})`;
  const mine = fxRates.filter((r) => r.currency === lot.currency && r.rateDate <= lot.boughtOn).sort((a, b) => b.rateDate.localeCompare(a.rateDate));
  const exact = mine.find((r) => r.rateDate === lot.boughtOn);
  if (exact && rateKey(exact.thbPerUnit) !== rateKey(lot.fxRate!)) {
    return { ok: false, message: `${where}: อัตรา ${lot.fxRate} ไม่ตรงกับตารางอัตราแลกเปลี่ยนของ ${lot.currency} วันที่ ${lot.boughtOn} (ประกาศไว้ ${exact.thbPerUnit}) — อัตราที่ใช้คิดต้นทุนต้องเป็นอัตราที่ประกาศไว้ ไม่ใช่ตัวเลขที่พิมพ์เอง` };
  }
  if (exact) return { ok: true, date: exact.rateDate };
  const cutoffMs = Date.parse(`${lot.boughtOn}T00:00:00Z`) - 10 * 86_400_000;
  const prior = mine.find((r) => Date.parse(`${r.rateDate}T00:00:00Z`) >= cutoffMs && rateKey(r.thbPerUnit) === rateKey(lot.fxRate!));
  if (prior) return { ok: true, date: prior.rateDate };
  return {
    ok: false,
    message:
      `${where}: ไม่มีอัตรา ${lot.currency} = ${lot.fxRate} ในตารางอัตราแลกเปลี่ยนของวันที่ ${lot.boughtOn} (หรือวันทำการก่อนหน้าไม่เกิน 10 วัน) — ` +
      "ให้ผู้ดูแลระบบเพิ่มอัตราของวันนั้นในตารางอัตราก่อน แล้วอัปโหลดใหม่ (ระบบไม่เดาอัตราและไม่ใช้อัตราคนละวัน)",
  };
}

/* ---------------------------------------------------------------- ตัวหลัก */

export function prepareOpeningPosting(parsed: ParsedOpening, env: PrepareEnv): PrepareResult {
  const problems: OpeningProblem[] = [];
  const owners: OwnerPosting[] = [];
  const evidenceOwners: { id: string; name: string }[] = [];
  const lotAssets = new Map<Lot, OpeningAsset>();
  const resolver = makeResolver(env.ref);
  const subByAccount = openingSubByAccount();
  const build = env.mode === "post" ? buildPosting : buildPostingDraft;
  const memo = `ยอดตั้งต้น ณ ${parsed.cutoff}`;

  // ผู้ถือที่ต้องคืนประตู: ทุกคนที่ใช้งานอยู่ (ไม่มียอด = entries ว่าง → ถ้าเคยนำเข้าไว้ ประตูจะกลับรายการชุดเดิม)
  for (const owner of env.ref.owners.filter((o) => o.status === "active")) {
    const journal = parsed.journals.find((j) => j.ownerId === owner.id);
    const fail = (message: string) => problems.push({ ownerName: owner.name, message });
    if (!journal) {
      owners.push({ ownerId: owner.id, ownerName: owner.name, payload: { entries: [], lots: [] }, lineCount: 0 });
      continue;
    }
    if (owner.policy === "corporate_strict") evidenceOwners.push({ id: owner.id, name: owner.name });
    const docs = owner.policy === "corporate_strict" ? env.evidence?.[owner.id] : undefined;

    type Planned = { input: PostingInput; cashDate: string | null };
    const planned: Planned[] = [];
    const base = (subCode: string, amount: number): PostingInput => ({
      typeKey: "opening",
      subCode,
      amount,
      ownerId: owner.id,
      memo,
      ...(docs?.attachments?.length ? { attachments: [...docs.attachments] } : {}),
      ...(docs?.contactId ? { contactId: docs.contactId } : {}),
    });

    // ---- บรรทัดของไฟล์ → หมวด ----
    let capital: Planned | null = null;
    for (const l of journal.lines) {
      const amount = Math.max(l.debit, l.credit);
      if (l.coaCode === RETAINED_EARNINGS_COA) continue; // ขาคู่ — engine เติมให้จากทุกหมวด แล้วเทียบกลับด้านล่าง
      if (l.coaCode === "1700" || l.coaCode === "1720") continue; // ลงต่อทรัพย์จากชีทรายล็อต ด้านล่าง
      const sub = subByAccount.get(l.coaCode);
      if (!sub) {
        fail(
          `บัญชี ${l.coaCode} ${coa(l.coaCode).nameTh} (${amount.toLocaleString("en-US")} บาท) ยังไม่มีหมวด "ยอดยกมา" ในตารางกฎ จึงลงสมุดผ่านหน้านี้ไม่ได้ — ` +
            "ระบบไม่ข้ามและไม่ปัดเข้าบัญชีอื่น (ข้ามแล้วยอดนี้หายจากงบดุลเงียบๆ) · ให้ผู้ดูแลตารางกฎเพิ่มหมวดยอดยกมาของบัญชีนี้ก่อน หรือเอาบรรทัดนี้ออกจากไฟล์"
        );
        continue;
      }
      const p: Planned = {
        input: { ...base(sub.code, amount), ...(l.bankAccountId ? { bankAccountId: l.bankAccountId } : {}) },
        // บรรทัดเงินสดต้องมีวันที่เงินเคลื่อน (ด่านฝั่ง DB) — ยอดยกมาใช้วันตัดยอด
        cashDate: l.bankAccountId ? parsed.cutoff : null,
      };
      // หมวดที่ลงบัญชีส่วนของเจ้าของ (แยกทุนตั้งต้นออกจากกำไรสะสม) ต้องเป็นใบสุดท้าย — ตารางกฎระบุไว้ที่ caution
      // ตัดสินจากชนิดบัญชีที่หมวดลง ไม่ใช่รหัสบัญชีหรือรหัสหมวด
      if (coa(l.coaCode).type === "equity") capital = p;
      else planned.push(p);
    }

    // ---- หุ้น/ทอง/คริปโต: ต่อทรัพย์หนึ่งใบ ผูก asset_id ----
    const lots = parsed.lots.filter((l) => l.ownerId === owner.id);
    const byAsset = new Map<string, { asset: OpeningAsset; code: "1700" | "1720"; lots: Lot[] }>();
    for (const lot of lots) {
      const r = resolveAsset(lot, env.assets);
      if (!r.ok) {
        fail(r.message);
        continue;
      }
      lotAssets.set(lot, r.asset);
      const g = byAsset.get(r.asset.id);
      if (g && g.code !== lot.coaCode) {
        fail(`ทรัพย์ ${r.asset.code} มีล็อตที่ลงคนละบัญชี (${g.code} กับ ${lot.coaCode}) — ทรัพย์หนึ่งชิ้นลงได้บัญชีเดียว ตรวจประเภทของล็อตในชีท`);
        continue;
      }
      if (g) g.lots.push(lot);
      else byAsset.set(r.asset.id, { asset: r.asset, code: lot.coaCode, lots: [lot] });
    }
    for (const g of byAsset.values()) {
      const sub = subByAccount.get(g.code);
      if (!sub) {
        fail(`บัญชี ${g.code} ${coa(g.code).nameTh} ยังไม่มีหมวด "ยอดยกมา" ในตารางกฎ`);
        continue;
      }
      const amount = g.lots.reduce((t, l) => t + cents(l.cost), 0) / 100;
      planned.push({ input: { ...base(sub.code, amount), assetId: g.asset.id }, cashDate: null });
    }
    if (capital) planned.push(capital);

    // ---- ให้ engine ประกอบ ----
    const entries: PostEntryPayload[] = [];
    const built: PostingResult[] = [];
    const engineErrors = new Map<string, string[]>();
    for (const p of planned) {
      try {
        const result = build(p.input, resolver);
        built.push(result);
        entries.push(toPostEntryPayload(p.input, result, { docDate: parsed.cutoff, cashDate: p.cashDate, source: "import" }));
      } catch (e) {
        if (!(e instanceof PostingError || e instanceof PayloadError)) throw e;
        engineErrors.set(e.message, [...(engineErrors.get(e.message) ?? []), p.input.subCode]);
      }
    }
    // ข้อความเดียวกันจากหลายหมวด (เช่น "นิติบุคคลต้องแนบหลักฐาน") แสดงครั้งเดียว
    for (const [message, subs] of engineErrors) fail(`${message} (หมวด ${[...new Set(subs)].join(", ")})`);

    // ---- เทียบกลับกับไฟล์: ทุกรหัสบัญชี (รวมกำไรสะสมที่ engine เติมเป็นขาคู่) ----
    const posted = new Map<string, { dr: number; cr: number }>();
    for (const r of built)
      for (const t of r.transactions)
        for (const l of t.lines) {
          const cur = posted.get(l.coaCode) ?? { dr: 0, cr: 0 };
          cur.dr += cents(l.debit);
          cur.cr += cents(l.credit);
          posted.set(l.coaCode, cur);
        }
    const wanted = new Map<string, { dr: number; cr: number }>();
    for (const l of journal.lines) {
      const cur = wanted.get(l.coaCode) ?? { dr: 0, cr: 0 };
      cur.dr += cents(l.debit);
      cur.cr += cents(l.credit);
      wanted.set(l.coaCode, cur);
    }
    const noProblemYet = !problems.some((p) => p.ownerName === owner.name);
    if (noProblemYet) {
      for (const code of new Set([...wanted.keys(), ...posted.keys()])) {
        const w = wanted.get(code) ?? { dr: 0, cr: 0 };
        const p = posted.get(code) ?? { dr: 0, cr: 0 };
        // ใช้ยอดสุทธิ (เดบิต − เครดิต) เพราะ 3300 ฝั่งไฟล์เป็นยอดสุทธิของผู้กรอก ส่วนของ engine สะสมจากทุกหมวด
        if (w.dr - w.cr !== p.dr - p.cr) {
          fail(
            `บัญชี ${code} ${coa(code).nameTh}: ไฟล์ระบุ ${((w.dr - w.cr) / 100).toLocaleString("en-US")} แต่รายการที่ระบบประกอบได้ ${((p.dr - p.cr) / 100).toLocaleString("en-US")} ` +
              "(เดบิตเป็นบวก เครดิตเป็นลบ) — ไม่ตรงกันจึงไม่ลงสมุด"
          );
        }
      }
    }

    // ---- ล็อต ----
    const lotPayloads: OpeningLotPayload[] = [];
    for (const lot of lots) {
      const asset = lotAssets.get(lot);
      if (!asset) continue; // ปัญหาถูกบันทึกไปแล้วตอนหาทรัพย์
      const row: OpeningLotPayload = {
        asset_id: asset.id,
        acquired_date: lot.boughtOn,
        quantity: lot.units,
        cost_thb: lot.cost,
        note: `ยอดตั้งต้น ณ ${parsed.cutoff} · ชีทรายล็อต แถว ${lot.row}`,
      };
      if (lot.currency !== "THB") {
        const d = resolveRateDate(lot, env.fxRates);
        if (!d.ok) {
          fail(d.message);
          continue;
        }
        Object.assign(row, { currency: lot.currency, amount_original: lot.amountOriginal, fx_rate: lot.fxRate, fx_rate_date: d.date });
      }
      lotPayloads.push(row);
    }
    // ผลรวมต้นทุนล็อต = ยอดที่ลงในสมุดต่อทรัพย์ (ทะเบียนย่อยกับสมุดต้องเล่าเรื่องเดียวกัน)
    // ตรวจเฉพาะเมื่อผู้ถือนี้ยังไม่มีปัญหาอื่น — ล็อตที่ตกไปเพราะปัญหาข้างบนจะทำให้ยอดไม่ตรงโดยธรรมชาติ ไม่ใช่ปัญหาใหม่
    for (const g of problems.some((p) => p.ownerName === owner.name) ? [] : byAsset.values()) {
      const inLedger = entries
        .filter((e) => e.asset_id === g.asset.id)
        .flatMap((e) => e.transactions.flatMap((t) => t.lines))
        .filter((l) => l.asset_id === g.asset.id)
        .reduce((t, l) => t + cents(l.debit) - cents(l.credit), 0);
      const inLots = lotPayloads.filter((l) => l.asset_id === g.asset.id).reduce((t, l) => t + cents(l.cost_thb), 0);
      if (entries.some((e) => e.asset_id === g.asset.id) && inLedger !== inLots) {
        fail(`ทรัพย์ ${g.asset.code}: ต้นทุนในสมุด ${(inLedger / 100).toLocaleString("en-US")} ไม่ตรงกับทะเบียนล็อต ${(inLots / 100).toLocaleString("en-US")} — ไม่ลงสมุด`);
      }
    }

    owners.push({
      ownerId: owner.id,
      ownerName: owner.name,
      payload: { entries, lots: lotPayloads },
      lineCount: entries.reduce((t, e) => t + e.transactions.reduce((u, x) => u + x.lines.length, 0), 0),
    });
  }

  // ผู้ถือที่ไฟล์มียอดแต่ไม่อยู่ในรายชื่อที่ใช้งานอยู่ — parse กันไว้แล้ว แต่ไม่ปล่อยให้ยอดหายเงียบๆ ถ้ามีหลุดมา
  for (const j of parsed.journals) {
    if (!env.ref.owners.some((o) => o.id === j.ownerId && o.status === "active")) {
      problems.push({ ownerName: j.ownerName, message: "ผู้ถือนี้ไม่ได้ใช้งานอยู่ในระบบ — ลงยอดตั้งต้นให้ไม่ได้" });
    }
  }

  if (problems.length) return { ok: false, problems, evidenceOwners, lotAssets };
  return { ok: true, owners, evidenceOwners, lotAssets };
}
