/** ทรัพย์ที่ผูกกับรายการได้ */
export type AssetRef = { id: string; name: string; category: string; ownerId: string; cost: number };

export const ASSETS: AssetRef[] = [
  { id: "rent1", name: "คอนโดตัวอย่าง C", category: "Real Estate · ปล่อยเช่า", ownerId: "thanakorn", cost: 2450000 },
  { id: "rent2", name: "คอนโดตัวอย่าง A", category: "Real Estate · ปล่อยเช่า", ownerId: "corp", cost: 2900000 },
  { id: "rent3", name: "อาคารพาณิชย์ตัวอย่าง E", category: "Real Estate · ปล่อยเช่า", ownerId: "corp", cost: 5450000 },
  { id: "th_b", name: "ทาวน์โฮมตัวอย่าง B", category: "Real Estate · ขายฝาก", ownerId: "corp", cost: 3100000 },
  { id: "land_d", name: "ที่ดินตัวอย่าง D", category: "Real Estate · ขายฝาก", ownerId: "corp", cost: 1800000 },
];
