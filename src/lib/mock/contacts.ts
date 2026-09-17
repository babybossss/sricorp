/** ผู้ติดต่อ — ผู้เช่า ผู้ให้กู้ ผู้กู้ คู่ค้า (Backlog ข้อ 3) */
export type ContactKind = "tenant" | "lender" | "borrower" | "vendor" | "other";

export type Contact = {
  id: string;
  firstName: string;
  lastName: string;
  phone: string;
  lineId: string;
  email: string;
  kind: ContactKind;
};

export const CONTACT_KIND_LABEL: Record<ContactKind, string> = {
  tenant: "ผู้เช่า",
  lender: "ผู้ให้กู้",
  borrower: "ผู้กู้",
  vendor: "คู่ค้า / ผู้รับเหมา",
  other: "อื่นๆ",
};

export function contactFullName(c: Contact): string {
  return `${c.firstName} ${c.lastName}`.trim();
}

export const SEED_CONTACTS: Contact[] = [
  { id: "c1", firstName: "สมชาย", lastName: "ใจดี", phone: "081-234-5678", lineId: "somchai.j", email: "somchai@example.com", kind: "tenant" },
  { id: "c2", firstName: "วิภา", lastName: "รุ่งเรือง", phone: "082-345-6789", lineId: "wipa.r", email: "wipa@example.com", kind: "tenant" },
  { id: "c3", firstName: "ธนาคาร", lastName: "ไทยพาณิชย์ (สาขาสีลม)", phone: "02-777-7777", lineId: "-", email: "silom@scb.example.com", kind: "lender" },
  { id: "c4", firstName: "ประสิทธิ์", lastName: "ทองมา", phone: "089-111-2222", lineId: "prasit.t", email: "prasit@example.com", kind: "borrower" },
  { id: "c5", firstName: "ร้านแอร์", lastName: "เย็นสบาย", phone: "086-555-4444", lineId: "yensabai", email: "yensabai@example.com", kind: "vendor" },
];
