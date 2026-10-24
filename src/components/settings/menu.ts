/**
 * เมนูซ้ายของหน้าตั้งค่า — `href` เป็นหน้าที่เปิดได้จริง · ไม่มี `href` = ยังไม่ทำ (แสดงเป็นหัวข้อจาง)
 * สิทธิ์ของแต่ละหน้าอยู่ที่ `ROUTE_ACCESS` (`lib/auth/routes.ts`) ตัวเดียว เมนูอ่านจากที่นั่น
 */
export const SETTINGS_MENU: { label: string; href?: string }[] = [
  { label: "บัญชีธนาคาร", href: "/settings/banks" },
  { label: "ผังบัญชี & ประเภทรายการ", href: "/settings/tx-rules" },
  { label: "ผู้ใช้ & สิทธิ์", href: "/settings/users" },
  { label: "นำเข้ายอดตั้งต้น", href: "/import" },
  { label: "Entity" },
  { label: "หมวดทรัพย์" },
  { label: "Automation" },
  { label: "AI / LLM" },
  { label: "แจ้งเตือน" },
  { label: "เป้าหมาย" },
  { label: "ปิดงวด" },
  { label: "ส่งออกข้อมูล" },
];
