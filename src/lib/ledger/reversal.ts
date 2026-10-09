/**
 * สร้างบรรทัดของ **ใบกลับรายการ** (reverse) จากรายการที่ post ไปแล้ว
 *
 * ความหมายของ void กับ reverse อยู่ที่ `docs/DECISIONS.md` D-097 — สรุป:
 *   งวดยังไม่ปิด → `void` ต้นฉบับทิ้ง ไม่ต้องมีใบกลับรายการ
 *   งวดปิดแล้ว  → ต้นฉบับยัง `posted` **นับต่อไป** แล้วลงใบกลับรายการวันที่ปัจจุบัน
 *                 ทั้งคู่นับ → สุทธิเป็นศูนย์ → งบเดือนที่ยื่นไปแล้วไม่ขยับ
 *
 * ============================================================
 * **สะท้อนบรรทัดที่เก็บไว้ ห้ามสร้างใหม่จากตารางกฎ**
 * ============================================================
 * จุดนี้คือหัวใจของไฟล์ และเป็นเหตุผลที่ไฟล์นี้ไม่เรียก `buildPosting()` เลย
 *
 * ตารางกฎเปลี่ยนได้ตามเวลา (08/10 เพิ่งเพิ่ม 1310/2310/1710 เข้าผังบัญชี)
 * ถ้าใบกลับรายการสร้างจาก "รันกฎของหมวดนั้นใหม่" มันจะได้คู่บัญชี **ของวันนี้**
 * ไม่ใช่คู่บัญชีที่ต้นฉบับใช้จริงเมื่อปีก่อน → สองใบหักกันไม่หมด
 * เหลือยอดค้างในบัญชีเก่าตลอดกาลโดยที่งบยังดูสมดุล (เพราะแต่ละใบสมดุลในตัว)
 *
 * ดังนั้นต้นทางของไฟล์นี้คือ **บรรทัดที่อ่านมาจาก `transaction_lines`**
 * ไม่ใช่ค่าที่ฟอร์มกรอก และไม่ใช่ `subCode` ของต้นฉบับ
 *
 * อีกข้อ: การสะท้อนคือ **คัดลอกค่า แล้วสลับข้าง** ไม่มีการคำนวณเลข
 * จึงไม่มีโอกาสปัดเศษเพี้ยน (ถ้าคำนวณใหม่จากยอดรวม เศษสตางค์จะไม่ลงตัวกับต้นฉบับ)
 *
 * ด่านฝั่ง DB ที่คู่กับไฟล์นี้: `supabase/migrations/20261009000000_reverse_integrity.sql`
 * ไฟล์นี้ทำให้ผู้ใช้เห็น error ที่อ่านรู้เรื่องก่อนกดบันทึก · **ไม่ใช่ตัวกั้นสุดท้าย**
 * ตัวกั้นสุดท้ายคือ trigger ที่อ่านบรรทัดต้นฉบับจาก DB มาเทียบเอง
 */
import { PostingError, type PostingLine, type PostingResult, type PostingTransaction } from "./types";
import { assertBalanced, assertLinesValid, round2, totalDebit } from "./guards";
import { isCashAccount } from "../rules/coa";
import type { IntercompanyNature } from "../rules/intercompany";

/** สถานะของรายการใน DB — ชนิดเดียวกับ `sri_os.txn_status` */
export type TxnStatus = "posted" | "void";

/**
 * รายการต้นฉบับหนึ่งใบ ตามที่ **อ่านมาจาก DB** (ไม่ใช่ตามที่ฟอร์มรู้)
 *
 * ทุกฟิลด์ **บังคับ** โดยตั้งใจ — ไม่มี optional เลย
 * เพราะฟิลด์ที่เว้นได้ ผู้เรียกจะเว้น แล้วด่านที่พึ่งฟิลด์นั้นก็ผ่านเงียบๆ
 * (บทเรียน `mace-windu` ข้อ 2: อย่าเชื่อฟิลด์ที่ผู้ใช้เว้นได้)
 */
export type ReversalSource = {
  /** id ของรายการต้นฉบับ → ไปเป็น `reverses_id` ของใบกลับรายการ */
  txnId: string;
  ownerId: string;
  status: TxnStatus;
  /** บรรทัดบัญชีที่เก็บอยู่จริงในสมุด */
  lines: PostingLine[];
  /** วันที่เอกสารของต้นฉบับ (YYYY-MM-DD) — ใช้กันการลงใบกลับรายการย้อนไปก่อนต้นฉบับ */
  docDate: string;
  /**
   * มีใบกลับรายการใบอื่นที่ **ยังไม่ถูก void** ชี้มาที่ใบนี้อยู่แล้วหรือไม่
   *
   * ผู้เรียกต้อง query มาให้ — เครื่องยนต์มองไม่เห็น DB
   * ถ้าเป็น true แล้วยังกลับรายการอีก = เครดิตซ้ำสองรอบ
   */
  hasLiveReversal: boolean;
  /** ผู้ถืออีกฝ่าย ถ้าต้นฉบับเป็นขาหนึ่งของรายการข้ามผู้ถือ */
  counterOwnerId?: string;
  intercompanyNature?: IntercompanyNature;
};

export type ReversalInput = {
  /**
   * รายการที่จะกลับ — **ข้ามผู้ถือต้องส่งมาครบทั้งสองขา**
   *
   * กฎ "1 transaction = 1 owner" ทำให้รายการข้ามผู้ถือเป็นสองใบคู่กัน
   * กลับข้างเดียวแล้วอีกข้างค้าง = ลูกหนี้/เจ้าหนี้ระหว่างกันไม่ตรงกันตลอดกาล
   */
  originals: ReversalSource[];
  /** เหตุผลที่กลับรายการ — บังคับ เพราะนี่คือร่องรอยที่ผู้สอบบัญชีจะถาม */
  reason: string;
  /**
   * วันที่เอกสารของใบกลับรายการ (YYYY-MM-DD) — **ไม่มีค่าตั้งต้น**
   *
   * D-097: งวดที่ปิดแล้วห้ามขยับ จึงลงใบกลับรายการด้วยวันที่ปัจจุบัน
   * เครื่องยนต์มองไม่เห็นว่างวดไหนปิด (ข้อมูลอยู่ใน DB) จึงบังคับได้แค่
   * **ห้ามย้อนไปก่อนวันที่ของต้นฉบับ** ซึ่งไม่ถูกต้องในทุกกรณี
   */
  docDate: string;
  /**
   * วันที่เงินเคลื่อนของใบกลับรายการ
   *
   * **บังคับเมื่อขาใดขาหนึ่งมีบรรทัดเงินสด และห้ามใส่เมื่อไม่มีเลย**
   * ถ้าปล่อยว่างตอนที่มีบรรทัดเงินสด งบดุลจะหักกันหมดแต่
   * **งบกระแสเงินสดค้างยอดนั้นตลอดกาล** (ยืนยันด้วยการรันจริง 09/10:
   * งบดุล 0.00 · งบกระแสเงินสด +5,000 ทั้งที่ทุกใบสมดุล)
   * ทางกลับกัน ใส่ตอนที่ไม่มีบรรทัดเงินสด = เงินสดผีที่ไม่มีเงินจริงเคลื่อน
   *
   * ของจริงบังคับที่ trigger (`20261009000001_cash_date_invariant`)
   * ที่นี่บังคับซ้ำเพื่อให้ผู้ใช้เห็นข้อความที่อ่านรู้เรื่องก่อนกดบันทึก
   */
  cashDate?: string;
};

/** ผลลัพธ์: ใบกลับรายการพร้อม `reverses_id` และวันที่ของแต่ละใบ */
export type ReversalTransaction = PostingTransaction & {
  reversesId: string;
  docDate: string;
  /**
   * null เมื่อขานี้ไม่มีบรรทัดเงินสด — **null ไม่ใช่ "ไม่รู้" แต่คือ "เงินยังไม่เคลื่อน"**
   * รายการข้ามผู้ถือมีได้ที่ขาหนึ่งมีเงินสดและอีกขาไม่มี จึงตัดสินทีละขา
   */
  cashDate: string | null;
  /** เหตุผลที่กลับรายการ — ลงคอลัมน์ `memo` ของ `transactions` */
  memo: string;
};

export type ReversalResult = Omit<PostingResult, "transactions"> & {
  transactions: ReversalTransaction[];
};

const fail = (msg: string): never => {
  throw new PostingError(msg);
};

/**
 * สะท้อนบรรทัดเดียว — สลับเดบิต/เครดิต **มิติอื่นคัดลอกทั้งหมด**
 *
 * `assetId` · `bankAccountId` · `cfCategory` ต้องตามมาด้วยเสมอ
 * ถ้าทิ้งไว้ รายงานจะเพี้ยนแบบที่หายาก:
 *   - ทิ้ง `cfCategory` → งบกระแสเงินสดเห็นขาจ่ายของต้นฉบับ แต่ไม่เห็นขากลับ
 *   - ทิ้ง `assetId`    → งบรายทรัพย์ยังแบกค่าใช้จ่ายที่กลับรายการไปแล้ว
 *   - ทิ้ง `bankAccountId` → ยอดตามบัญชีธนาคารไม่ตรงกับสเตทเมนต์
 * งบรวมยังสมดุลทั้งสามกรณี จึงไม่มีอะไรดังเตือน — ต้องสะท้อนให้ครบตั้งแต่ต้น
 */
function mirrorLine(src: PostingLine, index: number): PostingLine {
  const debit = round2(src.debit ?? 0);
  const credit = round2(src.credit ?? 0);

  // ตรงกับ check constraint `one_side_only` ของ `transaction_lines`
  // บรรทัดที่สองข้างเป็นศูนย์ลงไม่ได้อยู่แล้ว แต่ถ้าหลุดมาถึงที่นี่ก็สะท้อนไม่ได้
  if (!(debit > 0 && credit === 0) && !(credit > 0 && debit === 0)) {
    fail(
      `บรรทัดที่ ${index + 1} ของรายการต้นฉบับไม่ใช่เดบิตหรือเครดิตอย่างใดอย่างหนึ่ง ` +
        `(เดบิต ${debit} เครดิต ${credit}) — สะท้อนไม่ได้ ข้อมูลในสมุดผิดอยู่ก่อนแล้ว`,
    );
  }

  const mirrored: PostingLine = {
    coaCode: src.coaCode,
    debit: credit,
    credit: debit,
  };
  // คัดลอกมิติเฉพาะที่ต้นฉบับมี — ใส่ undefined ทิ้งไว้จะทำให้ JSON มีคีย์ว่าง
  // ซึ่งฝั่ง DB เทียบ multiset แล้วไม่ตรง (null vs ไม่มีคีย์)
  if (src.bankAccountId !== undefined) mirrored.bankAccountId = src.bankAccountId;
  if (src.assetId !== undefined) mirrored.assetId = src.assetId;
  if (src.cfCategory !== undefined) mirrored.cfCategory = src.cfCategory;
  return mirrored;
}

/** YYYY-MM-DD ที่เป็นวันที่จริง (2026-02-30 ต้องไม่ผ่าน) */
function assertDate(v: string | undefined, label: string): string {
  const t = (v ?? "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(t)) {
    fail(`${label} ต้องเป็นวันที่รูปแบบ YYYY-MM-DD (ได้ "${v ?? ""}")`);
  }
  // `new Date("2026-02-30")` เลื่อนเป็น 2026-03-02 โดยไม่โยน error
  // → เทียบข้อความกลับ ไม่งั้นวันที่ที่ไม่มีจริงจะถูกรับแล้วเลื่อนเงียบๆ
  const d = new Date(`${t}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== t) {
    fail(`${label} ไม่ใช่วันที่ที่มีอยู่จริง ("${t}")`);
  }
  return t;
}

/** ขานี้มีบรรทัดเงินสด/เงินฝากหรือไม่ — ใช้ `isCashAccount` ตัวเดียวกับที่ทั้งระบบใช้ */
function hasCashLine(lines: PostingLine[]): boolean {
  return lines.some((l) => isCashAccount(l.coaCode));
}

function assertSourceUsable(src: ReversalSource): void {
  if (!src.txnId) fail("ไม่มี id ของรายการต้นฉบับ — กลับรายการโดยไม่รู้ว่ากลับอะไรไม่ได้");
  if (!src.ownerId) fail(`รายการ ${src.txnId} ไม่มีผู้ถือ — กลับรายการไม่ได้`);
  assertDate(src.docDate, `วันที่เอกสารของรายการ ${src.txnId}`);

  // D-097 ด่าน 2: ต้นฉบับที่ void แล้วไม่นับในงบอยู่แล้ว
  // ถ้ายังลงใบกลับรายการที่ยังนับ สมุดจะผิดไป −ต้นฉบับ (ผิดเท่าตัวของยอดเดิม)
  if (src.status === "void") {
    fail(
      `รายการ ${src.txnId} ถูกยกเลิก (void) ไปแล้ว — กลับรายการอีกไม่ได้ ` +
        `เพราะมันไม่ถูกนับในงบอยู่แล้ว ถ้ากลับอีกจะกลายเป็นหักซ้ำ`,
    );
  }
  if (src.status !== "posted") {
    fail(`รายการ ${src.txnId} มีสถานะ "${String(src.status)}" ซึ่งกลับรายการไม่ได้`);
  }

  if (src.hasLiveReversal) {
    fail(
      `รายการ ${src.txnId} มีใบกลับรายการที่ยังมีผลอยู่แล้ว — กลับซ้ำจะทำให้หักสองรอบ ` +
        `ถ้าใบกลับรายการเดิมลงผิด ให้ยกเลิก (void) ใบนั้นก่อน`,
    );
  }

  if (src.lines.length < 2) {
    fail(
      `รายการ ${src.txnId} มีบรรทัดบัญชี ${src.lines.length} บรรทัด — ` +
        `รายการที่ลงสมุดแล้วต้องมีอย่างน้อยสองบรรทัด ข้อมูลที่อ่านมาไม่ครบ`,
    );
  }

  // ต้นฉบับที่ไม่สมดุลแปลว่าสิ่งที่อ่านมาไม่ใช่รายการที่ DB เก็บไว้จริง
  // (DB บังคับสมดุลด้วย constraint trigger) → สะท้อนต่อจะได้ใบที่ไม่สมดุลอีกใบ
  // **ปฏิเสธ ไม่ปัดให้ลงตัว** เพราะปัดคือเดา และเดาผิดแปลว่าตัวเลขผิดเงียบๆ
  try {
    assertBalanced(src.lines);
  } catch {
    fail(
      `บรรทัดของรายการ ${src.txnId} ที่อ่านมาไม่สมดุล ` +
        `(เดบิต ${totalDebit(src.lines)} ≠ เครดิต ${src.lines.reduce((s, l) => s + (l.credit ?? 0), 0)}) — ` +
        `ข้อมูลที่ส่งเข้ามาไม่ใช่รายการที่อยู่ในสมุด กลับรายการไม่ได้`,
    );
  }
}

/**
 * ข้ามผู้ถือต้องมาครบคู่ — ตรงกับ `fn_assert_intercompany_pair` ฝั่ง DB
 *
 * ขาที่ชี้ไปผู้ถืออีกคน ต้องมีอีกขาที่เป็นของผู้ถือคนนั้นและชี้กลับมา
 * ไม่ครบ = **ปฏิเสธ** ไม่ใช่เติมขาที่ขาดให้เอง เพราะเครื่องยนต์ไม่รู้ว่า
 * ขาที่ขาดไปนั้นในสมุดมีบรรทัดอะไรอยู่จริง
 */
function assertPairsComplete(originals: ReversalSource[]): void {
  const owners = new Set(originals.map((o) => o.ownerId));
  for (const src of originals) {
    if (!src.counterOwnerId) continue;
    if (!owners.has(src.counterOwnerId)) {
      fail(
        `รายการ ${src.txnId} เป็นขาหนึ่งของรายการข้ามผู้ถือ ` +
          `แต่ไม่ได้ส่งขาของผู้ถือ ${src.counterOwnerId} มาด้วย — ` +
          `กลับข้างเดียวจะทำให้ลูกหนี้/เจ้าหนี้ระหว่างกันไม่ตรงกันตลอดไป`,
      );
    }
  }
}

/**
 * สร้างใบกลับรายการของทุกใบที่ส่งมา
 *
 * ผู้เรียกต้องอ่านบรรทัดจาก `transaction_lines` ของต้นฉบับมาใส่ `lines`
 * และต้อง query `status` กับ `hasLiveReversal` มาด้วย (ดูหมายเหตุที่ `ReversalSource`)
 */
export function buildReversal(input: ReversalInput): ReversalResult {
  const originals = input.originals ?? [];
  if (originals.length === 0) {
    fail("ไม่ได้ระบุรายการที่จะกลับ");
  }

  const reason = (input.reason ?? "").trim();
  if (reason.length === 0) {
    fail(
      "ต้องใส่เหตุผลที่กลับรายการ — นี่คือสิ่งที่ผู้สอบบัญชีและสรรพากรจะถามว่า " +
        "ทำไมตัวเลขเดือนนั้นเปลี่ยน",
    );
  }

  const seen = new Set<string>();
  for (const src of originals) {
    if (seen.has(src.txnId)) {
      fail(`ส่งรายการ ${src.txnId} มาซ้ำสองครั้ง — จะได้ใบกลับรายการสองใบของรายการเดียว`);
    }
    seen.add(src.txnId);
    assertSourceUsable(src);
  }
  assertPairsComplete(originals);

  const docDate = assertDate(input.docDate, "วันที่ของใบกลับรายการ");

  // ย้อนไปก่อนวันที่ของต้นฉบับไม่ถูกต้องในทุกกรณี — เงินยังไม่เกิดในวันนั้น
  // (เครื่องยนต์บังคับได้แค่นี้ · "ต้องอยู่ในงวดที่ยังไม่ปิด" ต้องถามจาก DB)
  for (const src of originals) {
    if (docDate < src.docDate) {
      fail(
        `ใบกลับรายการลงวันที่ ${docDate} ซึ่งก่อนวันที่ของต้นฉบับ (${src.docDate}) — ` +
          `กลับรายการย้อนไปก่อนที่รายการจะเกิดไม่ได้`,
      );
    }
  }

  // ------------------------------------------------------------
  // cash_date: มีบรรทัดเงินสด ⟺ ต้องมีวันที่เงินเคลื่อน
  //
  // รูที่ยืนยันด้วยการรันจริง: ใบกลับรายการที่สะท้อนบรรทัดครบทุกมิติ แต่ไม่มี
  // cash_date ทำให้งบดุลหักกันหมด (0.00) ขณะที่งบกระแสเงินสดค้าง +5,000 ตลอดกาล
  // และไม่มีอะไรดังเตือน เพราะทุกใบสมดุลในตัวเอง
  // ------------------------------------------------------------
  const anyCash = originals.some((o) => hasCashLine(o.lines));
  const cashRaw = (input.cashDate ?? "").trim();

  if (anyCash && cashRaw.length === 0) {
    fail(
      "รายการนี้มีบรรทัดเงินสด/เงินฝาก ต้องระบุวันที่เงินเคลื่อนของใบกลับรายการ — " +
        "ถ้าไม่ระบุ งบดุลจะหักกันหมดแต่งบกระแสเงินสดจะค้างยอดนั้นไว้ตลอดกาล",
    );
  }
  if (!anyCash && cashRaw.length > 0) {
    fail(
      `รายการนี้ไม่มีบรรทัดเงินสดเลย (ค้างรับ-ค้างจ่าย) แต่ส่งวันที่เงินเคลื่อนมา (${cashRaw}) — ` +
        "ถ้ารับไว้ งบกระแสเงินสดจะนับเงินที่ไม่มีการเคลื่อนจริง",
    );
  }
  const cashDate = anyCash ? assertDate(cashRaw, "วันที่เงินเคลื่อนของใบกลับรายการ") : null;
  if (cashDate !== null && cashDate < docDate) {
    // เงินเคลื่อนก่อนวันที่เอกสารของใบเดียวกันไม่สมเหตุสมผล
    fail(`วันที่เงินเคลื่อน (${cashDate}) อยู่ก่อนวันที่เอกสารของใบกลับรายการ (${docDate})`);
  }

  const transactions: ReversalTransaction[] = originals.map((src) => {
    const lines = src.lines.map(mirrorLine);
    // ใบที่สะท้อนจากใบที่สมดุล ย่อมสมดุล — ตรวจซ้ำเพื่อให้ `mirrorLine`
    // ที่ถูกแก้ในอนาคตแล้วเผลอทำให้ไม่สมดุล ดังที่นี่ ไม่ใช่ที่ DB ของผู้ใช้
    assertLinesValid(lines);
    assertBalanced(lines);

    const txn: ReversalTransaction = {
      ownerId: src.ownerId,
      lines,
      reversesId: src.txnId,
      docDate,
      // ตัดสินทีละขา: ข้ามผู้ถือมีได้ที่ขาหนึ่งมีเงินสดและอีกขาไม่มี
      // ใส่ cash_date ให้ขาที่ไม่มีบรรทัดเงินสด = เงินสดผีของขานั้น
      cashDate: hasCashLine(lines) ? cashDate : null,
      memo: `กลับรายการของ ${src.txnId}: ${reason}`,
    };
    if (src.counterOwnerId !== undefined) txn.counterOwnerId = src.counterOwnerId;
    if (src.intercompanyNature !== undefined) txn.intercompanyNature = src.intercompanyNature;
    return txn;
  });

  const summary = [
    `กลับรายการ ${originals.length === 1 ? "1 รายการ" : `${originals.length} รายการที่ผูกกัน`}`,
    `เหตุผล: ${reason}`,
    ...transactions.map(
      (t) =>
        `ผู้ถือ ${t.ownerId} · กลับรายการ ${t.reversesId} · ` +
        `${t.lines.length} บรรทัด · ยอด ${totalDebit(t.lines).toLocaleString("th-TH", {
          minimumFractionDigits: 2,
        })}`,
    ),
    "ต้นฉบับยังอยู่ในสมุดและยังถูกนับ — ใบนี้เป็นขาที่ทำให้ยอดสุทธิเป็นศูนย์ (D-097)",
  ];

  return { transactions, summary };
}
