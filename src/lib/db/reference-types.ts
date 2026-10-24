/**
 * ข้อมูลอ้างอิงจริงจาก `sri_os` ที่หน้าจอและฟอร์มใช้ — ประเภทข้อมูลล้วน ใช้ได้ทั้ง server และ client
 *
 * อ่านเฉพาะคอลัมน์ที่ขึ้นทะเบียน `open` ใน `column_exposure` (D-089) —
 * คอลัมน์ที่ปิดด้วย GRANT (ยอดยกมา · เลขผู้เสียภาษี · ขนาดการถือทรัพย์) **ไม่ถูกอ่านที่นี่เลย**
 * เพราะ `select` ตารางฐานของ `authenticated` ถูกถอนไปแล้ว ขอคอลัมน์ที่ปิดจะได้ permission denied
 */

/** "มุมมองรวมทุกชื่อ" ไม่ใช่ผู้ถือใน DB — เป็นค่าพิเศษของตัวสลับมุมมองเท่านั้น เลือกเป็นผู้ถือรายการไม่ได้ */
export const FAMILY_VIEW = "family";

export type RefOwner = {
  id: string;
  code: string;
  name: string;
  policy: "corporate_strict" | "personal_flexible";
  /** 'planned' = นิติบุคคลที่ยังไม่จดทะเบียน (ซ่อนจากตัวเลือกผู้ถือ) */
  status: string;
  color: string | null;
  sortOrder: number;
};

export type RefBank = {
  id: string;
  ownerId: string;
  name: string;
  bank: string;
  last4: string | null;
  isActive: boolean;
  sortOrder: number;
};

export type RefAsset = {
  id: string;
  code: string;
  name: string;
  ownerId: string;
  status: string;
};

export type RefContact = {
  id: string;
  firstName: string;
  lastName: string;
  types: string[];
  phone: string;
  lineId: string;
  email: string;
};

export type Reference = {
  owners: RefOwner[];
  banks: RefBank[];
  assets: RefAsset[];
  contacts: RefContact[];
  /** `chart_of_accounts.id` → รหัสบัญชี (ใช้อ่านบรรทัดจาก `v_ledger_posted` ที่เก็บเป็น uuid) */
  coaCodeById: Record<string, string>;
};

export type ReferenceState =
  | { ok: true; ref: Reference }
  | { ok: false; error: string };

export const contactFullName = (c: Pick<RefContact, "firstName" | "lastName">): string =>
  `${c.firstName} ${c.lastName}`.trim();

/** ป้ายบทบาทของผู้ติดต่อ — `types` ใน DB เป็นข้อความอิสระ ค่าที่ไม่รู้จักแสดงตามที่เก็บไว้ ไม่เดาแทน */
const CONTACT_TYPE_LABEL: Record<string, string> = {
  tenant: "ผู้เช่า",
  lender: "ผู้ให้กู้",
  borrower: "ผู้กู้",
  vendor: "คู่ค้า / ผู้รับเหมา",
  other: "อื่นๆ",
};

export const contactTypeLabel = (types: readonly string[]): string =>
  types.length ? types.map((t) => CONTACT_TYPE_LABEL[t] ?? t).join(" / ") : "ไม่ระบุประเภท";

/** ค่าที่ฟอร์มสร้างผู้ติดต่อเลือกได้ — ตรงกับที่ `CONTACT_TYPE_LABEL` รู้จัก */
export const CONTACT_TYPE_CHOICES = Object.entries(CONTACT_TYPE_LABEL).map(([value, label]) => ({ value, label }));
