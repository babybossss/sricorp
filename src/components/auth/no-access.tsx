import Link from "next/link";
import { Card, CardBody, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { SignOutButton } from "./sign-out-button";

export type NoAccessReason =
  | { kind: "error"; detail: string }
  | { kind: "not-registered"; email: string | null }
  | { kind: "lacks"; mode: "any" | "all"; needed: { key: string; label: string }[] };

/**
 * หน้าบอกว่าไม่มีสิทธิ์ — **ห้าม 404 เงียบๆ** ผู้ใช้ต้องรู้ว่าเกิดอะไรและต้องไปขอใคร
 */
export function NoAccess({ reason }: { reason: NoAccessReason }) {
  return (
    <div className="mx-auto flex max-w-[640px] flex-col gap-4 py-6">
      <Card>
        <CardBody className="flex flex-col gap-3">
          {reason.kind === "lacks" ? (
            <>
              <CardTitle>คุณยังไม่มีสิทธิ์เข้าหน้านี้</CardTitle>
              <p className="text-base text-ink-600">
                หน้านี้ต้องมีสิทธิ์ {reason.mode === "any" ? "อย่างใดอย่างหนึ่ง" : "ครบทุกข้อ"} ต่อไปนี้
              </p>
              <ul className="flex flex-col gap-1 rounded border border-line bg-canvas p-[12px_16px] text-base">
                {reason.needed.map((n) => (
                  <li key={n.key}>
                    <b>{n.label}</b> <span className="text-sm text-ink-400">({n.key})</span>
                  </li>
                ))}
              </ul>
              <p className="text-base text-ink-600">
                ให้ขอ<b>ผู้ดูแลระบบ</b>ที่มีสิทธิ์ &ldquo;จัดการผู้ใช้และสิทธิ์&rdquo; เปิดสิทธิ์ข้างต้นให้บัญชีของคุณ
                แล้วเข้าสู่ระบบใหม่
              </p>
            </>
          ) : reason.kind === "not-registered" ? (
            <>
              <CardTitle>บัญชีนี้ยังไม่ได้ลงทะเบียนใน SRI OS</CardTitle>
              <p className="text-base text-ink-600">
                เข้าสู่ระบบด้วย Google สำเร็จแล้ว{reason.email ? <> (<b>{reason.email}</b>)</> : null}
                แต่ยังไม่มีชื่อในรายชื่อผู้ใช้ หรือบัญชีถูกปิดการใช้งาน จึงยังไม่มีสิทธิ์ใดเลย
              </p>
              <p className="text-base text-ink-600">
                ให้ขอ<b>ผู้ดูแลระบบ</b>เพิ่มอีเมลนี้เป็นผู้ใช้ แล้วเข้าสู่ระบบใหม่
              </p>
            </>
          ) : (
            <>
              <CardTitle>ตรวจสิทธิ์ไม่สำเร็จ</CardTitle>
              <p className="text-base text-ink-600">
                ระบบถามสิทธิ์จากฐานข้อมูลไม่ได้ จึงปิดหน้านี้ไว้ก่อน (ปิดไว้ดีกว่าเปิดทั้งที่ไม่รู้ว่าใครมีสิทธิ์)
                ให้แจ้งผู้ดูแลระบบพร้อมข้อความด้านล่าง
              </p>
              <p className="rounded border border-neg-bd bg-neg-bg p-[12px_16px] text-sm text-neg-fg">{reason.detail}</p>
            </>
          )}

          <div className="mt-2 flex flex-wrap gap-3">
            <Button asChild variant="secondary">
              <Link href="/dashboard" className="no-underline hover:no-underline">กลับหน้าแรก</Link>
            </Button>
            <SignOutButton className="w-auto" />
          </div>
        </CardBody>
      </Card>
    </div>
  );
}
