import * as React from "react";
import { redirect } from "next/navigation";
import { PageShell } from "@/components/layout/page-shell";
import { NoAccess, type NoAccessReason } from "@/components/auth/no-access";
import { getAccess } from "@/lib/auth/session";
import { hasAccess, type Access } from "@/lib/auth/routes";

/**
 * ตัวกั้นของหน้าลงทะเบียนทรัพย์/คิวร่าง
 *
 * **ทำไมไม่ใช้ `gateRoute("/assets")`**: กฎของ `/assets` ใน `src/lib/auth/routes.ts` คือ
 * `asset.view_assigned` ซึ่ง Staff ไม่มี — แต่ Staff คือคนที่ต้องร่างทะเบียนได้ (D-083)
 * ใช้ตัวนั้นแล้ว Staff จะถูกกั้นหน้าที่เขาควรเข้า · `routes.ts` อยู่นอกขอบเขตงานนี้
 * จึงกั้นเองตรงนี้ด้วย `hasAccess` ตัวเดียวกัน · พอ `ROUTE_ACCESS` มี `/assets/new` และ
 * `/assets/drafts` (anyOf asset.draft, asset.manage) ให้สลับกลับไปใช้ `gateRoute` และลบไฟล์นี้
 *
 * **นี่คือความสะดวก ไม่ใช่ความปลอดภัย** — RLS ใน DB คือของจริง (`asset_drafts_*`)
 */
export const DRAFT_PAGES_ACCESS: Access = { anyOf: ["asset.draft", "asset.manage"] };

export async function gateDraftPages(
  title: string
): Promise<{ denied: React.ReactElement; user: null } | { denied: null; user: { id: string; name: string } }> {
  const access = await getAccess();
  if (!access.user && !access.error) redirect("/login");

  if (!access.error && access.user && hasAccess(access.permissions, DRAFT_PAGES_ACCESS)) {
    return {
      denied: null,
      user: { id: access.user.id, name: access.profile?.displayName ?? access.user.email ?? "ผู้ใช้" },
    };
  }

  let reason: NoAccessReason;
  if (access.error) reason = { kind: "error", detail: access.error };
  else if (access.permissions.size === 0 && !access.profile)
    reason = { kind: "not-registered", email: access.user?.email ?? null };
  else
    reason = {
      kind: "lacks",
      mode: "any",
      needed: [
        { key: "asset.draft", label: "เสนอข้อมูลทะเบียนทรัพย์เป็นร่าง" },
        { key: "asset.manage", label: "เขียนทะเบียนทรัพย์/สัญญา + อนุมัติร่าง" },
      ],
    };

  return {
    denied: (
      <PageShell title={title}>
        <NoAccess reason={reason} />
      </PageShell>
    ),
    user: null,
  };
}
