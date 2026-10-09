/**
 * หมวดใหญ่ของทรัพย์ (Asset Class) — ลูกพี่กำหนด 26/09
 *
 *   Businesses · Real Estate · Paper Asset · Commodity & Cash
 *
 * **นี่เป็นการจัดกลุ่มคนละแกนกับผังบัญชี** อย่าสับสนกัน:
 * - `coa.ts` + `statements.ts` = มุมมอง**บัญชี** (สินทรัพย์/หนี้สิน · บรรทัดในงบ)
 * - ไฟล์นี้ = มุมมอง**ประเภทการลงทุน** ใช้ตอบว่า "เงินกองกลางกระจายอยู่ในอะไร"
 *
 * ทรัพย์หนึ่งชิ้นมีทั้งสองมุมมองพร้อมกัน เช่น สัญญาขายฝาก:
 * - บัญชี = ลูกหนี้ (1400 เงินลงทุนขายฝาก) ไม่ใช่ที่ดินที่เราเป็นเจ้าของ
 * - ประเภทการลงทุน = **Real Estate** เพราะความเสี่ยงและผลตอบแทนอิงอสังหาฯ (ลูกพี่ระบุชัด)
 *
 * เส้นแบ่ง Paper Asset กับ Commodity & Cash ที่ใช้ในไฟล์นี้:
 * - **Paper Asset** = สิทธิเรียกร้องที่มีผู้ออก (หุ้น พันธบัตร กองทุน สัญญาเงินกู้)
 *   มีคนที่อาจเบี้ยวเราได้
 * - **Commodity & Cash** = ถือตัวสินทรัพย์เอง ไม่มีผู้ออก (ทองคำ คริปโต เงินสด)
 */

import { COA } from "./coa";

export type AssetClassCode = "BIZ" | "RE" | "PAPER" | "COMMODITY";

export type AssetCategory = {
  code: string;
  nameTh: string;
  nameEn: string;
  /** รหัสบัญชีในผังที่ยอดของหมวดนี้ไปรวมอยู่ */
  coaCodes: string[];
  note?: string;
};

export type AssetClass = {
  code: AssetClassCode;
  /** ชื่อที่ลูกพี่ใช้ */
  name: string;
  nameTh: string;
  sortOrder: number;
  categories: AssetCategory[];
};

export const ASSET_CLASSES: AssetClass[] = [
  {
    code: "BIZ",
    name: "Businesses",
    nameTh: "ธุรกิจ",
    sortOrder: 10,
    categories: [
      {
        code: "BIZ_OPERATING",
        nameTh: "เงินลงทุนในกิจการ",
        nameEn: "Operating business",
        coaCodes: [],
        note: "กิจการที่เราลงทุนและมีส่วนในการบริหาร",
      },
      {
        code: "BIZ_RELATED",
        nameTh: "บริษัทในเครือ",
        nameEn: "Related company",
        coaCodes: ["1710"],
      },
    ],
  },
  {
    code: "RE",
    name: "Real Estate",
    nameTh: "อสังหาริมทรัพย์",
    sortOrder: 20,
    categories: [
      { code: "RE_RENTAL", nameTh: "ปล่อยเช่า", nameEn: "Rental", coaCodes: ["1500", "1510"] },
      { code: "RE_FOR_SALE", nameTh: "รอขาย", nameEn: "Held for sale", coaCodes: [] },
      { code: "RE_PROJECT", nameTh: "โครงการระหว่างพัฒนา", nameEn: "Project", coaCodes: [] },
      { code: "RE_RENOVATE", nameTh: "รอปรับปรุง", nameEn: "Awaiting renovation", coaCodes: [] },
      {
        code: "RE_SRR",
        nameTh: "ขายฝาก / รับจำนอง",
        nameEn: "Redemption & mortgage contracts",
        coaCodes: ["1400", "1410"],
        note:
          "ลูกพี่ระบุให้อยู่ใน Real Estate · ทางบัญชีเป็นลูกหนี้ ไม่ใช่ทรัพย์ที่เราถือกรรมสิทธิ์ " +
          "แต่ความเสี่ยงและผลตอบแทนอิงอสังหาฯ ที่เป็นหลักประกัน",
      },
    ],
  },
  {
    code: "PAPER",
    name: "Paper Asset",
    nameTh: "สินทรัพย์กระดาษ",
    sortOrder: 30,
    categories: [
      { code: "PAPER_STOCK", nameTh: "หุ้น", nameEn: "Stocks", coaCodes: ["1700"] },
      { code: "PAPER_ETF", nameTh: "ETF", nameEn: "ETF", coaCodes: [] },
      { code: "PAPER_FUND", nameTh: "กองทุน", nameEn: "Mutual fund", coaCodes: [] },
      { code: "PAPER_BOND", nameTh: "พันธบัตร / หุ้นกู้", nameEn: "Bonds", coaCodes: [] },
      {
        code: "PAPER_LOAN",
        nameTh: "สัญญาเงินให้กู้ยืม",
        nameEn: "Loan agreement",
        coaCodes: ["1300"],
        note: "เงินให้กู้ที่ไม่มีอสังหาฯ เป็นหลักประกัน · ถ้ามีหลักประกันเป็นที่ดิน ให้ลง RE_SRR",
      },
    ],
  },
  {
    code: "COMMODITY",
    name: "Commodity & Cash",
    nameTh: "สินทรัพย์จริงและเงินสด",
    sortOrder: 40,
    categories: [
      { code: "COM_GOLD", nameTh: "ทองคำ", nameEn: "Gold", coaCodes: ["1720"] },
      {
        code: "COM_CRYPTO",
        nameTh: "คริปโต",
        nameEn: "Crypto",
        coaCodes: [],
        note:
          "ลูกพี่ยืนยัน 27/09 ให้อยู่ Commodity & Cash — ถือตัวสินทรัพย์เอง ไม่มีผู้ออก " +
          "และไม่มีกระแสเงินสด เหมือนทองคำ ไม่ใช่สิทธิเรียกร้องแบบหุ้น/พันธบัตร",
      },
      { code: "COM_CASH", nameTh: "เงินสดและเงินฝาก", nameEn: "Cash & deposits", coaCodes: ["1100"] },
    ],
  },
];

/**
 * บัญชีสินทรัพย์ที่ **ไม่ใช่ประเภทการลงทุน** จึงไม่อยู่ในหมวดใหญ่ใดเลย
 *
 * ลูกหนี้ที่เกิดจากการดำเนินงานและรายการระหว่างกัน ไม่ใช่สิ่งที่เรา "ลงทุนใน"
 * ถ้าเอาไปรวมในหมวดใหญ่ ยอด NAV จะบวมด้วยลูกหนี้ที่รอเก็บ
 */
/**
 * **ตอนต่อข้อมูลจริง**: ผลรวมของ 4 หมวดใหญ่จะ **น้อยกว่า** สินทรัพย์รวมในงบดุล
 * เท่ากับยอดของบัญชีในลิสต์นี้ · หน้าไหนที่แสดง "ทรัพย์รวม" หรือ NAV
 * ต้องมีบรรทัด "อื่นๆ (ไม่ใช่การลงทุน)" มารับส่วนต่าง ไม่งั้นตัวเลขสองหน้าจะไม่ตรงกัน
 * (ตอนนี้ mock ยังไม่มียอดในบัญชีพวกนี้ ผลรวมจึงเท่ากันพอดี)
 */
export const UNCLASSIFIED_ASSET_COA: Record<string, string> = {
  "1200": "ลูกหนี้ค่าเช่า — เกิดจากการดำเนินงาน ไม่ใช่การลงทุน",
  "1210": "ลูกหนี้ดอกเบี้ย — เกิดจากการดำเนินงาน",
  // บัญชีพักของเงินที่ยังไม่เข้า — เป็นสิทธิเรียกเก็บ ไม่ใช่สิ่งที่เรา "ลงทุนใน"
  // เอาไปรวมในหมวดใหญ่จะนับซ้ำกับทรัพย์ที่ขายออกไปแล้ว (ตัดทรัพย์แล้วแต่เงินยังไม่เข้า)
  "1220": "ลูกหนี้อื่น (รอรับเงิน) — บัญชีพักก่อนยืนยันเงินเข้า",
  // ค่าเผื่อเป็น **สินทรัพย์ติดลบของลูกหนี้** ซึ่งทั้งสามบัญชีข้างบนไม่ใช่การลงทุน
  // ถ้าเอามารวมในหมวดใหญ่ ยอดลงทุนจะถูกกดลงเท่าค่าเผื่อของหนี้ที่ไม่เกี่ยวกับการลงทุนเลย
  "1290": "ค่าเผื่อหนี้สงสัยจะสูญ — หักจากลูกหนี้ ไม่ใช่ประเภทการลงทุน",
  "1600": "เงินมัดจำจ่าย — เงินวางประกัน รอคืน",
  "1310": "ลูกหนี้ระหว่างกัน — ตัดออกในงบรวม",
};

const CLASS_BY_CODE = new Map(ASSET_CLASSES.map((c) => [c.code, c]));

export function assetClass(code: AssetClassCode): AssetClass {
  const c = CLASS_BY_CODE.get(code);
  if (!c) throw new Error(`ไม่พบหมวดใหญ่ของทรัพย์: ${code}`);
  return c;
}

export function allCategories(): (AssetCategory & { classCode: AssetClassCode; className: string })[] {
  return ASSET_CLASSES.flatMap((c) =>
    c.categories.map((cat) => ({ ...cat, classCode: c.code, className: c.name }))
  );
}

export function findCategory(code: string) {
  return allCategories().find((c) => c.code === code);
}

/** หมวดใหญ่ที่บัญชีนี้รวมอยู่ · null = ไม่ใช่ประเภทการลงทุน */
export function classOfCoa(coaCode: string): AssetClass | null {
  for (const c of ASSET_CLASSES) {
    if (c.categories.some((cat) => cat.coaCodes.includes(coaCode))) return c;
  }
  return null;
}

/**
 * ตรวจว่าการจับคู่บัญชีกับหมวดใหญ่ครบและไม่ทับกัน
 *
 * ใช้ในเทสต์ · บัญชีสินทรัพย์ที่หลุดทั้งสองทาง แปลว่ายอดของมันจะหายจากมุมมอง
 * ประเภทการลงทุน โดยที่งบดุลยังลงตัว — เป็นความผิดพลาดที่มองไม่เห็น
 */
export function findAssetClassGaps(): {
  missing: string[];
  duplicated: string[];
  unknown: string[];
  bothWays: string[];
} {
  const mapped = new Map<string, number>();
  for (const c of ASSET_CLASSES) {
    for (const cat of c.categories) {
      for (const code of cat.coaCodes) mapped.set(code, (mapped.get(code) ?? 0) + 1);
    }
  }
  const assetCodes = COA.filter((a) => a.type === "asset").map((a) => a.code);
  const known = new Set(COA.map((a) => a.code));

  return {
    missing: assetCodes.filter((c) => !mapped.has(c) && !(c in UNCLASSIFIED_ASSET_COA)),
    duplicated: [...mapped.entries()].filter(([, n]) => n > 1).map(([c]) => c),
    unknown: [...mapped.keys()].filter((c) => !known.has(c)),
    bothWays: [...mapped.keys()].filter((c) => c in UNCLASSIFIED_ASSET_COA),
  };
}
