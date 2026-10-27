/**
 * type ที่คอมโพเนนต์ tag ใช้ร่วมกัน — รูปแบบตาม ADR 0002 หัวข้อ 6 (สัญญาชิ้น 4 → ชิ้น 5/7)
 * ตอนชิ้น 4 สร้าง `src/modules/tags/types.ts` แล้ว ให้ย้ายมา re-export จากที่นั่นที่เดียว
 *
 * คอมโพเนนต์ในโฟลเดอร์นี้รับข้อมูลทาง props อย่างเดียว ไม่ต่อ Supabase
 */

export type TagKind = {
  key: string;
  nameTh: string;
  allowsMulti: boolean;
  /** ประโยคกำกับตารางต่อ tag — มาจาก DB ไม่ใช่พิมพ์ในหน้าจอ (ADR 0002 ชั้น 3) */
  aggregateNoteTh: string;
  /** ADR 0003 — ชนิดที่ต้องถ่วงน้ำหนัก (project) */
  requiresAllocation?: boolean;
  /** ADR 0003 — ประโยคกำกับของชนิดที่ปันส่วน */
  allocationNoteTh?: string | null;
};

export type Tag = {
  id: string;
  kind: string;
  code: string;
  nameTh: string;
  isActive: boolean;
  /** ชื่อโทเคนสีใน tailwind.config.ts (ไม่ใช่ hex) · null = สีกลาง */
  colorToken: string | null;
};

export type TagFilter = {
  tagIds: string[];
  mode: "any" | "all";
  kinds?: string[];
  untaggedOnly?: boolean;
  ownerIds: string[];
  dateField: "doc_date" | "cash_date";
  from?: string;
  to?: string;
  contactId?: string;
  txnTypeCodes?: string[];
  assetId?: string;
};

/**
 * น้ำหนักของแต่ละ tag เป็น **สัดส่วน** (0.6 = 60%) ไม่ใช่เปอร์เซ็นต์ — ตรงกับ `tag_allocations.weight`
 * `null` = ช่องนั้นยังไม่ได้กรอกหรืออ่านค่าไม่ได้ (ไม่ใช่ศูนย์ · ศูนย์ไม่ให้มี)
 */
export type TagWeights = Record<string, number | null>;

/** หนึ่งแถวของ `v_tag_touch_totals` (ชื่อคอลัมน์ touched_* ตามชั้น 1 ของ ADR 0002) */
export type TagTouchRow = {
  tag: Tag;
  touchedDebit: number;
  touchedCredit: number;
  touchedTxnCount: number;
  overlapTxnCount: number;
  overlapDebit: number;
};
