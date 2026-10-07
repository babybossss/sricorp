"use client";

import * as React from "react";
import Link from "next/link";
import { findEntity } from "@/lib/mock/entities";
import { usePermissions } from "@/components/auth/permissions-provider";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Button } from "./tall-button";
import { Select } from "./fields";
import { Field } from "@/components/ui/field";
import { Pill } from "@/components/ui/pill";
import { cn } from "@/lib/utils";
import { useAssetStore } from "./asset-store";
import { fmtDateTime, norm, reviewActions, visibleDrafts, canSeeDraftQueue, registerMode, type Perms } from "./asset-drafts";
import { DraftReviewPanel } from "./draft-review-panel";
import { KindPill, LINK_BUTTON_CLASS, NotCountedNotice, StatusPill } from "./draft-parts";

/**
 * คิวร่างทะเบียนทรัพย์ที่รออนุมัติ — ใครสร้าง เมื่อไหร่ · กด "ตรวจร่าง" แล้วแผงเลื่อนเข้ามาทางขวา
 * (รูปแบบเดียวกับคิวอนุมัติรายการเงิน)
 *
 * Staff เห็นเฉพาะร่างของตัวเอง · ผู้มี asset.manage เห็นทั้งหมดในขอบเขต
 * (ตัวกรองนี้ใน TS เป็นแค่การจำลอง — ของจริงให้ RLS `asset_drafts_read` กรอง)
 */
export function DraftQueue({ currentUser }: { currentUser: { id: string; name: string } }) {
  const perms: Perms = usePermissions();
  return <DraftQueueView perms={perms} currentUser={currentUser} />;
}

export function DraftQueueView({ perms, currentUser }: { perms: Perms; currentUser: { id: string; name: string } }) {
  const allDrafts = useAssetStore((s) => s.drafts);
  const assets = useAssetStore((s) => s.assets);
  const [filter, setFilter] = React.useState<"pending" | "all">("pending");
  const [openId, setOpenId] = React.useState<string | null>(null);

  const mineVisible = React.useMemo(() => visibleDrafts(allDrafts, perms, currentUser.id), [allDrafts, perms, currentUser.id]);
  const pendingCount = mineVisible.filter((d) => d.status === "pending").length;
  const rows = React.useMemo(
    () =>
      mineVisible
        .filter((d) => filter === "all" || d.status === "pending")
        // รออนุมัติ: เก่าสุดขึ้นก่อน (รอนานสุด) · ทั้งหมด: ใหม่สุดขึ้นก่อน
        .sort((a, b) => (filter === "pending" ? 1 : -1) * (Date.parse(a.createdAt) - Date.parse(b.createdAt))),
    [mineVisible, filter]
  );

  if (!canSeeDraftQueue(perms)) {
    return (
      <div role="alert" className="rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-neg-fg">
        บัญชีของคุณยังไม่มีสิทธิ์ดูคิวร่างทะเบียนทรัพย์
      </div>
    );
  }

  const idx = rows.findIndex((d) => d.id === openId);
  const open = idx >= 0 ? rows[idx] : null;

  function afterDecision() {
    // ตัดสินแล้ว: ไปรายการรออนุมัติถัดไป ไม่มีแล้วก็ปิดแผง
    const next = rows.slice(idx + 1).find((d) => d.status === "pending") ?? rows.slice(0, idx).find((d) => d.status === "pending");
    setOpenId(next?.id ?? null);
  }

  return (
    <div className="flex flex-col gap-4 pb-24">
      <div className="flex flex-wrap items-end gap-3 rounded-card border border-line bg-surface p-[14px_18px] shadow-card">
        <div className="mr-auto flex flex-col gap-1">
          <div className="text-h2 font-semibold" data-testid="pending-count">
            ร่างรออนุมัติ {pendingCount} รายการ
          </div>
          <div className="text-base text-ink-600">ร่างทั้งหมดนี้ยังไม่ถูกนับในมูลค่าพอร์ต</div>
        </div>
        <Field label="แสดง" className="min-w-[200px]">
          <Select value={filter} onChange={(e) => setFilter(e.target.value as "pending" | "all")}>
            <option value="pending">เฉพาะรออนุมัติ</option>
            <option value="all">ทุกสถานะ</option>
          </Select>
        </Field>
        {registerMode(perms) !== "none" ? (
          <Link href="/assets/new" className={cn(LINK_BUTTON_CLASS, "border-line bg-surface text-ink-900 hover:border-ink-400")}>
            ลงทะเบียนทรัพย์
          </Link>
        ) : null}
      </div>

      {rows.length === 0 ? (
        <div className="rounded-card border border-line bg-surface p-[24px] text-base text-ink-600 shadow-card" data-testid="queue-empty">
          {filter === "pending" ? "ไม่มีร่างที่รออนุมัติ" : "ยังไม่มีร่าง"}
        </div>
      ) : (
        <TableShell>
          <Table minWidth={900}>
            <thead>
              <tr>
                <Th>ชนิด</Th>
                <Th className="min-w-[240px]">ทรัพย์</Th>
                <Th>ถือในชื่อ</Th>
                <Th>ผู้สร้าง</Th>
                <Th>สร้างเมื่อ</Th>
                <Th>สถานะ</Th>
                <Th>{""}</Th>
              </tr>
            </thead>
            <tbody>
              {rows.map((d) => {
                const target = d.targetAssetId ? assets.find((a) => a.id === d.targetAssetId) : undefined;
                const holder = findEntity(d.ownerId);
                const mine = d.createdBy.id === currentUser.id;
                const a = reviewActions(perms, d, currentUser.id);
                return (
                  <tr key={d.id} className="bg-surface" data-testid={`draft-row-${d.id}`}>
                    <Td className="whitespace-nowrap"><KindPill kind={d.kind} /></Td>
                    <Td className="font-semibold">
                      {d.kind === "create" ? (norm(d.name) ?? "(ยังไม่มีชื่อ)") : (target?.name ?? "(ไม่พบทรัพย์)")}
                    </Td>
                    <Td className="whitespace-nowrap">
                      <span className="inline-flex items-center gap-1.5">
                        {holder ? <span className="h-2.5 w-2.5 flex-none rounded-pill" style={{ background: holder.color }} /> : null}
                        {holder?.name ?? "—"}
                      </span>
                    </Td>
                    <Td>
                      <div className="whitespace-nowrap">{d.createdBy.name}</div>
                      {/* ผู้ตรวจที่เป็นคนคีย์เอง ต้องเห็นตั้งแต่หน้าคิว ไม่ใช่เพิ่งรู้ตอนกดอนุมัติ */}
                      {mine && a.approve ? (
                        <Pill className="mt-1 whitespace-nowrap border-warn bg-warn-bg text-warn-fg">คุณเป็นทั้งคนร่างและคนอนุมัติ</Pill>
                      ) : mine ? (
                        <span className="text-sm text-ink-600">ร่างของคุณเอง</span>
                      ) : null}
                    </Td>
                    <Td className="whitespace-nowrap tabular-nums">{fmtDateTime(d.createdAt)}</Td>
                    <Td className="whitespace-nowrap"><StatusPill status={d.status} /></Td>
                    <Td className="whitespace-nowrap">
                      <Button variant={a.approve || a.reject ? "primary" : "secondary"} onClick={() => setOpenId(d.id)}>
                        {a.approve || a.reject ? "ตรวจร่าง" : "ดูร่าง"}
                      </Button>
                    </Td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
        </TableShell>
      )}

      {registerMode(perms) === "draft" ? <NotCountedNotice className="max-w-[720px]" /> : null}

      <DraftReviewPanel
        draft={open}
        perms={perms}
        currentUser={currentUser}
        position={{ index: Math.max(idx, 0), total: rows.length }}
        onClose={() => setOpenId(null)}
        onStep={(delta) => setOpenId(rows[idx + delta]?.id ?? openId)}
        onDone={afterDecision}
      />
    </div>
  );
}
