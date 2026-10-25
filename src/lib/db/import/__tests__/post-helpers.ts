import type { Reference } from "@/lib/db/reference-types";
import type { OpeningAsset, FxRateRow } from "../opening-post";
import { BANKS, OWNERS, loadFixture, setCell, sheetOf } from "./helpers";
import type { Workbook } from "../xlsx";

/** ผู้ถือ/บัญชีของไฟล์ตัวอย่าง พร้อมนโยบาย (SRI Corporation เป็นนิติบุคคล) */
export function refOf(): Pick<Reference, "owners" | "banks" | "contacts"> {
  return {
    owners: OWNERS.map((o, i) => ({
      id: o.id,
      code: o.id,
      name: o.name,
      status: o.status,
      policy: o.id === "o-sri" ? ("corporate_strict" as const) : ("personal_flexible" as const),
      color: null,
      sortOrder: i,
    })),
    banks: BANKS.map((b, i) => ({ id: b.id, ownerId: b.ownerId, name: b.name, bank: "X", last4: null, isActive: b.isActive, sortOrder: i, currency: b.currency })),
    contacts: [{ id: "c-auditor", firstName: "สำนักงานบัญชี", lastName: "", types: ["vendor"], phone: "", lineId: "", email: "" }],
  };
}

export const ASSET_IDS = { ptt: "a-ptt", set50: "a-set50", kfixed: "a-kfixed" };

/** ทรัพย์ของธนากรที่ล็อตในไฟล์ตัวอย่างอ้างถึง (PTT · SET50 · K-FIXED) */
export const assetsOf = (): OpeningAsset[] => [
  { id: ASSET_IDS.ptt, code: "PTT", name: "หุ้น ปตท.", ownerId: "o-thanakorn", status: "active", currency: "THB" },
  { id: ASSET_IDS.set50, code: "SEC-002", name: "SET50", ownerId: "o-thanakorn", status: "active", currency: "THB" },
  { id: ASSET_IDS.kfixed, code: "k-fixed", name: "กองทุน K-FIXED", ownerId: "o-thanakorn", status: "active", currency: "THB" },
];

export const noRates: FxRateRow[] = [];

/** แก้ยอดของรหัสบัญชีในชีทผู้ถือ (หาแถวจากคอลัมน์ A) */
export function setByCode(wb: Workbook, sheet: string, code: string, amount: number | null): void {
  const sh = sheetOf(wb, sheet);
  for (const [row, cells] of sh.rows) {
    if (String(cells.get("A")?.value ?? "") === code) {
      setCell(wb, sheet, row, "E", amount);
      return;
    }
  }
  throw new Error(`ไม่พบรหัส ${code} ในชีท ${sheet}`);
}

/**
 * ไฟล์ตัวอย่างที่ **ลงสมุดผ่านตารางกฎปัจจุบันได้** — เอา 1310/2310 (ลูกหนี้/เจ้าหนี้ระหว่างกัน) ออก
 * เพราะตารางกฎยังไม่มีหมวดยอดยกมาของสองบัญชีนี้ (ดู opening-post.test.ts) แล้วชดเชยที่ส่วนของเจ้าของให้งบดุลยังดุล
 */
export function postableWorkbook(): Workbook {
  const wb = loadFixture();
  setByCode(wb, "BS-ธนากร", "1310", null);
  setByCode(wb, "BS-ธนากร", "3300", 1_820_000); // เดิม 1,920,000 (รวมลูกหนี้ระหว่างกัน 100,000)
  setByCode(wb, "BS-สุธี", "2310", null);
  setByCode(wb, "BS-สุธี", "3300", 100_000); // ทุน 200,000 + กำไรสะสม 100,000 = เงินสด 300,000
  return wb;
}
