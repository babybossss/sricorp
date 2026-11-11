"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { Select } from "@/components/ui/select";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogPrimitive } from "@/components/ui/dialog";
import { Notice, WillSave } from "@/components/assets/asset-parts";
import type { RefOwner } from "@/lib/db/reference-types";
import { FAMILY_VIEW } from "@/lib/db/reference-types";
import { isoToDmy } from "@/lib/format";
import { cn } from "@/lib/utils";
import { updateUserAccess } from "./actions";
import type { RoleRow, UserRow } from "./users-data";

const ROLE_TONE = ["border-brand-100 bg-brand-50 text-brand-600", "border-info-bd bg-info-bg text-info-fg", "border-line bg-canvas text-ink-600"];

/**
 * ตารางผู้ใช้จริง — กรองตามผู้ถือที่ผู้ใช้ถูกให้เห็นได้ · ปุ่มแก้ไขโชว์เฉพาะคนที่มีสิทธิ์จัดการผู้ใช้
 * (ความสะดวก — ด่านจริงคือ RLS `users_write`) · เปิดบนมือถือได้: ตารางเลื่อนแนวนอนในกรอบ ปุ่มสูง ≥ 52px
 */
export function UsersTable({ users, roles, owners, currentUserId, canManage }: { users: UserRow[]; roles: RoleRow[]; owners: RefOwner[]; currentUserId: string; canManage: boolean }) {
  const [owner, setOwner] = React.useState<string>(FAMILY_VIEW);
  const [editing, setEditing] = React.useState<UserRow | null>(null);
  const [flash, setFlash] = React.useState<string | null>(null);
  const roleLabel = (k: string) => roles.find((r) => r.key === k)?.label ?? k;
  const ownerName = (id: string) => owners.find((o) => o.id === id)?.name ?? "ไม่ทราบผู้ถือ";
  const rows = users.filter((u) => owner === FAMILY_VIEW || u.ownerIds.includes(owner));

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-end gap-3">
        <div className="text-base text-ink-600" data-testid="user-count">
          ผู้ใช้ทั้งหมด <b className="text-ink-900">{rows.length} คน</b>
        </div>
        <Field label="ผู้ถือที่ถูกให้เห็น" className="ml-auto min-w-[240px]">
          <Select value={owner} onChange={(e) => setOwner(e.target.value)}>
            <option value={FAMILY_VIEW}>ทุกคน (ไม่กรอง)</option>
            {owners.filter((o) => o.status === "active").map((o) => (
              <option key={o.id} value={o.id}>{o.name}</option>
            ))}
          </Select>
        </Field>
      </div>

      {flash ? <Notice tone="ok">{flash}</Notice> : null}
      {users.length === 0 ? <Notice tone="warn">ไม่มีผู้ใช้ที่คุณมีสิทธิ์เห็น</Notice> : null}

      <TableShell>
        <Table minWidth={860}>
          <thead>
            <tr>
              <Th className="p-[12px_14px]">ชื่อ</Th>
              <Th className="p-[12px_14px]">อีเมล</Th>
              <Th className="p-[12px_14px]">ระดับสิทธิ์</Th>
              <Th className="p-[12px_14px]">ผู้ถือที่เห็น</Th>
              <Th className="p-[12px_14px]">สถานะ</Th>
              <Th className="p-[12px_14px]">สร้างเมื่อ</Th>
              {canManage ? <Th className="p-[12px_14px]">{""}</Th> : null}
            </tr>
          </thead>
          <tbody>
            {rows.map((u) => {
              const rank = Math.max(0, roles.findIndex((r) => r.key === u.role));
              return (
                <tr key={u.id} data-testid={`user-${u.id}`}>
                  <Td className="p-[12px_14px]">
                    <div className="flex items-center gap-2.5">
                      <div className="flex h-10 w-10 flex-none items-center justify-center rounded-pill bg-brand-50 text-base font-bold text-brand-600">{u.displayName.trim().slice(0, 1)}</div>
                      <b>{u.displayName}{u.id === currentUserId ? " (คุณ)" : ""}</b>
                    </div>
                  </Td>
                  <Td className="p-[12px_14px] text-ink-600">{u.email}</Td>
                  <Td className="p-[12px_14px]"><Pill className={cn("whitespace-nowrap", ROLE_TONE[Math.min(rank, ROLE_TONE.length - 1)])}>{roleLabel(u.role)}</Pill></Td>
                  <Td className="p-[12px_14px] text-ink-600">{u.ownerIds.length ? u.ownerIds.map(ownerName).join(", ") : "ตามสิทธิ์ของระดับ"}</Td>
                  <Td className="p-[12px_14px]">
                    <Pill className={u.isActive ? "border-pos bg-pos-bg text-pos-fg" : "border-line bg-canvas text-ink-600"}>{u.isActive ? "ใช้งานอยู่" : "ปิดใช้งาน"}</Pill>
                  </Td>
                  <Td className="whitespace-nowrap p-[12px_14px] text-ink-600 tabular-nums">{isoToDmy(u.createdAt.slice(0, 10))}</Td>
                  {canManage ? (
                    <Td className="p-[12px_14px]">
                      <Button variant="secondary" onClick={() => setEditing(u)} aria-label={`แก้ไขสิทธิ์ของ ${u.displayName}`}>แก้ไขสิทธิ์</Button>
                    </Td>
                  ) : null}
                </tr>
              );
            })}
          </tbody>
        </Table>
      </TableShell>

      {editing ? (
        <EditUser user={editing} roles={roles} self={editing.id === currentUserId} onClose={() => setEditing(null)} onSaved={(m) => { setFlash(m); setEditing(null); }} />
      ) : null}
    </div>
  );
}

function EditUser({ user, roles, self, onClose, onSaved }: { user: UserRow; roles: RoleRow[]; self: boolean; onClose: () => void; onSaved: (message: string) => void }) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [role, setRole] = React.useState(user.role);
  const [active, setActive] = React.useState(user.isActive);
  const [error, setError] = React.useState<string | null>(null);
  const label = (k: string) => roles.find((r) => r.key === k)?.label ?? k;
  const changed = role !== user.role || active !== user.isActive;

  function save() {
    setError(null);
    startTransition(async () => {
      const out = await updateUserAccess({ userId: user.id, role, isActive: active });
      if (out.ok) {
        router.refresh();
        onSaved(`${user.displayName}: ${out.message}`);
      } else setError(out.message);
    });
  }

  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <DialogContent aria-describedby={undefined} width="max-w-[560px]">
        <DialogPrimitive.Title className="sr-only">แก้ไขสิทธิ์ {user.displayName}</DialogPrimitive.Title>
        <DialogHeader title={`แก้ไขสิทธิ์ ${user.displayName}`} onClose={onClose} />
        <div className="flex flex-col gap-4 p-[20px_24px]">
          {self ? <Notice tone="warn">นี่คือบัญชีของคุณเอง — ระบบไม่ให้แก้ระดับหรือปิดบัญชีตัวเอง เพื่อไม่ให้ล็อกตัวเองออกจากระบบ</Notice> : null}
          <Field label="ระดับสิทธิ์">
            <Select value={role} onChange={(e) => setRole(e.target.value)} disabled={self}>
              {roles.map((r) => (
                <option key={r.key} value={r.key}>{r.label}</option>
              ))}
            </Select>
          </Field>
          <Field label="สถานะการใช้งาน">
            <Select value={active ? "1" : "0"} onChange={(e) => setActive(e.target.value === "1")} disabled={self}>
              <option value="1">ใช้งานอยู่</option>
              <option value="0">ปิดใช้งาน (เข้าระบบแล้วไม่เห็นอะไร)</option>
            </Select>
          </Field>
          <WillSave
            items={
              changed
                ? [
                    ...(role !== user.role ? [<>ระดับสิทธิ์ของ <b>{user.displayName}</b>: {label(user.role)} → <b>{label(role)}</b></>] : []),
                    ...(active !== user.isActive ? [<>สถานะ: {user.isActive ? "ใช้งานอยู่" : "ปิดใช้งาน"} → <b>{active ? "ใช้งานอยู่" : "ปิดใช้งาน"}</b></>] : []),
                    "ไม่ลบผู้ใช้และไม่แตะประวัติรายการที่เคยทำ · ผู้ใช้ต้องออกแล้วเข้าใหม่จึงเห็นสิทธิ์ใหม่ครบ",
                  ]
                : ["ยังไม่ได้เปลี่ยนอะไร — ยังไม่มีอะไรจะบันทึก"]
            }
          />
          {error ? <Notice tone="neg">{error}</Notice> : null}
        </div>
        <DialogFooter>
          <Button variant="secondary" onClick={onClose} disabled={pending}>ยกเลิก</Button>
          <Button onClick={save} disabled={!changed || pending || self}>{pending ? "กำลังบันทึก…" : "บันทึกการเปลี่ยนแปลง"}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
