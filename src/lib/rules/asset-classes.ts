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

/**
 * **ทรัพย์ชิ้นนี้ถัวเฉลี่ยต้นทุนกับชิ้นอื่นได้หรือไม่** (ลูกพี่สั่ง 25/10)
 *
 * > "แยกทรัพย์สินแม้จะอยู่คอนโดเดียวกัน แต่คนละห้องก็แยก
 * >  **จะไม่นำต้นทุนมาคำนวณหรือเฉลี่ยเด็ดขาด ไม่ใช่หุ้นหรือคริปโต**"
 *
 * - `unique`   = **ทรัพย์ชิ้นเดียว** มีต้นทุนของตัวเอง · กำไรตอนขาย =
 *   ราคาขาย − ต้นทุนของชิ้นนั้นเอง · **ห้ามถัวเฉลี่ยกับชิ้นอื่นทุกกรณี**
 *   แม้อยู่คอนโดเดียวกัน ตึกเดียวกัน เจ้าของเดียวกัน
 * - `fungible` = **แทนกันได้จริง** ทุกหน่วยเหมือนกันหมด (หุ้นตัวเดียวกัน · ทองคำ ·
 *   คริปโตเหรียญเดียวกัน) → คิดต้นทุน**ถัวเฉลี่ยถ่วงน้ำหนัก**ตาม D-112
 *
 * **คำนี้หมายถึง "แทนกันได้ในแง่ต้นทุน" เท่านั้น** ไม่ใช่เรื่องสภาพคล่องหรือ
 * การแลกเปลี่ยนในโลกจริง · ตัวที่ไม่เดินผ่านเส้นทางต้นทุน/ล็อตเลย (เงินสด)
 * จึงเป็น `unique` เพราะนั่นคือค่าที่ **ปิด**เส้นทางถัวเฉลี่ย
 *
 * **ค่าตั้งต้นคือ `unique` เสมอ** — เผลอแล้วได้ "ห้ามเฉลี่ย" ไม่ใช่ "เฉลี่ยได้"
 * (ฝั่ง DB คอลัมน์ `asset_categories.fungibility` ก็ `default 'unique'` ตัวเดียวกัน)
 *
 * **ข้อยกเว้นโรงแรมของ D-112 ไม่ขัดกับเรื่องนี้** — "โรงแรมนับทั้งตึกเป็นชิ้นเดียว
 * ไม่แยกห้อง" เป็นเรื่องของ **จะสร้างแถวใน `assets` กี่แถว** ไม่ใช่เรื่องการเฉลี่ย
 * ตึกทั้งตึก = หนึ่งแถว = `unique` เหมือนคอนโดรายห้องที่เป็นหนึ่งแถวต่อห้อง
 */
export type Fungibility = "fungible" | "unique";

export type AssetCategory = {
  code: string;
  nameTh: string;
  nameEn: string;
  /** รหัสบัญชีในผังที่ยอดของหมวดนี้ไปรวมอยู่ */
  coaCodes: string[];
  /**
   * **ถัวเฉลี่ยต้นทุนได้หรือไม่** — บังคับระบุทุกหมวด (ไม่มี optional)
   *
   * อยู่ที่ **หมวดย่อย** ไม่ใช่ที่ `assets` โดยตั้งใจ (D-115): ด่านที่ตัดสินเรื่องเงิน
   * ต้องอ่านจาก**ข้อมูลอ้างอิง** ไม่ใช่ฟิลด์ที่ผู้สร้างทรัพย์เลือกได้
   * ถ้าอยู่ที่ `assets` คนกรอกจะติดป้าย "คอนโดห้องนี้ fungible" ได้ แล้วด่านทั้งชุด
   * ที่อ่านป้ายนั้นก็เชื่อตาม = รูเดิมรูปที่สี่
   */
  fungibility: Fungibility;
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
        fungibility: "unique",
        note: "กิจการที่เราลงทุนและมีส่วนในการบริหาร · แต่ละกิจการมีต้นทุนของตัวเอง ถัวเฉลี่ยข้ามกิจการไม่ได้",
      },
      {
        code: "BIZ_RELATED",
        nameTh: "บริษัทในเครือ",
        nameEn: "Related company",
        coaCodes: ["1710"],
        fungibility: "unique",
        note:
          "หุ้นของบริษัทในเครือถือเป็นก้อนเดียวต่อบริษัท ไม่มีตลาดและไม่มีการซื้อเพิ่มเป็นล็อต — " +
          "ถ้าวันหนึ่งต้องซื้อเพิ่มหลายครั้งจริง ให้ตัดสินใจเป็น D-xxx แล้วแก้ที่ตารางนี้ที่เดียว",
      },
    ],
  },
  {
    code: "RE",
    name: "Real Estate",
    nameTh: "อสังหาริมทรัพย์",
    sortOrder: 20,
    categories: [
      /**
       * **อสังหาฯ ทุกหมวดเป็น `unique` ทั้งหมด** (ลูกพี่สั่ง 25/10)
       * คนละห้องในคอนโดเดียวกันก็คนละชิ้น · ต้นทุนของห้องไหนก็ของห้องนั้น
       * โรงแรมที่นับทั้งตึกเป็นชิ้นเดียว (D-112) ก็ยังเป็น "หนึ่งชิ้น" เหมือนกัน
       */
      {
        code: "RE_RENTAL",
        nameTh: "ปล่อยเช่า",
        nameEn: "Rental",
        coaCodes: ["1500", "1510"],
        fungibility: "unique",
      },
      {
        code: "RE_FOR_SALE",
        nameTh: "รอขาย",
        nameEn: "Held for sale",
        coaCodes: [],
        fungibility: "unique",
      },
      {
        code: "RE_PROJECT",
        nameTh: "โครงการระหว่างพัฒนา",
        nameEn: "Project",
        coaCodes: [],
        fungibility: "unique",
      },
      {
        code: "RE_RENOVATE",
        nameTh: "รอปรับปรุง",
        nameEn: "Awaiting renovation",
        coaCodes: [],
        fungibility: "unique",
      },
      {
        code: "RE_SRR",
        nameTh: "ขายฝาก / รับจำนอง",
        nameEn: "Redemption & mortgage contracts",
        coaCodes: ["1400", "1410"],
        fungibility: "unique",
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
      /**
       * **หมวดที่ถัวเฉลี่ยได้จริง** — ทุกหน่วยของหลักทรัพย์ตัวเดียวกันเหมือนกันหมด
       * จึงคิดต้นทุนถัวเฉลี่ยถ่วงน้ำหนักตาม D-112 (ยังเก็บทุกล็อตไว้ตรวจย้อน)
       */
      {
        code: "PAPER_STOCK",
        nameTh: "หุ้น",
        nameEn: "Stocks",
        coaCodes: ["1700"],
        fungibility: "fungible",
      },
      { code: "PAPER_ETF", nameTh: "ETF", nameEn: "ETF", coaCodes: [], fungibility: "fungible" },
      {
        code: "PAPER_FUND",
        nameTh: "กองทุน",
        nameEn: "Mutual fund",
        coaCodes: [],
        fungibility: "fungible",
      },
      {
        code: "PAPER_BOND",
        nameTh: "พันธบัตร / หุ้นกู้",
        nameEn: "Bonds",
        coaCodes: [],
        fungibility: "fungible",
      },
      {
        code: "PAPER_LOAN",
        nameTh: "สัญญาเงินให้กู้ยืม",
        nameEn: "Loan agreement",
        coaCodes: ["1300"],
        fungibility: "unique",
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
      { code: "COM_GOLD", nameTh: "ทองคำ", nameEn: "Gold", coaCodes: ["1720"], fungibility: "fungible" },
      {
        code: "COM_CRYPTO",
        nameTh: "คริปโต",
        nameEn: "Crypto",
        coaCodes: [],
        fungibility: "fungible",
        note:
          "ลูกพี่ยืนยัน 27/09 ให้อยู่ Commodity & Cash — ถือตัวสินทรัพย์เอง ไม่มีผู้ออก " +
          "และไม่มีกระแสเงินสด เหมือนทองคำ ไม่ใช่สิทธิเรียกร้องแบบหุ้น/พันธบัตร",
      },
      /**
       * เงินสด **ไม่เดินผ่านเส้นทางต้นทุน/ล็อตเลย** (ยอดมาจาก `bank_accounts`)
       * จึงตั้งเป็น `unique` ซึ่งเป็นค่าที่ **ปิด**เส้นทางถัวเฉลี่ย — ไม่ใช่เพราะ
       * เงินบาทแทนกันไม่ได้ แต่เพราะไม่มีกรณีที่ควรเฉลี่ยต้นทุนเงินสดเลย
       * (ผลต่างอัตราของบัญชี FCD คิดที่ `fn_fx_entry_currency` + 3410 คนละเส้นทาง)
       */
      {
        code: "COM_CASH",
        nameTh: "เงินสดและเงินฝาก",
        nameEn: "Cash & deposits",
        coaCodes: ["1100"],
        fungibility: "unique",
      },
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
  /**
   * ภาษีถูกหัก ณ ที่จ่ายรอเครดิต (D-111 ข้อ 1) — **ไม่ใช่การลงทุน**
   *
   * เป็นเงินของเราที่กรมสรรพากรถือไว้แทน รอเอาไปหักภาษีปลายปี
   * ถ้าเอาไปรวมในหมวดใหญ่ NAV จะบวมด้วยเครดิตภาษีที่ยังใช้ไม่ได้
   * และหน้าพอร์ตจะแสดงว่าบ้านนี้ "ลงทุนใน" ภาษี ซึ่งอ่านไม่รู้เรื่อง
   */
  "1800": "ภาษีถูกหัก ณ ที่จ่ายรอเครดิต — เครดิตภาษีรอใช้ ไม่ใช่การลงทุน",
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

/**
 * **ถัวเฉลี่ยต้นทุนได้หรือไม่ ของหมวดย่อยหนึ่ง** — ตัวเดียวที่ทั้งระบบถาม
 *
 * ไม่รู้จักหมวด · ไม่ได้ส่งหมวดมา · หมวดว่าง → **`"unique"`**
 * ไม่ใช่ throw และไม่ใช่ `"fungible"` โดยตั้งใจ:
 *   - `"fungible"` คือคำตอบที่ **เปิด**ประตูถัวเฉลี่ย เดาผิดทางนั้นแปลว่า
 *     ต้นทุนคอนโดสองห้องถูกเฉลี่ยเข้าหากันเงียบๆ ซึ่งคือสิ่งที่ลูกพี่ห้าม
 *   - throw ที่นี่จะทำให้หน้าที่แค่ "แสดงรายการทรัพย์" พังทั้งหน้า
 *     ส่วนการ**ปฏิเสธ**เป็นหน้าที่ของ `lib/ledger` ตอนจะคิดต้นทุนจริง
 *     (ที่นั่นไม่รู้จักทรัพย์ = `PostingError` เพราะตอนนั้นข้อมูลต้องครบ)
 *
 * ตรงกับฝั่ง DB ตัวต่อตัว: `asset_categories.fungibility default 'unique'`
 * และ `fn_asset_fungibility()` คืน `'unique'` เมื่อหาหมวดไม่เจอ
 */
export function fungibilityOfCategory(code: string | null | undefined): Fungibility {
  if (typeof code !== "string" || code.trim() === "") return "unique";
  return findCategory(code.trim())?.fungibility ?? "unique";
}

/** ถัวเฉลี่ยได้ไหม — รูปบูลีนของ `fungibilityOfCategory()` (ความจริงเดียวกัน) */
export function isFungibleCategory(code: string | null | undefined): boolean {
  return fungibilityOfCategory(code) === "fungible";
}

/**
 * หมวดย่อยที่ถัวเฉลี่ยได้ทั้งหมด — เรียงคงที่ ใช้ในเทสต์และในไฟล์ migration
 * ที่ seed คอลัมน์ `asset_categories.fungibility` (เทสต์เทียบสองฝั่งให้ตรงกัน)
 */
export function fungibleCategoryCodes(): string[] {
  return allCategories()
    .filter((c) => c.fungibility === "fungible")
    .map((c) => c.code)
    .sort();
}

/** หมวดย่อยที่เป็นทรัพย์ชิ้นเดียว — ส่วนเติมเต็มของ `fungibleCategoryCodes()` */
export function uniqueCategoryCodes(): string[] {
  return allCategories()
    .filter((c) => c.fungibility === "unique")
    .map((c) => c.code)
    .sort();
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
