/**
 * ทะเบียนทรัพย์ (mock) — โครงข้อมูลอ้างอิงจากไฟล์จริงของลูกพี่
 * `SRI_CORP_ 2 ASSET HOLDING & BALANCE SHEET.xlsx` (6 ชีท)
 *
 * **สองแกนที่ต้องแยกให้ขาด** — ไฟล์เดิมปนกันอยู่ในคำว่า "ชนิด" คำเดียว:
 * - `kind`    = ทรัพย์**เป็นอะไร** (คอนโด บ้าน ที่ดิน อาคารพาณิชย์ คลังสินค้า)
 * - `holding` = เรา**ถือไว้ทำอะไร** (ปล่อยเช่า ขายฝาก จำนอง ปล่อยกู้ รอขาย)
 *
 * ที่ต้องแยกเพราะคอนโดหนึ่งห้องวันนี้ปล่อยเช่า พรุ่งนี้เอาไปจำนองได้ — ชนิดไม่เปลี่ยน
 * แต่การลงบัญชีเปลี่ยนทั้งหมด (1500 อสังหาฯ ↔ 1400 ขายฝาก ↔ 1410 จำนอง)
 * ถ้าเก็บรวมเป็นคำเดียว จะแยกรายงานตามประเภทการถือไม่ได้เลย
 */

export type Frequency = "monthly" | "quarterly" | "semiannual" | "annual";

export const FREQUENCY_LABEL: Record<Frequency, string> = {
  monthly: "รายเดือน",
  quarterly: "ราย 3 เดือน",
  semiannual: "ราย 6 เดือน",
  annual: "รายปี",
};

export const PER_YEAR: Record<Frequency, number> = { monthly: 12, quarterly: 4, semiannual: 2, annual: 1 };

/** ทรัพย์เป็นอะไร — ชุดนี้มาจากค่าที่โผล่จริงในไฟล์ของลูกพี่ */
export type AssetKind = "condo" | "house" | "townhome" | "land" | "commercial" | "warehouse";
export const KIND_LABEL: Record<AssetKind, string> = {
  condo: "คอนโด",
  house: "บ้าน",
  townhome: "ทาวน์โฮม",
  land: "ที่ดินเปล่า",
  commercial: "อาคารพาณิชย์",
  warehouse: "คลังสินค้า",
};

/** ถือไว้ทำอะไร — ตัวนี้คือสิ่งที่ลูกพี่เรียกว่า "ประเภททรัพย์" ตอนกรองและดูสัดส่วน */
export type HoldingType = "rental" | "srr" | "mortgage" | "loan" | "for_sale";
export const HOLDING_LABEL: Record<HoldingType, string> = {
  rental: "ปล่อยเช่า",
  srr: "สัญญาขายฝาก",
  mortgage: "สัญญาจำนอง",
  loan: "ปล่อยกู้ถือโฉนด",
  for_sale: "รอขาย",
};

export type RecurringPlan = {
  id: string;
  /** หมวดย่อยในตารางกฎ — คู่บัญชีต้องมาจากที่เดียว ไม่ใช่ข้อความอิสระ */
  subCode: string;
  label: string;
  amount: number;
  frequency: Frequency;
  direction: "income" | "expense";
};

export type AssetRef = {
  id: string;
  name: string;
  kind: AssetKind;
  holding: HoldingType;
  ownerId: string;
  /** ต้นทุน = ราคาซื้อ + รีโนเวทที่บันทึกเป็นทุน · สำหรับขายฝาก/จำนองคือเงินต้นที่ปล่อยไป */
  cost: number;
  status: "active" | "inactive";
  statusNote?: string;
  photo?: string;
  recurring: RecurringPlan[];

  /** ทำเล — ไม่โชว์ในหน้ารวม เปิดดูในแผงรายละเอียด */
  location?: {
    province?: string;
    address?: string;
    /**
     * ลิงก์ Google Maps ที่ผู้ใช้วางมา — **นี่คือสิ่งที่คนกรอก**
     * ไฟล์เดิมของลูกพี่มีทั้งลิงก์เต็ม ลิงก์ย่อ พิกัด DMS และชื่อสถานที่เฉยๆ ปนกัน
     */
    mapsUrl?: string;
    /** พิกัดที่ระบบดึงออกมาเอง — ไม่ให้คนกรอก เพราะพิมพ์ผิดแล้วทรัพย์ไปอยู่ผิดจังหวัด */
    lat?: number;
    lng?: number;
  };

  /** เอกสารสิทธิ์ */
  legal?: {
    /** ชื่อหลังโฉนด — อาจไม่ใช่ผู้ถือตามบัญชี (ถือแทน) */
    titleDeedName?: string;
    landOffice?: string;
    sizeLabel?: string;
    deedNo?: string;
  };

  /** มูลค่า — ต้นทุนอยู่ที่ `cost` ส่วนนี้คือราคาที่ประเมินทีหลัง */
  valuation?: {
    appraised?: number;
    market?: number;
    asOf?: string;
  };

  /** ภาระกับธนาคาร — ยอดค้างเป็นหนี้สิน ไม่ใช่ตัวหักมูลค่าทรัพย์ */
  bank?: { outstanding?: number; instalmentPerMonth?: number; lender?: string };

  /** ผู้เช่า (เฉพาะทรัพย์ปล่อยเช่า) */
  tenancy?: {
    tenantName?: string;
    tenantPhone?: string;
    depositAmount?: number;
    contractStart?: string;
    contractEnd?: string;
  };

  /** สัญญาขายฝาก/จำนอง/ปล่อยกู้ */
  contract?: {
    counterparty?: string;
    referredBy?: string;
    principal?: number;
    /** ดอกเบี้ยต่อเดือน เช่น 0.0125 = 1.25% */
    ratePerMonth?: number;
    prepaidMonths?: number;
    redemptionValue?: number;
    startDate?: string;
    endDate?: string;
    nextDueDate?: string;
    noticeWindow?: string;
    noticeSent?: boolean;
  };

  note?: string;
};

export const ASSETS: AssetRef[] = [
  {
    id: "rent1",
    name: "คอนโดตัวอย่าง C",
    kind: "condo",
    holding: "rental",
    ownerId: "thanakorn",
    cost: 2450000,
    status: "active",
    location: { province: "กรุงเทพมหานคร", address: "พหลโยธิน 24", mapsUrl: "https://www.google.com/maps/place/SRI/@13.8200000,100.5600000,17z/data=!4m6!3m5!1s0x0:0x0!8m2!3d13.8186!4d100.5612", lat: 13.8186, lng: 100.5612 },
    legal: { titleDeedName: "ธนากร", landOffice: "สำนักงานที่ดินกรุงเทพมหานคร สาขาจตุจักร", sizeLabel: "28 ตร.ม." },
    valuation: { appraised: 2600000, market: 2850000, asOf: "30/06/2026" },
    bank: { outstanding: 980000, instalmentPerMonth: 4300, lender: "SCB" },
    tenancy: { tenantName: "คุณวิ", tenantPhone: "08x-xxx-1234", depositAmount: 24000, contractStart: "01/01/2026", contractEnd: "31/12/2026" },
    recurring: [
      { id: "r1a", subCode: "inc.rent", label: "ค่าเช่ารายเดือน", amount: 12000, frequency: "monthly", direction: "income" },
      { id: "r1b", subCode: "exp.common", label: "ค่าส่วนกลาง", amount: 9800, frequency: "annual", direction: "expense" },
      { id: "r1c", subCode: "exp.repair", label: "ล้างแอร์", amount: 1200, frequency: "quarterly", direction: "expense" },
    ],
  },
  {
    id: "rent2",
    name: "คอนโดตัวอย่าง A",
    kind: "condo",
    holding: "rental",
    ownerId: "corp",
    cost: 2900000,
    status: "active",
    location: { province: "สมุทรปราการ", address: "เทพารักษ์", mapsUrl: "13° 33' 42.5124\" N 100° 36' 57.2256\" E", lat: 13.5618, lng: 100.6159 },
    legal: { titleDeedName: "SRI Corporation", landOffice: "สำนักงานที่ดินจังหวัดสมุทรปราการ", sizeLabel: "35 ตร.ม." },
    valuation: { appraised: 2900000, market: 3250000, asOf: "30/06/2026" },
    tenancy: { tenantName: "คุณกรวิชญ์", tenantPhone: "08x-xxx-5469", depositAmount: 37000, contractStart: "01/03/2026", contractEnd: "28/02/2027" },
    recurring: [
      { id: "r2a", subCode: "inc.rent", label: "ค่าเช่ารายเดือน", amount: 18500, frequency: "monthly", direction: "income" },
      { id: "r2b", subCode: "exp.common", label: "ค่าส่วนกลาง", amount: 12400, frequency: "annual", direction: "expense" },
      { id: "r2c", subCode: "exp.repair", label: "ล้างแอร์ 2 ห้อง", amount: 2400, frequency: "quarterly", direction: "expense" },
    ],
  },
  {
    id: "rent3",
    name: "อาคารพาณิชย์ตัวอย่าง E",
    kind: "commercial",
    holding: "rental",
    ownerId: "corp",
    cost: 5450000,
    status: "inactive",
    statusNote: "ผู้เช่าย้ายออก 31/08 · รอปรับปรุงก่อนปล่อยใหม่",
    location: { province: "ปทุมธานี", address: "ลำลูกกา คลอง 2", mapsUrl: "https://www.google.com/maps/@13.9876,100.7123,16z", lat: 13.9876, lng: 100.7123 },
    legal: { titleDeedName: "SRI Corporation", landOffice: "สำนักงานที่ดินจังหวัดปทุมธานี", sizeLabel: "2 คูหา · 32 ตร.ว." },
    valuation: { appraised: 5200000, market: 5800000, asOf: "30/06/2026" },
    bank: { outstanding: 2150000, instalmentPerMonth: 18500, lender: "KBank" },
    recurring: [
      { id: "r3a", subCode: "inc.rent", label: "ค่าเช่ารายเดือน", amount: 45000, frequency: "monthly", direction: "income" },
      { id: "r3b", subCode: "exp.utilities", label: "ค่าน้ำ-ค่าไฟส่วนกลาง", amount: 3200, frequency: "monthly", direction: "expense" },
    ],
  },
  {
    id: "th_b",
    name: "ทาวน์โฮมตัวอย่าง B",
    kind: "townhome",
    holding: "srr",
    ownerId: "corp",
    cost: 3100000,
    status: "active",
    location: { province: "กรุงเทพมหานคร", address: "ลาดพร้าว 101", mapsUrl: "https://maps.google.com/?q=13.7847,100.6267", lat: 13.7847, lng: 100.6267 },
    legal: { titleDeedName: "สุธี", landOffice: "สำนักงานที่ดินกรุงเทพมหานคร สาขาบางกะปิ", sizeLabel: "24 ตร.ว." },
    valuation: { appraised: 3400000, market: 4100000, asOf: "30/06/2026" },
    contract: {
      counterparty: "คุณจิมมี่",
      referredBy: "นัท Winner",
      principal: 3100000,
      ratePerMonth: 0.0125,
      prepaidMonths: 12,
      redemptionValue: 3100000,
      startDate: "04/03/2026",
      endDate: "04/03/2027",
      nextDueDate: "04/11/2026",
      noticeWindow: "04/09/2026 – 04/11/2026",
      noticeSent: true,
    },
    recurring: [{ id: "r4a", subCode: "inc.interest_srr", label: "ดอกเบี้ยขายฝาก", amount: 36000, frequency: "monthly", direction: "income" }],
  },
  {
    id: "land_d",
    name: "ที่ดินตัวอย่าง D",
    kind: "land",
    holding: "mortgage",
    ownerId: "corp",
    cost: 1800000,
    status: "active",
    location: { province: "เชียงใหม่", address: "สันทราย", mapsUrl: "https://maps.app.goo.gl/Fhf2m5K2jCUkj3aL" },
    legal: { titleDeedName: "SRI Corporation", landOffice: "สำนักงานที่ดินจังหวัดเชียงใหม่", sizeLabel: "1 ไร่ 2 งาน" },
    valuation: { appraised: 2100000, market: 2400000, asOf: "30/06/2026" },
    contract: {
      counterparty: "คุณโอ้ต",
      principal: 1800000,
      ratePerMonth: 0.0117,
      prepaidMonths: 2,
      redemptionValue: 1800000,
      startDate: "09/07/2026",
      endDate: "09/07/2027",
      nextDueDate: "09/11/2026",
      noticeWindow: "09/01/2027 – 09/03/2027",
      noticeSent: false,
    },
    recurring: [
      { id: "r5a", subCode: "inc.interest_mortgage", label: "ดอกเบี้ยจำนอง", amount: 21000, frequency: "monthly", direction: "income" },
      { id: "r5b", subCode: "exp.tax", label: "ภาษีที่ดิน", amount: 7400, frequency: "annual", direction: "expense" },
    ],
  },
];

/**
 * ยอดต่อปี — ทรัพย์ที่ `inactive` คืน 0 **โดยตั้งใจ**
 *
 * ห้องที่ไม่มีคนเช่าไม่ควรมีรายได้คาดการณ์ ถ้านับรวม ตัวเลขทั้งบ้านจะสูงกว่าความจริงตลอดเวลา
 * และ Auto-Key (D-067) ก็จะออกใบค่าเช่าของห้องว่างทุกเดือน
 */
export function yearlyFor(a: AssetRef): { income: number; expense: number; net: number } {
  if (a.status !== "active") return { income: 0, expense: 0, net: 0 };
  let income = 0;
  let expense = 0;
  for (const r of a.recurring) {
    const yearly = r.amount * PER_YEAR[r.frequency];
    if (r.direction === "income") income += yearly;
    else expense += yearly;
  }
  return { income, expense, net: income - expense };
}

/**
 * ยอดต่อ**เดือน**
 *
 * คิดจากยอดต่อปีหารสิบสอง ไม่ใช่ "เอาเฉพาะรายการรายเดือน" — ค่าส่วนกลางรายปี
 * กับค่าล้างแอร์ราย 3 เดือนเป็นภาระจริงของทุกเดือน แค่จ่ายเป็นก้อน
 */
export function monthlyFor(a: AssetRef): { income: number; expense: number; net: number } {
  const y = yearlyFor(a);
  return { income: y.income / 12, expense: y.expense / 12, net: y.net / 12 };
}

export function monthlyOf(r: RecurringPlan): number {
  return (r.amount * PER_YEAR[r.frequency]) / 12;
}

/**
 * มูลค่าปัจจุบัน — ราคาตลาด ถ้าไม่มีใช้ราคาประเมิน ถ้าไม่มีอีกใช้ต้นทุน
 *
 * ไล่ลำดับแบบนี้เพื่อให้ช่องนี้**ไม่เคยว่าง** คอลัมน์มูลค่าที่ว่างบ้างไม่ว่างบ้าง
 * จะรวมยอดท้ายตารางไม่ได้ และคนอ่านจะไม่รู้ว่าศูนย์แปลว่าไม่มีมูลค่าหรือยังไม่ได้ประเมิน
 */
export function currentValue(a: AssetRef): { value: number; basis: "market" | "appraised" | "cost" } {
  if (a.valuation?.market) return { value: a.valuation.market, basis: "market" };
  if (a.valuation?.appraised) return { value: a.valuation.appraised, basis: "appraised" };
  return { value: a.cost, basis: "cost" };
}

export const VALUE_BASIS_LABEL: Record<"market" | "appraised" | "cost", string> = {
  market: "ราคาตลาด",
  appraised: "ราคาประเมินกรมที่ดิน",
  cost: "ยังไม่ประเมิน — ใช้ต้นทุน",
};

/**
 * ผลตอบแทนต่อปีคิดจาก**ต้นทุน** ไม่ใช่มูลค่าปัจจุบัน
 *
 * ต้นทุนคือเงินที่จ่ายออกไปจริง ตอบคำถามว่า "เงินก้อนที่ลงไปให้ผลเท่าไร"
 * ถ้าหารด้วยมูลค่าปัจจุบัน ทรัพย์ที่ราคาขึ้นจะดูผลตอบแทนแย่ลงทั้งที่ค่าเช่าเท่าเดิม
 * ซึ่งอ่านผิดความหมาย · ฝั่งที่อยากรู้ว่า "ถ้าซื้อวันนี้ได้เท่าไร" เป็นอีกตัวเลขหนึ่ง
 */
export function yieldPct(a: AssetRef): number | null {
  if (a.status !== "active" || !a.cost) return null;
  return (yearlyFor(a).net / a.cost) * 100;
}
