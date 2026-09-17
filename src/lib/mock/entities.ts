/** ผู้ถือกรรมสิทธิ์ — ทุกอย่างเป็นกองกลาง SRI Family ทรัพย์บางตัวแค่อยู่ในชื่อบุคคล */
/**
 * Corporate = เข้ม 100% ห้าม override
 * Personal = ยืดหยุ่นได้ถ้าใส่เหตุผล แต่ Money Invariants ห้ามละเมิด
 * ตรงกับคอลัมน์ `policy` ในตาราง `sri_os.owners`
 */
export type OwnerPolicy = "corporate_strict" | "personal_flexible";

export type Entity = {
  id: string;
  name: string;
  color: string;
  policy: OwnerPolicy;
  /** หัวข้อกลุ่มใน entity switcher */
  group?: string;
  /** เลือกเป็นผู้ถือในฟอร์มได้หรือไม่ (มุมมองรวมเลือกไม่ได้) */
  selectableAsHolder: boolean;
};

export const ENTITIES: Entity[] = [
  { id: "family", name: "SRI Family (รวมทุกชื่อ)", color: "#0A2540", policy: "corporate_strict", group: "กองกลางครอบครัว", selectableAsHolder: false },
  { id: "corp", name: "SRI Corporation", color: "#004AAD", policy: "corporate_strict", group: "ถือในชื่อนิติบุคคล", selectableAsHolder: true },
  { id: "sutee", name: "สุธี (ป๊า)", color: "#7A5AF8", policy: "personal_flexible", group: "ถือในชื่อบุคคล (ยังเป็นกองกลาง)", selectableAsHolder: true },
  { id: "sudjit", name: "สุดจิตต์ (ม๊า)", color: "#7A5AF8", policy: "personal_flexible", selectableAsHolder: true },
  { id: "thanakorn", name: "ธนากร", color: "#7A5AF8", policy: "personal_flexible", selectableAsHolder: true },
  { id: "thanawin", name: "ธนวินท์", color: "#7A5AF8", policy: "personal_flexible", selectableAsHolder: true },
  { id: "benjaporn", name: "เบ็ญจพร", color: "#7A5AF8", policy: "personal_flexible", selectableAsHolder: true },
];

export const HOLDERS = ENTITIES.filter((e) => e.selectableAsHolder);

/** หาไม่เจอให้คืน undefined — อย่าเดา เพราะ owner ผิดแปลว่าเงินไปอยู่ในงบของคนผิด */
export function findEntity(id: string): Entity | undefined {
  return ENTITIES.find((e) => e.id === id);
}

/**
 * ใช้ตอนที่มั่นใจว่า id ถูกต้อง (เช่น มาจาก dropdown ในระบบ)
 * ถ้าไม่เจอให้ throw ไม่ fallback เงียบๆ ไปเป็นมุมมองรวม
 */
export function entityById(id: string): Entity {
  const e = findEntity(id);
  if (!e) throw new Error(`ไม่พบผู้ถือกรรมสิทธิ์: ${id}`);
  return e;
}

export const MONTHS = ["ม.ค.", "ก.พ.", "มี.ค.", "เม.ย.", "พ.ค.", "มิ.ย.", "ก.ค.", "ส.ค.", "ก.ย.", "ต.ค.", "พ.ย.", "ธ.ค."];
