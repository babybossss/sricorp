import type { Reference } from "@/lib/db/reference-types";
import type { OpeningAsset, FxRateRow } from "../opening-post";
import { BANKS, OWNERS, loadFixture, setCell, sheetOf } from "./helpers";
import type { Workbook } from "../xlsx";
import { coa } from "@/lib/rules/coa";

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

/** ชื่อทรัพย์รายชิ้นที่ `breakdownRowsFromBs()` ตั้งให้ (ตรงกับชีทแจกแจงที่เติมในไฟล์ตัวอย่าง) */
export const itemName = (code: string, owner: string) => `${coa(code).nameTh} · ชิ้นที่ 1 ของ${owner}`;

/**
 * ทรัพย์ที่ลงทะเบียนไว้แล้ว: ของธนากรที่ล็อตในไฟล์ตัวอย่างอ้างถึง (PTT · SET50 · K-FIXED)
 * + ทรัพย์รายชิ้นของชีทแจกแจงในไฟล์ตัวอย่าง (SRI: ขายฝาก 1400 · อสังหาฯ เช่า 1500 / ธนากร: อสังหาฯ เช่า 1500)
 * หมวดเขียนเป็นตัวอักษรตรงนี้โดยตั้งใจ (ไม่เรียก `assetCategoryOfCoa`) เพื่อให้เทสต์เป็นผู้ตัดสินอิสระจากโค้ดที่ทดสอบ
 */
export const assetsOf = (): OpeningAsset[] => [
  { id: ASSET_IDS.ptt, code: "PTT", name: "หุ้น ปตท.", ownerId: "o-thanakorn", status: "active", currency: "THB" },
  { id: ASSET_IDS.set50, code: "SEC-002", name: "SET50", ownerId: "o-thanakorn", status: "active", currency: "THB" },
  { id: ASSET_IDS.kfixed, code: "k-fixed", name: "กองทุน K-FIXED", ownerId: "o-thanakorn", status: "active", currency: "THB" },
  ...itemAssetsOf(),
];

export const ITEM_ASSET_IDS = { sriSrr: "a-sri-1400", sriRental: "a-sri-1500", tkRental: "a-tk-1500" };
export const itemAssetsOf = (): OpeningAsset[] => [
  { id: ITEM_ASSET_IDS.sriSrr, code: "RE-0001", name: itemName("1400", "SRI Corporation"), ownerId: "o-sri", status: "active", currency: "THB", categoryCode: "RE_SRR" },
  { id: ITEM_ASSET_IDS.sriRental, code: "RE-0002", name: itemName("1500", "SRI Corporation"), ownerId: "o-sri", status: "active", currency: "THB", categoryCode: "RE_RENTAL" },
  { id: ITEM_ASSET_IDS.tkRental, code: "RE-0003", name: itemName("1500", "ธนากร"), ownerId: "o-thanakorn", status: "active", currency: "THB", categoryCode: "RE_RENTAL" },
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
 * ไฟล์ตัวอย่างฉบับ "ไม่มีลูกหนี้/เจ้าหนี้ระหว่างกัน" — เอา 1310/2310 ออกแล้วชดเชยที่ส่วนของเจ้าของให้งบดุลยังดุล
 * (เดิมต้องเอาออกเพราะตารางกฎไม่มีหมวด ตอนนี้มีแล้ว · ยังใช้ฉบับนี้เป็นฐานของเทสต์ส่วนใหญ่เพื่อให้ตัวเลขคงที่ ส่วนไฟล์เดิมทดสอบแยก)
 */
export function postableWorkbook(): Workbook {
  const wb = loadFixture();
  setByCode(wb, "BS-ธนากร", "1310", null);
  setByCode(wb, "BS-ธนากร", "3300", 1_820_000); // เดิม 1,920,000 (รวมลูกหนี้ระหว่างกัน 100,000)
  setByCode(wb, "BS-สุธี", "2310", null);
  setByCode(wb, "BS-สุธี", "3300", 100_000); // ทุน 200,000 + กำไรสะสม 100,000 = เงินสด 300,000
  return wb;
}
