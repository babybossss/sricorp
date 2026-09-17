export const KPIS = [
  { label: "สินทรัพย์รวม", en: "Total assets", value: "฿ 82.9M", delta: "▲ 1.2%", note: "เทียบเดือนก่อน", positive: true, spark: "0,30 18,29 36,27 54,28 72,24 90,23 108,22 126,19 144,18 162,14 180,12 200,8", sparkColor: "#004AAD" },
  { label: "หนี้สิน", en: "Liabilities", value: "฿ 18.7M", delta: "▼ 0.4%", note: "ลดลง ดีขึ้น", positive: true, spark: "0,10 18,11 36,12 54,12 72,14 90,15 108,15 126,17 144,18 162,19 180,20 200,22", sparkColor: "#8792A2" },
  { label: "ส่วนของเจ้าของ", en: "Equity · NAV", value: "฿ 64.2M", delta: "▲ 1.8%", note: "เทียบเดือนก่อน", positive: true, spark: "0,31 18,29 36,30 54,25 72,26 90,21 108,20 126,20 144,15 162,12 180,9 200,6", sparkColor: "#004AAD" },
  { label: "ผลตอบแทนเฉลี่ยทั้งพอร์ต", en: "(ก่อนหักต้นทุนทางการเงิน)", value: "7.03%", delta: "▲ 0.15 จุด", note: "", positive: true, spark: "0,26 18,25 36,24 54,24 72,22 90,21 108,20 126,19 144,17 162,15 180,13 200,11", sparkColor: "#004AAD" },
];

export const YIELDS = [
  { label: "Yield อสังหาปล่อยเช่า", en: "Rental", value: "5.9%", target: "เป้า 6.5%", bar: "90%", color: "#F5A524", note: "ห้องว่าง 1 ห้องฉุดลง 0.4 จุด" },
  { label: "ผลตอบแทนพอร์ตหุ้น", en: "Equities YTD", value: "+11.2%", target: "SET +4.1%", bar: "100%", color: "#0E9F6E", note: "กำไรยังไม่รับรู้ ฿ 850,000" },
];

export type Todo = { p: "P1" | "P2" | "P3"; title: string; why: string; href: string };

export const TODOS: Todo[] = [
  { p: "P1", title: "ติดตามดอกเบี้ยค้าง 3 งวด — คอนโดตัวอย่าง A", why: "ค้าง 45 วัน ยอด ฿ 31,500 · สัญญาหมดแล้ว", href: "/assets/rent1" },
  { p: "P1", title: "ส่ง Notice ขายฝาก — ทาวน์โฮมตัวอย่าง B", why: "เหลือ 20 วันก่อนหมดช่วงส่ง", href: "/assets/rent1" },
  { p: "P2", title: "สัญญาเช่าหมด 29/09/2026 — คอนโดตัวอย่าง C", why: "ยังไม่มีการต่อสัญญา", href: "/assets/rent1" },
  { p: "P2", title: "อนุมัติรายการรอ 7 รายการ", why: "รวม ฿ 186,500", href: "/approvals" },
  { p: "P3", title: "ราคาหุ้นไม่อัปเดต 9 วัน", why: "แหล่งราคาฟรีดึงไม่สำเร็จ", href: "/balance" },
];

export const TEAM_TASKS = [
  { when: "จ. 21/09 10:00", what: "ตรวจงานปรับปรุงคอนโด A", who: "มาวิน" },
  { when: "อ. 22/09 14:00", what: "นัดผู้เช่ารายใหม่ดูห้อง", who: "แพทตี้" },
  { when: "พ. 23/09 09:30", what: "ยื่นเอกสารไถ่ถอน ที่ดิน D", who: "มาวิน" },
  { when: "ศ. 25/09 16:00", what: "ปิดยอดสัปดาห์ + ตรวจ statement", who: "ธนกร" },
];

export const EXPIRING_CONTRACTS = [
  { name: "คอนโดตัวอย่าง C", date: "29/09/2026", kind: "สัญญาเช่า", left: "เหลือ 12 วัน", tone: "neg" as const },
  { name: "ทาวน์โฮมตัวอย่าง B", date: "07/10/2026", kind: "ขายฝาก", left: "เหลือ 20 วัน", tone: "warn" as const },
  { name: "อาคารพาณิชย์ตัวอย่าง E", date: "30/11/2026", kind: "สัญญาเช่า", left: "เหลือ 74 วัน", tone: "muted" as const },
];

export const USERS = [
  { initial: "ธก", name: "ธนกร (ลูกพี่)", email: "thanakorn@sri.co.th", role: "Management", owner: "ธนากร", status: "ใช้งาน", last: "วันนี้ 09:12" },
  { initial: "อก", name: "อากง", email: "grandpa@sri.co.th", role: "Management", owner: "—", status: "ใช้งาน", last: "16/09/2026" },
  { initial: "ธว", name: "ธนวินท์", email: "thanawin@sri.co.th", role: "Manager", owner: "ธนวินท์", status: "ใช้งาน", last: "วันนี้ 08:40" },
  { initial: "มว", name: "มาวิน", email: "mavin@sri.co.th", role: "Manager", owner: "—", status: "ใช้งาน", last: "เมื่อวาน 18:05" },
  { initial: "พต", name: "แพทตี้", email: "patty@sri.co.th", role: "User", owner: "เบ็ญจพร", status: "รอยืนยันอีเมล", last: "—" },
];

export const SETTINGS_MENU = [
  { label: "บัญชีธนาคาร", href: "/settings/banks" },
  { label: "ผังบัญชี & ประเภทรายการ", href: "/settings/tx-rules" },
  { label: "ผู้ใช้ & สิทธิ์", href: "/settings/users" },
  { label: "Entity" },
  { label: "หมวดทรัพย์" },
  { label: "Automation" },
  { label: "AI / LLM" },
  { label: "แจ้งเตือน" },
  { label: "เป้าหมาย" },
  { label: "ปิดงวด" },
  { label: "นำเข้า / ส่งออก" },
];

export const COMING_SOON = ["บริหารทรัพย์", "บอร์ดงาน / Ticket", "เบิกจ่าย", "HR", "Broker Portal", "Investment Tips"];
