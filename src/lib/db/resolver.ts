import type { BankInfo, LedgerResolver, OwnerInfo } from "@/lib/ledger/types";
import type { Reference } from "./reference-types";

/**
 * LedgerResolver ที่สร้างจากข้อมูลจริงใน `sri_os.owners` / `sri_os.bank_accounts`
 *
 * เป็นชั้นนอกของ engine (engine ไม่ import ข้อมูลเอง · ดู `lib/ledger/types.ts`)
 * ทุกฟังก์ชันคืน `null` เมื่อหาไม่เจอ ไม่ throw ไม่เดา — engine แปลงเป็น PostingError เอง
 *
 * - บัญชีที่ปิดใช้งาน **ยังต้องหาเจอ** (คืน `isActive: false`) เพราะรายการย้อนหลังต้องอ้างถึงได้ (D-092)
 * - `selectableAsHolder` เป็น true ทุกราย: ใน DB ไม่มีผู้ถือแบบ "มุมมองรวม" (มีแต่ในตัวสลับมุมมอง)
 *   ผู้ถือที่ยังเป็น `planned` ถูกซ่อนจากตัวเลือกในฟอร์ม แต่ **engine ไม่ปฏิเสธ** เพราะข้อความ
 *   ของด่านนั้นพูดถึง "มุมมองรวม" ซึ่งไม่ตรงความจริง — ต้องให้ลูกพี่ตัดสินว่าจะกัน planned ที่ DB ไหม
 *
 * `currency` ต้องส่งต่อให้ engine เสมอ — engine **ปฏิเสธ** เส้นทางเงินตราทุกเส้น (แปลงค่า · แลกเป็นบาท) เมื่อบัญชีไม่บอกสกุล
 * (ไม่ตีความว่าบาท) · resolver ที่ลืมช่องนี้ทำให้ทั้งสองหมวดลงไม่ได้เลยแม้ข้อมูลครบ (เจอตอนรันกับ Postgres จริง 25/10)
 *
 * **สถานะเปิด-ปิดของบัญชีจากสแนปช็อตนี้เก่าได้เท่าอายุของหน้า** — ห้ามใช้ตัดสินตอนบันทึกจริง
 * ตอนบันทึกจริง server action โหลดใหม่ทุกครั้ง และ trigger `fn_assert_bank_account_open` เป็นด่านสุดท้าย
 */
export function makeResolver(ref: Pick<Reference, "owners" | "banks">): LedgerResolver {
  const owners = new Map<string, OwnerInfo>(
    ref.owners.map((o) => [
      o.id,
      { id: o.id, name: o.name, policy: o.policy, selectableAsHolder: true },
    ])
  );
  const banks = new Map<string, BankInfo>(
    ref.banks.map((b) => [b.id, { id: b.id, name: b.name, ownerId: b.ownerId, isActive: b.isActive, currency: b.currency }])
  );
  return {
    owner: (id) => owners.get(id) ?? null,
    bankAccount: (id) => banks.get(id) ?? null,
  };
}
