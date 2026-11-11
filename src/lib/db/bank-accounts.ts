import { CURRENCIES } from "@/lib/rules/currency";

/**
 * ตรวจข้อมูลบัญชีธนาคารก่อนเขียน `sri_os.bank_accounts` — ฟังก์ชันล้วน ไม่แตะ DB
 *
 * สิ่งที่ตรวจเป็น "ความสะดวก/ข้อความอ่านออก" ไม่ใช่ความปลอดภัย: สิทธิ์จริงคือ RLS
 * (`bank_accounts_insert/update` = `settings.manage` + เห็นผู้ถือนั้น) และสกุลเงินมี check constraint ใน DB
 *
 * กติกาที่ตั้งใจ
 *  - **สกุลเงินกำหนดตอนสร้างครั้งเดียว** แก้ภายหลังไม่ได้: บัญชี FCD ที่ถูกสร้างเป็นบาท (หรือกลับกัน) แล้วมีรายการลงไป
 *    ยอดเงินสดในงบจะผิดเงียบๆ ทั้งงวด · DB ยังไม่มีด่านกันการเปลี่ยนสกุลหลังมีบรรทัด จึงกันที่ทางเข้านี้ไว้ก่อน
 *    (ผิดสกุล = ปิดบัญชีนั้นแล้วสร้างใหม่ ถ้ายังไม่มีรายการ)
 *  - **ชื่อบัญชีซ้ำในผู้ถือเดียวกันไม่ได้** (นับบัญชีที่ปิดแล้วด้วย): ไฟล์นำเข้ายอดตั้งต้นจับคู่บัญชีด้วยชื่อ
 *    ชื่อซ้ำ = เงินอาจลงผิดบัญชีเงียบๆ
 *  - ผู้ถือต้องเปิดใช้งาน (`active`) — ผู้ถือที่ยังไม่จดทะเบียนลงรายการไม่ได้อยู่แล้ว
 */

export type BankInput = {
  ownerId: string;
  /** ธนาคาร/ช่องทาง เช่น กรุงเทพ */
  bank: string;
  /** ชื่อที่แสดงในตัวเลือกทุกฟอร์ม เช่น "ธนากร - BBL 888" */
  displayName: string;
  /** เลขท้าย 4 หลัก (ไม่บังคับ) */
  last4: string;
  currency: string;
};

export type BankField = keyof BankInput;
export type BankFieldErrors = Partial<Record<BankField, string>>;

export type CleanBank = {
  ownerId: string;
  bank: string;
  displayName: string;
  last4: string | null;
  currency: string;
};

export const MAX_BANK_TEXT = 60;

/** ตัดช่องว่างหัวท้าย + ยุบช่องว่างซ้อน (ชื่อที่ต่างกันแค่เว้นวรรคต้องนับว่าซ้ำ) */
export const squash = (s: unknown): string => (typeof s === "string" ? s.replace(/\s+/g, " ").trim() : "");

const nameKey = (s: string): string => squash(s).normalize("NFC").toLocaleLowerCase("th-TH");

export type OwnerLite = { id: string; name: string; status: string };
export type ExistingBank = { id: string; ownerId: string; name: string };

function checkText(label: string, v: string, errors: BankFieldErrors, field: BankField) {
  if (!v) errors[field] = `กรอก${label}ก่อน`;
  else if (v.length > MAX_BANK_TEXT) errors[field] = `${label}ยาวเกิน ${MAX_BANK_TEXT} ตัวอักษร`;
  // eslint-disable-next-line no-control-regex
  else if (/[\u0000-\u001f\u007f]/.test(v)) errors[field] = `${label}มีอักขระที่ใช้ไม่ได้`;
}

/**
 * ตรวจข้อมูลของบัญชีที่จะสร้างใหม่ หรือแก้ (ส่ง `editingId` เมื่อแก้ — ไม่นับตัวเองว่าชื่อซ้ำ)
 * `ownerId` / `currency` ของการแก้ไม่ถูกใช้ — action ไม่ส่งสองช่องนี้ไปแก้
 */
export function validateBank(
  input: BankInput,
  owners: readonly OwnerLite[],
  existing: readonly ExistingBank[],
  opts: { editingId?: string; skipOwnerAndCurrency?: boolean } = {}
): { ok: true; value: CleanBank } | { ok: false; errors: BankFieldErrors } {
  const errors: BankFieldErrors = {};
  const bank = squash(input?.bank);
  const displayName = squash(input?.displayName);
  const last4 = squash(input?.last4);
  const ownerId = typeof input?.ownerId === "string" ? input.ownerId : "";
  const currency = typeof input?.currency === "string" ? input.currency : "";

  checkText("ชื่อธนาคาร", bank, errors, "bank");
  checkText("ชื่อบัญชี", displayName, errors, "displayName");
  if (last4 && !/^\d{4}$/.test(last4)) errors.last4 = "เลขท้ายต้องเป็นตัวเลข 4 หลักพอดี (หรือเว้นว่าง)";

  if (!opts.skipOwnerAndCurrency) {
    const owner = owners.find((o) => o.id === ownerId);
    if (!ownerId) errors.ownerId = "เลือกผู้ถือบัญชีก่อน — ระบบไม่เลือกให้";
    else if (!owner) errors.ownerId = "ไม่รู้จักผู้ถือนี้";
    else if (owner.status !== "active") errors.ownerId = `ผู้ถือ “${owner.name}” ยังไม่เปิดใช้งาน จึงเปิดบัญชีให้ไม่ได้`;

    if (!currency) errors.currency = "เลือกสกุลเงินของบัญชี — ระบบไม่เดาให้ (บัญชี FCD ที่ตั้งเป็นบาทจะทำให้ยอดผิดเงียบๆ)";
    else if (!(CURRENCIES as readonly string[]).includes(currency)) errors.currency = `ไม่รองรับสกุล “${currency}” (รองรับ ${CURRENCIES.join(" · ")})`;
  }

  if (!errors.displayName) {
    const key = nameKey(displayName);
    const clash = existing.find((b) => b.ownerId === ownerId && b.id !== opts.editingId && nameKey(b.name) === key);
    if (clash) errors.displayName = `ผู้ถือคนนี้มีบัญชีชื่อ “${clash.name}” อยู่แล้ว — ชื่อซ้ำไม่ได้ (ไฟล์นำเข้ายอดตั้งต้นจับคู่บัญชีด้วยชื่อ)`;
  }

  if (Object.keys(errors).length) return { ok: false, errors };
  return { ok: true, value: { ownerId, bank, displayName, last4: last4 || null, currency } };
}

export const CURRENCY_LABEL: Record<string, string> = {
  THB: "บาท (THB)",
  USD: "ดอลลาร์สหรัฐ (USD)",
  JPY: "เยน (JPY)",
  CNY: "หยวน (CNY)",
};
