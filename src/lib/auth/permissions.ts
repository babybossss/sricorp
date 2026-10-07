/**
 * ชื่อสิทธิ์ที่ฝั่ง TypeScript รู้จัก — **ชื่อเท่านั้น ไม่มีตาราง role → permission**
 *
 * ใครมีสิทธิ์อะไรอยู่ใน DB (`sri_os.roles` · `permissions` · `role_permissions` · `fn_can`)
 * ตามกฎข้อ 5 ของ CLAUDE.md (ตั้งค่าได้ = อยู่ในตาราง config) ห้ามคัดลอกตารางนั้นมาเขียนซ้ำที่นี่
 * ไม่งั้นสิ่งที่หน้าจอโชว์กับสิ่งที่ DB บังคับจะแยกจากกันได้
 *
 * รายการนี้ต้องตรงกับตาราง `permissions` ใน DB ทุกตัว — `npm run check:permissions`
 * เทียบให้และพังทันทีถ้าไม่ตรง (เพิ่มสิทธิ์ใน DB แล้วลืมเพิ่มที่นี่ = พัง ไม่ใช่เงียบ)
 */
export const PERMISSIONS = [
  "asset.assign_manager",
  "asset.draft",
  "asset.manage",
  "asset.value",
  "asset.view_assigned",
  "cash.confirm",
  "draft.read_own",
  "ledger.approve",
  "ledger.read",
  "owner.view_all",
  "period.reopen",
  "portfolio.view_all",
  "settings.manage",
  "txn.create",
  "txn.void",
  "users.manage",
] as const;

export type Permission = (typeof PERMISSIONS)[number];

export function isPermission(key: string): key is Permission {
  return (PERMISSIONS as readonly string[]).includes(key);
}
