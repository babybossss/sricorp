"use client";

import * as React from "react";
import type { Permission } from "@/lib/auth/permissions";

/**
 * ส่งชุดสิทธิ์จาก server (ที่ถาม DB แล้ว) ลงไปให้ client component ซ่อนเมนู/ปุ่มได้
 * ใช้เพื่อความสะดวกของผู้ใช้เท่านั้น — ไม่ใช่ความปลอดภัย (RLS ใน DB คือของจริง)
 */
const Ctx = React.createContext<ReadonlySet<Permission>>(new Set());

export function PermissionsProvider({ permissions, children }: { permissions: Permission[]; children: React.ReactNode }) {
  const set = React.useMemo(() => new Set(permissions), [permissions]);
  return <Ctx.Provider value={set}>{children}</Ctx.Provider>;
}

export const usePermissions = () => React.useContext(Ctx);
