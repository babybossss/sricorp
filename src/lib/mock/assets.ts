/** ทรัพย์ที่ผูกกับรายการได้ */

/** งวดของรายการประจำ — ตรงกับที่ลูกพี่ระบุ 06/10 */
export type Frequency = "monthly" | "quarterly" | "semiannual" | "annual";

export const FREQUENCY_LABEL: Record<Frequency, string> = {
  monthly: "รายเดือน",
  quarterly: "ราย 3 เดือน",
  semiannual: "ราย 6 เดือน",
  annual: "รายปี",
};

/** จำนวนครั้งต่อปี — ใช้แปลงยอดต่องวดเป็นยอดต่อปี */
export const PER_YEAR: Record<Frequency, number> = {
  monthly: 12,
  quarterly: 4,
  semiannual: 2,
  annual: 1,
};

/**
 * รายการประจำของทรัพย์หนึ่งชิ้น — ต้นทางของ Auto-Key (D-067)
 *
 * `subCode` อ้างหมวดย่อยในตารางกฎ ไม่ใช่ข้อความอิสระ เพราะคู่บัญชีต้องมาจากที่เดียว
 */
export type RecurringPlan = {
  id: string;
  subCode: string;
  label: string;
  amount: number;
  frequency: Frequency;
  direction: "income" | "expense";
};

export type AssetRef = {
  id: string;
  name: string;
  category: string;
  ownerId: string;
  cost: number;
  /** active = ยังสร้างรายได้/ยังใช้งานอยู่ · inactive = หยุดไว้ ไม่ออกรายการประจำ */
  status: "active" | "inactive";
  /** เหตุผลที่หยุด — แสดงให้คนอ่านรู้ว่าทำไมทรัพย์ชิ้นนี้ไม่มีรายได้เดือนนี้ */
  statusNote?: string;
  /** รูปทรัพย์ — ชิ้นละหนึ่งรูป ใช้เป็นไอคอนเล็กหน้าชื่อให้จำได้เร็วกว่าอ่านชื่อ */
  photo?: string;
  recurring: RecurringPlan[];
};

export const ASSETS: AssetRef[] = [
  {
    id: "rent1",
    photo: "/asset-photos/rent1.svg",
    name: "คอนโดตัวอย่าง C",
    category: "Real Estate · ปล่อยเช่า",
    ownerId: "thanakorn",
    cost: 2450000,
    status: "active",
    recurring: [
      { id: "r1a", subCode: "inc.rent", label: "ค่าเช่ารายเดือน", amount: 12000, frequency: "monthly", direction: "income" },
      { id: "r1b", subCode: "exp.common", label: "ค่าส่วนกลาง", amount: 9800, frequency: "annual", direction: "expense" },
      { id: "r1c", subCode: "exp.repair", label: "ล้างแอร์", amount: 1200, frequency: "quarterly", direction: "expense" },
    ],
  },
  {
    id: "rent2",
    photo: "/asset-photos/rent2.svg",
    name: "คอนโดตัวอย่าง A",
    category: "Real Estate · ปล่อยเช่า",
    ownerId: "corp",
    cost: 2900000,
    status: "active",
    recurring: [
      { id: "r2a", subCode: "inc.rent", label: "ค่าเช่ารายเดือน", amount: 18500, frequency: "monthly", direction: "income" },
      { id: "r2b", subCode: "exp.common", label: "ค่าส่วนกลาง", amount: 12400, frequency: "annual", direction: "expense" },
      { id: "r2c", subCode: "exp.repair", label: "ล้างแอร์ 2 ห้อง", amount: 2400, frequency: "quarterly", direction: "expense" },
    ],
  },
  {
    id: "rent3",
    photo: "/asset-photos/rent3.svg",
    name: "อาคารพาณิชย์ตัวอย่าง E",
    category: "Real Estate · ปล่อยเช่า",
    ownerId: "corp",
    cost: 5450000,
    status: "inactive",
    statusNote: "ผู้เช่าย้ายออก 31/08 · รอปรับปรุงก่อนปล่อยใหม่",
    recurring: [
      { id: "r3a", subCode: "inc.rent", label: "ค่าเช่ารายเดือน", amount: 45000, frequency: "monthly", direction: "income" },
      { id: "r3b", subCode: "exp.utilities", label: "ค่าน้ำ-ค่าไฟส่วนกลาง", amount: 3200, frequency: "monthly", direction: "expense" },
    ],
  },
  {
    id: "th_b",
    photo: "/asset-photos/th_b.svg",
    name: "ทาวน์โฮมตัวอย่าง B",
    category: "Real Estate · ขายฝาก",
    ownerId: "corp",
    cost: 3100000,
    status: "active",
    recurring: [
      { id: "r4a", subCode: "inc.interest_srr", label: "ดอกเบี้ยขายฝาก", amount: 36000, frequency: "monthly", direction: "income" },
    ],
  },
  {
    id: "land_d",
    photo: "/asset-photos/land_d.svg",
    name: "ที่ดินตัวอย่าง D",
    category: "Real Estate · ขายฝาก",
    ownerId: "corp",
    cost: 1800000,
    status: "active",
    recurring: [
      { id: "r5a", subCode: "inc.interest_srr", label: "ดอกเบี้ยขายฝาก", amount: 21000, frequency: "monthly", direction: "income" },
      { id: "r5b", subCode: "exp.tax", label: "ภาษีที่ดิน", amount: 7400, frequency: "annual", direction: "expense" },
    ],
  },
];

/**
 * ยอดต่อปีของทรัพย์ชิ้นหนึ่ง
 *
 * ทรัพย์ที่ `inactive` คืน 0 **โดยตั้งใจ** — ห้องที่ไม่มีคนเช่าไม่ควรมีรายได้คาดการณ์
 * ถ้านับรวม ตัวเลขคาดการณ์ทั้งบ้านจะสูงกว่าความจริงตลอดเวลา และ Auto-Key
 * ก็จะออกใบค่าเช่าของห้องว่างทุกเดือน (D-067)
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
 * ยอดต่อ**เดือน** — ลูกพี่ขอให้ทุกตัวเลขในหน้าบริหารเทียบเป็นรายเดือนเหมือนกันหมด
 *
 * คิดจากยอดต่อปีหารสิบสอง ไม่ใช่ "เอาเฉพาะรายการรายเดือน" — ค่าส่วนกลางรายปี
 * กับค่าล้างแอร์ราย 3 เดือน ก็เป็นภาระจริงของทุกเดือน แค่จ่ายเป็นก้อน
 * ถ้านับเฉพาะรายการรายเดือน ตัวเลขจะดูดีเกินจริงในเดือนที่ไม่มีบิลก้อนใหญ่
 */
export function monthlyFor(a: AssetRef): { income: number; expense: number; net: number } {
  const y = yearlyFor(a);
  return { income: y.income / 12, expense: y.expense / 12, net: y.net / 12 };
}

/** ยอดต่อเดือนของรายการประจำหนึ่งแผน */
export function monthlyOf(r: RecurringPlan): number {
  return (r.amount * PER_YEAR[r.frequency]) / 12;
}
