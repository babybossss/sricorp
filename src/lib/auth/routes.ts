import type { Permission } from "./permissions";

/**
 * หน้าไหนต้องมีสิทธิ์อะไร — **ตารางเดียว** ที่ทั้งเมนูข้างและตัวกั้นหน้าอ่านร่วมกัน
 * (เขียนสองที่ไม่ได้ ไม่งั้นเมนูโชว์หน้าที่กดแล้วโดนกั้น หรือซ่อนหน้าที่เข้าได้)
 *
 * นี่คือ "หน้า → สิทธิ์" ไม่ใช่ "role → สิทธิ์" · ฝั่ง role อยู่ใน DB
 *
 * การกั้นหน้าจอคือ **ความสะดวก ไม่ใช่ความปลอดภัย** — ความปลอดภัยจริงคือ RLS ใน DB
 * ต่อให้ผ่านตัวกั้นนี้ ทุก query ก็ยังถูก RLS กรองตามผู้ใช้ และห้ามอ้างว่า "หน้านี้กั้นแล้ว"
 * เป็นเหตุผลให้ query ไม่ต้องกรอง
 *
 * anyOf = มีสักอย่างก็พอ · allOf = ต้องมีครบ (ใส่ทั้งคู่ = ต้องผ่านทั้งสองเงื่อนไข)
 */
export type Access = { anyOf?: readonly Permission[]; allOf?: readonly Permission[] };

export const ROUTE_ACCESS = {
  "/dashboard": { anyOf: ["ledger.read", "draft.read_own"] },
  "/ledger": { anyOf: ["ledger.read", "draft.read_own"] },
  "/approvals": { anyOf: ["ledger.approve", "cash.confirm"] },
  // ลูกพี่สั่ง: Manager ดูภาพรวมการลงทุนไม่ได้ ดูได้แต่ทรัพย์ที่ตนบริหาร (ผ่าน /assets)
  "/balance": { allOf: ["portfolio.view_all"] },
  // ทุกคนที่มี asset.view_assigned เข้าได้ — แถวที่เห็นให้ RLS กรอง ห้ามกรองใน TS
  "/assets": { allOf: ["asset.view_assigned"] },
  // ผู้ติดต่อใช้ตอนคีย์รายการ จึงผูกกับสิทธิ์สร้างรายการ (ข้อกำหนดไม่ได้ระบุ — ตัดสินเอง)
  "/contacts": { allOf: ["txn.create"] },
  "/settings": { allOf: ["settings.manage"] },
  "/settings/users": { allOf: ["settings.manage", "users.manage"] },
  // หน้าทดลองของนักพัฒนา (ไม่อยู่ในเมนู)
  "/dev": { allOf: ["settings.manage"] },
  // มุมมองมือถือ (ตัวอย่างหน้าจอ)
  "/m": { anyOf: ["ledger.read", "draft.read_own"] },
  "/m/new": { allOf: ["txn.create"] },
} as const satisfies Record<string, Access>;

export type GatedRoute = keyof typeof ROUTE_ACCESS;

/** หา rule ของ path โดยเอา prefix ที่ยาวที่สุดที่ตรงทั้ง segment (/m ไม่ตรง /menu) */
export function routeFor(pathname: string): GatedRoute | null {
  let best: GatedRoute | null = null;
  for (const key of Object.keys(ROUTE_ACCESS) as GatedRoute[]) {
    if (pathname === key || pathname.startsWith(key + "/")) {
      if (!best || key.length > best.length) best = key;
    }
  }
  return best;
}

export function hasAccess(perms: ReadonlySet<Permission>, access: Access): boolean {
  const anyOk = !access.anyOf || access.anyOf.some((p) => perms.has(p));
  const allOk = !access.allOf || access.allOf.every((p) => perms.has(p));
  return anyOk && allOk;
}

/**
 * path ที่ไม่มีใน ROUTE_ACCESS = ไม่ต้องใช้สิทธิ์เฉพาะ (ต้องล็อกอินอย่างเดียว ซึ่ง middleware ดูแล)
 * ใช้กับเมนูข้าง: ไม่รู้จัก = ไม่ซ่อน
 */
export function canOpen(perms: ReadonlySet<Permission>, pathname: string): boolean {
  const r = routeFor(pathname);
  return r ? hasAccess(perms, ROUTE_ACCESS[r]) : true;
}
