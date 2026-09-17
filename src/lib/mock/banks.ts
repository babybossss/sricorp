export type BankAccount = {
  id: string;
  name: string;
  bank: string;
  last4: string;
  ownerId: string;
  opening: string;
  short: string;
  color: string;
  /** ปิดใช้งาน = ซ่อนจากตัวเลือกในฟอร์ม แต่ยังอยู่ในรายงานย้อนหลัง */
  off: boolean;
};

export const BANKS: BankAccount[] = [
  { id: "b1", name: "SRI - SCB", bank: "ไทยพาณิชย์", last4: "4412", ownerId: "corp", opening: "฿ 3,800,000.00", short: "SCB", color: "#4E2A84", off: false },
  { id: "b2", name: "SRI - BBL", bank: "กรุงเทพ", last4: "7781", ownerId: "corp", opening: "฿ 0.00", short: "BBL", color: "#1E4598", off: true },
  { id: "b3", name: "SRI - BAY", bank: "กรุงศรีอยุธยา", last4: "2093", ownerId: "corp", opening: "฿ 0.00", short: "BAY", color: "#8a6200", off: true },
  { id: "b4", name: "ธนากร - BBL 888", bank: "กรุงเทพ", last4: "8888", ownerId: "thanakorn", opening: "฿ 1,200,000.00", short: "BBL", color: "#1E4598", off: false },
  { id: "b5", name: "ธนวินท์ - KBANK", bank: "กสิกรไทย", last4: "5520", ownerId: "thanawin", opening: "฿ 600,000.00", short: "KB", color: "#0A8F3C", off: false },
  { id: "b6", name: "ธนวินท์ - BBL", bank: "กรุงเทพ", last4: "3317", ownerId: "thanawin", opening: "฿ 150,000.00", short: "BBL", color: "#1E4598", off: false },
  { id: "b7", name: "เบ็ญจพร - BBL", bank: "กรุงเทพ", last4: "6045", ownerId: "benjaporn", opening: "฿ 300,000.00", short: "BBL", color: "#1E4598", off: false },
];
