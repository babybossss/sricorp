/** ผู้ถือกรรมสิทธิ์ — ทุกอย่างเป็นกองกลาง SRI Family ทรัพย์บางตัวแค่อยู่ในชื่อบุคคล */
export type Entity = {
  id: string;
  name: string;
  color: string;
  /** หัวข้อกลุ่มใน entity switcher */
  group?: string;
  /** เลือกเป็นผู้ถือในฟอร์มได้หรือไม่ (มุมมองรวมเลือกไม่ได้) */
  selectableAsHolder: boolean;
};

export const ENTITIES: Entity[] = [
  { id: "family", name: "SRI Family (รวมทุกชื่อ)", color: "#0A2540", group: "กองกลางครอบครัว", selectableAsHolder: false },
  { id: "corp", name: "SRI Corporation", color: "#004AAD", group: "ถือในชื่อนิติบุคคล", selectableAsHolder: true },
  { id: "sutee", name: "สุธี (ป๊า)", color: "#7A5AF8", group: "ถือในชื่อบุคคล (ยังเป็นกองกลาง)", selectableAsHolder: true },
  { id: "sudjit", name: "สุดจิตต์ (ม๊า)", color: "#7A5AF8", selectableAsHolder: true },
  { id: "thanakorn", name: "ธนากร", color: "#7A5AF8", selectableAsHolder: true },
  { id: "thanawin", name: "ธนวินท์", color: "#7A5AF8", selectableAsHolder: true },
  { id: "benjaporn", name: "เบ็ญจพร", color: "#7A5AF8", selectableAsHolder: true },
];

export const HOLDERS = ENTITIES.filter((e) => e.selectableAsHolder);

export function entityById(id: string): Entity {
  return ENTITIES.find((e) => e.id === id) ?? ENTITIES[0];
}

export const MONTHS = ["ม.ค.", "ก.พ.", "มี.ค.", "เม.ย.", "พ.ค.", "มิ.ย.", "ก.ค.", "ส.ค.", "ก.ย.", "ต.ค.", "พ.ย.", "ธ.ค."];
