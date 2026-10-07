/**
 * ด่านตรวจร่วมของทุกเส้นทางที่สร้างรายการเงิน
 *
 * ย้ายออกมาจาก `posting.ts` ตอนที่ `clearing.ts` (ยืนยันเงินเข้า-ออกจริง) ต้องใช้ด่านเดียวกัน
 * **ห้ามให้แต่ละเส้นทางเขียนด่านของตัวเอง** ไม่งั้นกฎเดียวกันจะมีสองเวอร์ชันและเพี้ยนจากกัน
 * (บทเรียน mace-windu ข้อ 5: กฎเดียวกันห้ามเขียนสองที่)
 *
 * ทุกด่านที่นี่ตัดสินจาก **บรรทัดที่สร้างได้จริง** ไม่ใช่จากช่องใน input —
 * ด้วยวิธีนี้เส้นทางใหม่ที่เพิ่มในอนาคตถูกไล่ครบโดยไม่ต้องจำว่าต้องเรียกด่านไหนเพิ่ม
 */

import { isCashAccount } from "@/lib/rules/coa";
import {
  TX_TYPES,
  findSub,
  isValidPair,
  type SubCategory,
  type TxType,
  type TxTypeKey,
} from "@/lib/rules/tx-rules";
import {
  PostingError,
  type LedgerResolver,
  type OwnerInfo,
  type PostingLine,
  type PostingTransaction,
} from "./types";

export const round2 = (n: number) => Math.round(n * 100) / 100;

/** ตัวเลขเงินที่รับได้: จำกัด ไม่ใช่ NaN/Infinity และไม่ติดลบ */
export function money(n: number, label: string): number {
  if (typeof n !== "number" || !Number.isFinite(n)) {
    throw new PostingError(`${label} ต้องเป็นตัวเลขที่ระบุได้`);
  }
  if (n < 0) throw new PostingError(`${label} ติดลบไม่ได้`);
  return round2(n);
}

export function line(
  p: Omit<PostingLine, "debit" | "credit"> & { debit?: number; credit?: number }
): PostingLine {
  return { debit: 0, credit: 0, ...p };
}

/**
 * บัญชีที่ผู้ใช้ยังไม่ได้เลือก — ฟอร์มส่ง `""` · โค้ดที่ประกอบ input เองส่ง `undefined`
 * สองอย่างนี้ต้องแปลว่า "ไม่ได้ระบุ" เหมือนกัน ไม่ใช่ `""` กลายเป็นรหัสบัญชีที่หาไม่เจอ
 */
export function blankToUndefined(v: string | undefined): string | undefined {
  const t = v?.trim();
  return t ? t : undefined;
}

export function totalDebit(lines: PostingLine[]): number {
  return round2(lines.reduce((t, l) => t + l.debit, 0));
}

export function totalCredit(lines: PostingLine[]): number {
  return round2(lines.reduce((t, l) => t + l.credit, 0));
}

/** Money Invariant 1 — โยน error ถ้าไม่สมดุล */
export function assertBalanced(lines: PostingLine[]): void {
  const dr = totalDebit(lines);
  const cr = totalCredit(lines);
  if (dr !== cr) throw new PostingError(`รายการไม่สมดุล: เดบิต ${dr} · เครดิต ${cr}`);
}

/** Money Invariant 2 — บรรทัดเงินสดต้องผูกบัญชี · และไม่มีบรรทัดศูนย์ */
export function assertLinesValid(lines: PostingLine[]): void {
  for (const l of lines) {
    if (isCashAccount(l.coaCode) && !l.bankAccountId) {
      throw new PostingError(`บรรทัดเงินสด ${l.coaCode} ต้องระบุบัญชีธนาคาร`);
    }
    if (l.debit === 0 && l.credit === 0) {
      throw new PostingError(`บรรทัด ${l.coaCode} มีทั้งเดบิตและเครดิตเป็นศูนย์`);
    }
    if (l.debit > 0 && l.credit > 0) {
      throw new PostingError(`บรรทัด ${l.coaCode} เป็นได้อย่างเดียว เดบิตหรือเครดิต`);
    }
  }
}

/**
 * ต้องมีบัญชี **เมื่อมีบรรทัดเงินสดจริง** เท่านั้น (Money Invariant 2)
 *
 * เดิมด่านนี้เป็นการเช็ค `!input.bankAccountId` ไว้ก่อนการแยกสาขา จึงไม่สนใจ `notYetPaid`
 * เลย แล้วเส้นทางค้างรับ-ค้างจ่าย (ที่ตั้งใจให้ไม่มีขาเงินสด) ก็ใช้ไม่ได้ทั้งเส้น
 * ทั้งที่คอมเมนต์ในไฟล์เดียวกันเขียนไว้ว่าเส้นทางนั้นไม่มีบรรทัดเงินสด —
 * กันแน่นเกินจนเส้นทางที่ถูกต้องทำไม่ได้ (บทเรียนข้อ 7)
 *
 * ตัดสินจากบรรทัดที่สร้างได้จริงเหมือน `assertCashAccountsActive()` จึงครอบคลุมทุกสาขา
 * โดยไม่ต้องจำว่าสาขาไหนใช้บัญชี: ขาเงินสดของการโอน · บรรทัดเงินสดหลายบรรทัด
 * ของสาขาแยกเงินต้น-ดอกเบี้ย · ขาเงินสดของการขายทรัพย์ · และขาล้างลูกหนี้/เจ้าหนี้
 *
 * ข้อความต้องชี้ไปที่ "ยังไม่เลือกบัญชี" ไม่ใช่ไปโผล่เป็นเรื่องผู้ถือหรือบัญชีปิด
 * ซึ่งชี้ผิดจุดและทำให้ผู้ใช้แก้ไม่ถูก
 */
export function assertCashLinesHaveAccount(transactions: PostingTransaction[]): void {
  for (const t of transactions) {
    for (const l of t.lines) {
      if (isCashAccount(l.coaCode) && !l.bankAccountId) {
        throw new PostingError("ต้องระบุบัญชีธนาคารที่เงินเข้าหรือออก");
      }
    }
  }
}

/* ------------------------------------------------------------------ *
 * ปากทางเข้าตารางกฎ — ประเภทรายการ · หมวดย่อย · ช่องบังคับ
 *
 * ทุกเส้นทางที่สร้างรายการเงินต้องเข้าทางนี้ จึงมีการแปลง "ข้อมูลไม่ครบ" เป็น
 * `PostingError` ที่ผู้ใช้อ่านได้อยู่ **ที่เดียว**
 * ------------------------------------------------------------------ */

/**
 * ประเภทรายการ + หมวดย่อยต้องมีจริงในตารางกฎ และต้องเข้าคู่กัน
 *
 * ทำไมต้องเช็ค `typeKey` ก่อนเรียก `isValidPair()`: `isValidPair()` เรียก `getTxType()`
 * ซึ่งโยน **`Error` ธรรมดา** เมื่อไม่รู้จักประเภท ไม่ใช่ `PostingError` ผลคือ
 * `previewPosting()` และ `attempt()` ในหน้าจอ (ที่จับเฉพาะ `PostingError` แล้ว re-throw
 * ตัวอื่นโดยตั้งใจ) ปล่อย error ดิบขึ้นจอ ผู้ใช้เห็นข้อความที่อ่านไม่รู้เรื่อง
 * และไม่ได้รู้เลยว่าสิ่งที่ขาดคือ "ประเภทรายการ"
 *
 * `typeKey` เป็นช่องที่มาจากฟอร์ม/DB จึงเป็น "ข้อมูลผู้ใช้ไม่ครบ" → `PostingError`
 * ไม่ใช่ bug ของโปรแกรมเมอร์ (เส้นแบ่งนี้คือเหตุผลที่ `coa()` ยังโยน `Error` ธรรมดาได้
 * เพราะรับรหัสบัญชีจากตารางกฎเท่านั้น ถ้าพังคือตารางกฎพัง ไม่ใช่ผู้ใช้กรอกผิด)
 */
export function assertTypeAndSub(
  typeKey: TxTypeKey | undefined,
  subCode: string | undefined
): { type: TxType; sub: SubCategory } {
  const code = blankToUndefined(subCode);
  if (!code) {
    throw new PostingError(
      "ต้องเลือกหมวดย่อยของรายการ เพราะหมวดย่อยคือคนบอกคู่บัญชีและผลกระทบต่องบ"
    );
  }
  const found = findSub(code);
  if (!found) throw new PostingError(`ไม่พบหมวดย่อย ${code} ในตารางกฎ`);

  const key = blankToUndefined(typeKey);
  if (!key) {
    throw new PostingError(
      `ต้องระบุประเภทรายการ — หมวด "${found.sub.label}" อยู่ใต้ประเภท "${found.type.label}"`
    );
  }
  // ถามตารางกฎแบบไม่โยน ก่อนส่งต่อให้ `isValidPair()` ซึ่งโยน Error ดิบถ้าไม่รู้จักประเภท
  if (!TX_TYPES.some((t) => t.key === key)) {
    throw new PostingError(`ไม่พบประเภทรายการ "${key}" ในตารางกฎ`);
  }
  if (!isValidPair(key as TxTypeKey, code)) {
    throw new PostingError(
      `หมวดย่อย "${found.sub.label}" ไม่อยู่ใต้ประเภท "${found.type.label}"`
    );
  }
  return found;
}

/** ส่วนของ input ที่มิติบังคับใช้ตัดสิน — เส้นทางไหนก็ส่งรูปนี้มาได้ */
export type DimensionInput = { assetId?: string; contactId?: string };

/**
 * มิติที่หมวดย่อยบังคับ — อ่านจาก `sub.requires` ในตารางกฎ **ห้ามเช็ครหัสหมวดตรงๆ**
 *
 * ใช้ร่วมกันทั้งเส้นทางบันทึก (`buildPosting()`) และเส้นทางล้างยอดค้าง
 * (`buildClearing()`) เพราะการยืนยันเงินเข้า-ออกคือ transaction จริงอีกใบของ
 * เหตุการณ์เดียวกัน ถ้าใบแรกต้องผูกทรัพย์/คู่ค้า ใบที่สองก็ต้อง ไม่งั้นบัญชีย่อย
 * รายทรัพย์ของลูกหนี้/เจ้าหนี้ตั้งยอดด้วยทรัพย์หนึ่ง แล้วล้างแบบไม่มีทรัพย์ = ไม่หักกลบกัน
 *
 * กฎนี้เคยอยู่แค่ใน `posting.ts` ส่วน `clearing.ts` ปล่อยผ่าน — กฎเดียวกันอยู่สองที่
 * (หรือหายไปที่หนึ่ง) คือทางที่ตัวเลขสองใบไม่ตรงกันแบบเงียบๆ (บทเรียนข้อ 5)
 */
export function assertRequiredDimensions(sub: SubCategory, input: DimensionInput): void {
  if (sub.requires?.includes("asset") && !blankToUndefined(input.assetId)) {
    throw new PostingError(`หมวด "${sub.label}" ต้องผูกทรัพย์`);
  }
  if (sub.requires?.includes("contact") && !blankToUndefined(input.contactId)) {
    throw new PostingError(`หมวด "${sub.label}" ต้องระบุผู้ติดต่อ`);
  }
}

/**
 * ผู้ถือและบัญชีมาจาก resolver ที่ผู้เรียกส่งเข้ามาเท่านั้น
 *
 * หาไม่เจอ = ข้อมูลไม่ครบ ต้องปฏิเสธด้วย `PostingError` ที่ผู้ใช้อ่านได้
 * ไม่ใช่ปล่อย error ดิบขึ้นจอ และไม่ใช่เดาเป็นผู้ถือ/บัญชีอื่น
 * เพราะผู้ถือผิดแปลว่าเงินไปอยู่ในงบของคนผิดแบบเงียบๆ
 */
export function ownerOf(resolve: LedgerResolver, ownerId: string): OwnerInfo {
  const o = resolve.owner(ownerId);
  if (!o) throw new PostingError(`ไม่พบผู้ถือ: ${ownerId}`);
  return o;
}

export function bankOwner(resolve: LedgerResolver, bankAccountId: string): string {
  const b = resolve.bankAccount(bankAccountId);
  if (!b) throw new PostingError(`ไม่พบบัญชีธนาคาร: ${bankAccountId}`);
  return b.ownerId;
}

/**
 * ผู้ถือต้องเป็นตัวตนที่ถือทรัพย์ได้จริง — "SRI Family (รวม)" เป็นมุมมองรวม ไม่ใช่เจ้าของ
 * เป็นเงื่อนไขเชิงโครงสร้าง ไม่ใช่นโยบายเอกสาร จึงตรวจตั้งแต่ตอนสร้างบรรทัด
 */
export function assertOwnerSelectable(resolve: LedgerResolver, ownerId: string): void {
  const owner = ownerOf(resolve, ownerId);
  if (!owner.selectableAsHolder) {
    throw new PostingError(`"${owner.name}" เป็นมุมมองรวม เลือกเป็นผู้ถือของรายการไม่ได้`);
  }
}

/** บัญชีที่เลือกต้องเป็นของผู้ถือรายการนั้น ไม่งั้นเงินไปโผล่ในงบของคนอื่น */
export function assertBankBelongsTo(
  resolve: LedgerResolver,
  bankAccountId: string,
  ownerId: string
): void {
  const holder = bankOwner(resolve, bankAccountId);
  if (holder !== ownerId) {
    throw new PostingError(
      `บัญชีที่เลือกเป็นของ ${ownerOf(resolve, holder).name} แต่รายการระบุผู้ถือเป็น ${ownerOf(resolve, ownerId).name}`
    );
  }
}

/** ส่วนของ input ที่กติกาเอกสารใช้ตัดสิน — เส้นทางไหนก็ส่งรูปนี้มาได้ */
export type EvidenceInput = { attachments?: string[]; contactId?: string };

/**
 * Corporate strict — ดักตั้งแต่ที่นี่เพื่อให้ผู้ใช้เห็นข้อความที่เข้าใจได้
 * (DB มี trigger กันอีกชั้นอยู่แล้ว ที่นี่ไม่ได้แทนที่ แต่ช่วยให้รู้ตัวก่อนกดส่ง)
 *
 * แยกออกจากการสร้างบรรทัดโดยตั้งใจ: เอกสารหลักฐานไม่ได้เปลี่ยนคู่บัญชี
 * พรีวิวจึงแสดงบรรทัดได้ทั้งที่ยังไม่แนบไฟล์ แต่ตัวจริงจะไม่ยอมปล่อยผ่าน
 */
export function assertEvidencePolicy(
  input: EvidenceInput,
  ownerId: string,
  resolve: LedgerResolver
): void {
  const owner = ownerOf(resolve, ownerId);
  if (owner.policy !== "corporate_strict") return;
  if ((input.attachments?.length ?? 0) === 0) {
    throw new PostingError(
      `${owner.name} เป็นนิติบุคคล ต้องแนบหลักฐาน (ใบเสร็จ/ใบแจ้งหนี้/สัญญา) ก่อนบันทึก`
    );
  }
  if (!input.contactId) {
    throw new PostingError(`${owner.name} เป็นนิติบุคคล ต้องระบุคู่ค้าทุกรายการ`);
  }
}

/**
 * บัญชีที่ปิดใช้งานแล้วห้ามรับรายการ **ใหม่** (D-092)
 *
 * ตัดสินจาก **บรรทัดที่สร้างได้จริง** ไม่ใช่จาก `input.bankAccountId` —
 * ด้วยวิธีนี้ทุกสาขาถูกไล่ครบโดยไม่ต้องจำว่าสาขาไหนต้องเรียกเพิ่ม:
 * ขาเงินสดของการโอนทั้งต้นทางและปลายทาง · ทั้งสองขาของรายการข้ามผู้ถือ
 * (ผู้ถือและบัญชีปลายทางอ่านจาก resolver เอง ไม่ใช่จากฟอร์ม — บทเรียนข้อ 2)
 * และบรรทัดเงินสดที่สาขาแยกเงินต้น-ดอกเบี้ย/ขายทรัพย์ประกอบขึ้นเอง
 *
 * ผลพลอยได้ที่ตั้งใจ: เส้นทางค้างรับ-ค้างจ่ายไม่มีบรรทัดเงินสดเลย จึงอ้างบัญชีที่ปิดได้
 * การรับรู้ว่าลูกค้าค้างจ่ายเราไม่ควรถูกบล็อกเพราะบัญชีที่จะรับเงินปิดไป
 * ตอนล้างลูกหนี้ด้วยเงินสดจริง (`buildClearing()`) จะมีบรรทัดเงินสดและถูกกันที่นั้น
 * ซึ่งเป็นจุดที่ถูกต้อง
 *
 * `isActive !== true` ไม่ใช่ `=== false` — resolver ที่คืนข้อมูลไม่ครบต้องถูกปฏิเสธ
 * ไม่ใช่ถูกตีความว่าเปิดใช้งาน ไม่งั้นวันที่ resolver ตัวใดลืมส่งฟิลด์นี้
 * การกันบัญชีปิดจะหายไปเงียบๆ ทั้งระบบ (บทเรียนข้อ 1 และ ข้อ 3)
 */
export function assertCashAccountsActive(
  transactions: PostingTransaction[],
  resolve: LedgerResolver,
  opts: { reversal?: boolean } = {}
): void {
  // ยกเว้นการกลับรายการ: กฎเหล็กข้อ 1 ห้าม DELETE รายการที่ post แล้ว ทางเดียวที่แก้ได้
  // คือ reverse + ลงใหม่ ถ้ากันแบบไม่มียกเว้น รายการเก่าของบัญชีที่ปิดจะแก้ไม่ได้ตลอดกาล
  //
  // อ่านจากธงที่ผู้เรียกบอกเจตนามาตรงๆ เท่านั้น **ห้ามเดาจากเครื่องหมายยอดเงิน
  // หรือจากหมวดย่อย** เพราะเดาผิดแปลว่าปิดบัญชีไปแล้วยังลงรายการใหม่เข้าไปได้
  // คือช่องเดียวกับที่ D-092 ตั้งใจปิด
  if (opts.reversal) return;

  for (const t of transactions) {
    for (const l of t.lines) {
      if (!l.bankAccountId) continue;
      const b = resolve.bankAccount(l.bankAccountId);
      if (!b) throw new PostingError(`ไม่พบบัญชีธนาคาร: ${l.bankAccountId}`);
      if (b.isActive !== true) {
        throw new PostingError(
          `บัญชี "${b.name}" ปิดใช้งานแล้ว (หรือไม่ทราบสถานะ) ลงรายการใหม่เข้าบัญชีนี้ไม่ได้ — ` +
            "เลือกบัญชีที่ยังเปิดใช้งาน หรือถ้าต้องการแก้รายการเดิมของบัญชีนี้ " +
            "ให้ใช้การกลับรายการ (reverse) แล้วลงใหม่"
        );
      }
    }
  }
}
