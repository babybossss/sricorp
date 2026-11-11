/**
 * จำแนก error จาก PostgREST/Postgres ว่า "ของฝั่ง DB ยังไม่มี" (ยังไม่ได้ลง migration) หรือเป็นปัญหาอื่น
 *
 * ของที่ยังไม่มีต้องปฏิเสธเสียงดังพร้อมบอกว่าไม่ได้บันทึกอะไร — ห้ามปล่อยผ่านเงียบ และห้ามบันทึกครึ่งเดียว
 */
export type DbErrorLike = { code?: string | null; message?: string | null };

const MISSING_CODES = new Set([
  "42P01", // undefined_table
  "42883", // undefined_function
  "42703", // undefined_column
  "3F000", // invalid_schema_name
  "PGRST202", // function not found in schema cache
  "PGRST204", // column not found in schema cache
  "PGRST205", // table not found in schema cache
]);

export function isMissingDbObject(err: DbErrorLike | null | undefined): boolean {
  if (!err) return false;
  if (err.code && MISSING_CODES.has(err.code)) return true;
  return /could not find the (function|table)|schema cache|(relation|function|table) .* does not exist/i.test(err.message ?? "");
}

/** fn_post_entry ที่ยังไม่รู้จัก `tag_ids` / `tag_weights` ปฏิเสธทั้งใบด้วย "มีช่องที่ยังไม่รู้จัก (...)" */
export function isUnknownTagField(err: DbErrorLike | null | undefined): boolean {
  const m = err?.message ?? "";
  return /ช่องที่ยังไม่รู้จัก/.test(m) && /tag_ids|tag_weights/.test(m);
}

export const NOT_MIGRATED_MESSAGE =
  "ฐานข้อมูลยังไม่ได้ลง migration ของ tag และการถ่วงน้ำหนัก (ยังไม่ได้ลง migration) — ยังไม่ได้บันทึกอะไร ให้แจ้งผู้ดูแลระบบ";
