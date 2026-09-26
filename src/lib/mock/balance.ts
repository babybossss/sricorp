export type TreeNode = {
  id: string;
  name: string;
  ownerLabel?: string;
  value: number;
  cost?: number | null;
  gl?: number;
  src?: string;
  yield?: string;
  status?: string;
  statusTone?: "wait" | "saved" | "done" | "late" | "off";
  assetId?: string;
  children?: TreeNode[];
};

export const TREE: TreeNode[] = [
  {
    id: "assets",
    name: "สินทรัพย์",
    value: 84415920,
    cost: null,
    children: [
      {
        id: "biz",
        name: "Businesses",
        value: 18000000,
        cost: 17000000,
        gl: 1000000,
        children: [
          { id: "f1", name: "เงินลงทุนในกิจการ", ownerLabel: "SRI Corporation", value: 18000000, cost: 17000000, gl: 1000000, yield: "8.2%", src: "มูลค่าตามบัญชี" },
        ],
      },
      {
        id: "re",
        name: "Real Estate",
        value: 39800000,
        cost: 36600000,
        gl: 3200000,
        children: [
          { id: "re1", name: "RE รอขาย", ownerLabel: "SRI Corporation", value: 8500000, cost: 7400000, gl: 1100000, src: "ประเมินภายใน 08/2026", status: "Active", statusTone: "saved" },
          {
            id: "rent",
            name: "RE ปล่อยเช่า",
            ownerLabel: "หลายเจ้าของ",
            value: 12300000,
            cost: 10800000,
            gl: 1500000,
            yield: "5.9%",
            children: [
              { id: "rent1", name: "คอนโดตัวอย่าง C", ownerLabel: "ธนากร", value: 2780000, cost: 2450000, gl: 330000, yield: "5.2%", src: "ประเมินภายใน 07/2026", status: "Active", statusTone: "done", assetId: "rent1" },
              { id: "rent2", name: "คอนโดตัวอย่าง A", ownerLabel: "SRI Corporation", value: 3120000, cost: 2900000, gl: 220000, yield: "0.0%", src: "ประเมินภายใน 07/2026", status: "ไม่มีรายได้", statusTone: "wait" },
              { id: "rent3", name: "อาคารพาณิชย์ตัวอย่าง E", ownerLabel: "SRI Corporation", value: 6400000, cost: 5450000, gl: 950000, yield: "6.8%", src: "ประเมินภายใน 06/2026", status: "Active", statusTone: "done" },
            ],
          },
          { id: "re3", name: "RE รับจำนอง-ขายฝาก (ลูกหนี้)", ownerLabel: "SRI Corporation", value: 14200000, cost: 14200000, gl: 0, yield: "14.2%", src: "มูลค่าตามสัญญา", status: "Active", statusTone: "done" },
          { id: "re4", name: "RE Project", ownerLabel: "SRI Corporation", value: 3200000, cost: 2900000, gl: 300000, src: "ต้นทุนงานระหว่างทำ", status: "Active", statusTone: "saved" },
          { id: "re5", name: "RE รอปรับปรุง", ownerLabel: "SRI Corporation", value: 1600000, cost: 1300000, gl: 300000, src: "ประเมินภายใน 05/2026", status: "Inactive", statusTone: "off" },
        ],
      },
      {
        id: "paper",
        name: "Paper Asset",
        value: 19750000,
        cost: 18620000,
        gl: 1130000,
        children: [
          { id: "f2", name: "Bond", ownerLabel: "SRI Corporation", value: 6500000, cost: 6300000, gl: 200000, yield: "3.1%", src: "ราคาตลาด 16/09" },
          { id: "f3", name: "Loan Agreement", ownerLabel: "SRI Corporation", value: 7000000, cost: 6800000, gl: 200000, yield: "9.0%", src: "มูลค่าตามสัญญา" },
          { id: "i1", name: "หุ้นไทย", ownerLabel: "ธนากร", value: 2400000, cost: 2150000, gl: 250000, src: "ราคาปิด 08/09", status: "ราคาเก่า 9 วัน", statusTone: "wait" },
          { id: "i2", name: "หุ้น US", ownerLabel: "ธนากร", value: 1850000, cost: 1500000, gl: 350000, src: "ราคาปิด 16/09" },
          { id: "i3", name: "ETF", ownerLabel: "ธนากร", value: 900000, cost: 820000, gl: 80000, src: "ราคาปิด 16/09" },
          { id: "i4", name: "กองทุน", ownerLabel: "ธนากร", value: 1100000, cost: 1050000, gl: 50000, src: "NAV 15/09" },
        ],
      },
      {
        id: "commodity",
        name: "Commodity & Cash",
        value: 6865920,
        cost: null,
        gl: 120000,
        children: [
          {
            id: "cash",
            name: "เงินสดและเงินฝาก",
            value: 6015920,
            cost: null,
            children: [
          { id: "c1", name: "SRI - SCB", ownerLabel: "SRI Corporation", value: 2340120, cost: null, src: "ยอดธนาคาร 17/09" },
          { id: "c2", name: "ธนากร - BBL 888", ownerLabel: "ธนากร", value: 1286500, cost: null, src: "ยอดธนาคาร 17/09" },
          { id: "c3", name: "ธนวินท์ - KBANK", ownerLabel: "ธนวินท์", value: 592400, cost: null, src: "ยอดธนาคาร 17/09" },
          { id: "c3b", name: "ธนวินท์ - BBL", ownerLabel: "ธนวินท์", value: 150000, cost: null, src: "ยอดธนาคาร 17/09" },
          { id: "c4", name: "เบ็ญจพร - BBL", ownerLabel: "เบ็ญจพร", value: 326900, cost: null, src: "ยอดธนาคาร 17/09" },
          { id: "c5", name: "สุธี - TTB", ownerLabel: "สุธี", value: 850000, cost: null, src: "ยอดธนาคาร 17/09" },
          { id: "c6", name: "สุดจิตต์ - BAY", ownerLabel: "สุดจิตต์", value: 420000, cost: null, src: "ยอดธนาคาร 17/09" },
          { id: "c7", name: "เงินสดในมือ SRI", ownerLabel: "SRI Corporation", value: 50000, cost: null, src: "นับเงินสด 17/09" },
            ],
          },
          { id: "i6", name: "ทองคำ", ownerLabel: "ธนากร", value: 500000, cost: 450000, gl: 50000, src: "ราคาสมาคม 17/09" },
          { id: "i5", name: "Crypto", ownerLabel: "ธนากร", value: 350000, cost: 280000, gl: 70000, src: "ราคาตลาด 17/09" },
        ],
      },
    ],
  },
  {
    id: "liab",
    name: "หนี้สิน",
    value: 18700000,
    cost: null,
    children: [
      { id: "l1", name: "เงินกู้ธนาคาร", ownerLabel: "SRI Corporation", value: 12400000, cost: null, src: "ยอดคงเหลือ 17/09" },
      { id: "l2", name: "เงินกู้ยืมกรรมการ", ownerLabel: "SRI Corporation", value: 4300000, cost: null, src: "ยอดคงเหลือ 17/09" },
      { id: "l3", name: "เงินมัดจำผู้เช่า", ownerLabel: "หลายเจ้าของ", value: 1142000, cost: null, src: "ตามสัญญาเช่า" },
      { id: "l4", name: "เจ้าหนี้ค้างจ่าย", ownerLabel: "หลายเจ้าของ", value: 858000, cost: null, src: "ค้างจ่าย 58,200 + ค่าใช้จ่ายรอจ่าย" },
    ],
  },
  {
    id: "eq",
    name: "ส่วนของเจ้าของ",
    value: 65715920,
    cost: null,
    children: [
      { id: "e1", name: "ทุน", value: 30000000, cost: null },
      { id: "e2", name: "กำไรสะสม", value: 30265920, cost: null },
      { id: "e3", name: "ส่วนเปลี่ยนแปลงมูลค่ายุติธรรม (ยังไม่รับรู้)", value: 5450000, cost: null, src: "จากราคาประเมิน/ราคาตลาด" },
    ],
  },
];

export const NAV_BY_HOLDER = [
  { name: "SRI Corporation", color: "#004AAD", value: "฿ 40.2M" },
  { name: "สุธี", color: "#7A5AF8", value: "฿ 6.4M" },
  { name: "ธนากร", color: "#D92D20", value: "฿ 9.8M" },
  { name: "ธนวินท์", color: "#0E7C4A", value: "฿ 3.6M" },
  { name: "เบ็ญจพร", color: "#E93D82", value: "฿ 2.0M" },
  { name: "สุดจิตต์", color: "#CA8A04", value: "฿ 2.2M" },
];

/** สีประจำหมวดใหญ่ของทรัพย์ ใช้ทั้งโดนัทหน้าแรกและกราฟอื่น */
export const CLASS_COLOR: Record<string, string> = {
  biz: "#7A5AF8",
  re: "#004AAD",
  paper: "#0E9F6E",
  commodity: "#F5A524",
};

/**
 * สัดส่วนทรัพย์สินตามหมวดใหญ่ — **คำนวณจาก TREE** ไม่ใช่ตัวเลขที่พิมพ์ไว้
 *
 * เดิมหน้าแรกฮาร์ดโค้ดทั้งชื่อหมวดและเปอร์เซ็นต์ พอเปลี่ยนการจัดหมวดแล้ว
 * โดนัทยังโชว์ของเก่าอยู่โดยไม่มีอะไรฟ้อง — ซึ่งเป็นความผิดพลาดที่ดูไม่ออกจากหน้าจอ
 */
export function allocationByClass(): { id: string; name: string; value: number; pct: number; color: string }[] {
  const assets = TREE.find((n) => n.id === "assets");
  const classes = assets?.children ?? [];
  const total = classes.reduce((t, c) => t + c.value, 0);
  return classes.map((c) => ({
    id: c.id,
    name: c.name,
    value: c.value,
    pct: total ? (c.value / total) * 100 : 0,
    color: CLASS_COLOR[c.id] ?? "#8792A2",
  }));
}

/** ขอบเขตของแต่ละหมวดใน conic-gradient ของโดนัท */
export function allocationGradient(): string {
  let at = 0;
  const stops = allocationByClass().map((c) => {
    const from = at;
    at += c.pct;
    return `${c.color} ${from.toFixed(2)}% ${at.toFixed(2)}%`;
  });
  return `conic-gradient(${stops.join(",")})`;
}
