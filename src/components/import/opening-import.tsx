"use client";

import * as React from "react";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Table, TableShell, Td, Th } from "@/components/ui/table";
import { Amount, Notice, Section, m } from "@/components/reports/parts";
import {
  confirmOpeningImport,
  previewOpeningImport,
  type OpeningConfirmOutcome,
  type OpeningPreview,
} from "@/app/actions/import-opening";
import { isoToDmy } from "@/lib/format";
import { OwnerEvidence, evidenceReady, type EvidenceDraft } from "./opening-evidence";
import type { OwnerOutcome } from "@/lib/db/import/opening-run";

type Ok = Extract<OpeningPreview, { ok: true }>;

const ACTION_LABEL: Record<string, string> = {
  new: "ลงใหม่ (ยังไม่เคยมียอดตั้งต้นในสมุด)",
  unchanged: "ไม่เปลี่ยน — เนื้อหาเหมือนในสมุดแล้ว จะไม่ลงซ้ำ",
  replace: "จะกลับรายการชุดเดิม (ไม่ลบ) แล้วลงชุดใหม่",
  retract: "ไฟล์ใหม่ไม่มียอดของผู้ถือนี้ — จะกลับรายการชุดเดิมทั้งหมด",
};

/**
 * นำเข้ายอดตั้งต้น — ตรวจไฟล์ → ดูตัวอย่าง → ยืนยันลงสมุด
 * ขั้นยืนยันส่งไฟล์เดิมกลับไปให้ server อ่านใหม่ทั้งหมด (ไม่ส่งบรรทัดบัญชีจากหน้านี้) พร้อมรหัสตรวจเนื้อหาที่ผู้ใช้เห็น
 */
export function OpeningImport() {
  const [pending, start] = React.useTransition();
  const [result, setResult] = React.useState<OpeningPreview | null>(null);
  const [crash, setCrash] = React.useState<string | null>(null);
  const [outcome, setOutcome] = React.useState<OpeningConfirmOutcome | null>(null);
  const [evidence, setEvidence] = React.useState<Record<string, EvidenceDraft>>({});
  // ไฟล์/วันตัดยอดที่ใช้ตรวจ — ขั้นยืนยันส่งชุดเดียวกันนี้ ไม่อ่านจากช่องในฟอร์มที่ผู้ใช้อาจแก้ไปแล้ว
  const sent = React.useRef<FormData | null>(null);

  function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    setResult(null);
    setOutcome(null);
    setCrash(null);
    setEvidence({});
    sent.current = fd;
    start(async () => {
      try {
        setResult(await previewOpeningImport(fd));
      } catch {
        setCrash("ส่งไฟล์ไม่สำเร็จ (อาจใหญ่เกินไปหรือเน็ตหลุด) — ลองใหม่อีกครั้ง ยังไม่มีอะไรถูกบันทึก");
      }
    });
  }

  function onConfirm() {
    if (!result || !result.ok || !sent.current) return;
    const fd = new FormData();
    const file = sent.current.get("file");
    if (file) fd.set("file", file);
    fd.set("cutoff", isoToDmy(result.cutoff));
    fd.set("fingerprint", result.fingerprint);
    fd.set("evidence", JSON.stringify(evidence));
    setOutcome(null);
    setCrash(null);
    start(async () => {
      try {
        setOutcome(await confirmOpeningImport(fd));
      } catch {
        setCrash(
          "ส่งคำสั่งยืนยันไม่สำเร็จ (เน็ตหลุดหรือหมดเวลา) — ยังไม่ทราบว่าลงสมุดแล้วหรือไม่ ให้เปิดหน้าสมุดบัญชีตรวจก่อน แล้วค่อยอัปโหลดไฟล์เดิมซ้ำ (ถ้าลงแล้ว ระบบจะไม่ลงซ้ำ)"
        );
      }
    });
  }

  const done = outcome?.ok === true;
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <Notice tone="info">
        <strong>ขั้นตอน: ตรวจไฟล์ → ดูตัวอย่างว่าระบบจะบันทึกอะไร → ยืนยันลงสมุดบัญชี</strong>
        <div className="text-base">
          ตรวจทั้งไฟล์ในครั้งเดียว ถ้ามีจุดผิดแม้จุดเดียวจะไม่นำเข้าเลย และบอกว่าผิดที่ชีทไหนแถวไหน · อัปโหลดไฟล์เดิมซ้ำได้โดยไม่เกิดรายการซ้ำ ·
          แก้ตัวเลขแล้วอัปโหลดใหม่ ระบบจะกลับรายการชุดเดิม (ไม่ลบ) แล้วลงชุดใหม่
        </div>
      </Notice>

      <form onSubmit={onSubmit} className="flex flex-col gap-4 rounded-card border border-line bg-surface p-4 shadow-card">
        <Field label="วันตัดยอด (วว/ดด/ปปปป)" hint="เว้นว่างได้ — ระบบอ่านจากหัวชีทให้ (ต้องเป็นวันเดียวกันทุกชีท) · ถ้ากรอกเองแล้วไม่ตรงกับในไฟล์ จะไม่นำเข้า">
          <Input name="cutoff" inputMode="numeric" autoComplete="off" placeholder="เช่น 31/10/2026 (เว้นว่างให้ระบบอ่านจากไฟล์)" />
        </Field>
        <Field label="ไฟล์ Excel ยอดตั้งต้น (.xlsx)" hint="ไฟล์ที่กรอกจากเทมเพลต “ยอดตั้งต้นงบดุล” ขนาดไม่เกิน 10 MB" required>
          <Input name="file" type="file" accept=".xlsx" required className="py-3" />
        </Field>
        <div>
          <Button type="submit" disabled={pending} className="w-full sm:w-auto max-sm:min-h-control-mobile">
            {pending && !result ? "กำลังตรวจไฟล์…" : "ตรวจไฟล์และดูตัวอย่าง"}
          </Button>
        </div>
      </form>

      {crash ? <Notice tone="neg">{crash}</Notice> : null}
      {result && !result.ok ? <Rejected message={result.message} issues={result.issues} /> : null}
      {result && result.ok ? (
        <Preview
          result={result}
          evidence={evidence}
          setEvidence={setEvidence}
          pending={pending}
          done={done}
          onConfirm={onConfirm}
          outcome={outcome}
        />
      ) : null}
    </div>
  );
}

function Rejected({ message, issues }: { message: string; issues: { sheet: string; row?: number; message: string }[] }) {
  const bySheet = new Map<string, typeof issues>();
  for (const i of issues) bySheet.set(i.sheet, [...(bySheet.get(i.sheet) ?? []), i]);
  return (
    <div className="flex min-w-0 flex-col gap-4">
      <Notice tone="neg">
        <strong>{message}</strong>
      </Notice>
      {[...bySheet].map(([sheet, list]) => (
        <Section key={sheet} title={`ชีท: ${sheet}`}>
          <ul className="flex flex-col">
            {list.map((i, k) => (
              <li key={k} className="border-t border-line py-3 text-base leading-7 first:border-t-0">
                {i.row ? <span className="mr-2 inline-block rounded bg-neg-bg px-2 text-neg-fg">แถว {i.row}</span> : null}
                {i.message}
              </li>
            ))}
          </ul>
        </Section>
      ))}
    </div>
  );
}

function Preview({
  result,
  evidence,
  setEvidence,
  pending,
  done,
  onConfirm,
  outcome,
}: {
  result: Ok;
  evidence: Record<string, EvidenceDraft>;
  setEvidence: React.Dispatch<React.SetStateAction<Record<string, EvidenceDraft>>>;
  pending: boolean;
  done: boolean;
  onConfirm: () => void;
  outcome: OpeningConfirmOutcome | null;
}) {
  const evidenceMissing = result.evidenceOwners.filter((o) => !evidenceReady(o.id, evidence[o.id]));
  const blocked = result.blockers.length > 0;
  const canConfirm = !blocked && result.canPost && evidenceMissing.length === 0 && !done;
  const nothingToDo = result.plan !== null && result.plan.length > 0 && result.plan.every((p) => p.action === "unchanged");

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <Notice tone="ok">
        <strong>ไฟล์ผ่านการตรวจทั้งหมด</strong> · วันตัดยอด {isoToDmy(result.cutoff)}
        {result.cutoffFromFile ? " (อ่านจากหัวชีทในไฟล์)" : ""} · {result.totals.owners} ผู้ถือ · {result.totals.lines} บรรทัดบัญชี
        <div className="text-base">{done ? "ลงสมุดบัญชีเรียบร้อยแล้ว — ดูผลด้านล่าง" : "ยังไม่ได้บันทึก — ตรวจตัวอย่างด้านล่างแล้วกดยืนยันที่ท้ายหน้า"}</div>
      </Notice>
      {result.warnings.map((w) => (
        <Notice key={w} tone="warn">
          {w}
        </Notice>
      ))}

      {blocked ? (
        <Notice tone="neg">
          <strong>ยังลงสมุดไม่ได้ — พบปัญหา {result.blockers.length} จุด (ยังไม่มีอะไรถูกบันทึก)</strong>
          <ul className="mt-2 flex flex-col gap-2 text-base leading-7">
            {result.blockers.map((b, i) => (
              <li key={i}>
                {b.ownerName ? <strong>{b.ownerName}: </strong> : null}
                {b.message}
              </li>
            ))}
          </ul>
        </Notice>
      ) : null}

      {result.plan ? (
        <Section title="ครั้งนี้จะเกิดอะไรกับยอดตั้งต้นที่อยู่ในสมุดตอนนี้">
          <ul className="flex flex-col">
            {result.plan.map((p) => (
              <li key={p.ownerId} className="border-t border-line py-3 text-base leading-7 first:border-t-0">
                <strong>{p.ownerName}</strong> — {ACTION_LABEL[p.action] ?? p.action}
                {p.note ? <span className="text-ink-600"> ({p.note})</span> : null}
              </li>
            ))}
          </ul>
          <div className="pb-3 text-base text-ink-600">นี่คือการคาดการณ์ — ตอนกดยืนยัน ฐานข้อมูลเทียบเนื้อหาอีกครั้งและเป็นผู้ตัดสินจริง</div>
        </Section>
      ) : result.planError ? (
        <Notice tone="warn">อ่านยอดตั้งต้นเดิมในสมุดไม่ได้ จึงบอกล่วงหน้าไม่ได้ว่าจะเป็นลงใหม่หรือแทนที่ ({result.planError}) — ตอนยืนยัน ฐานข้อมูลจะเทียบให้เอง</Notice>
      ) : null}

      <h2 className="text-h2 font-semibold">ระบบจะบันทึกให้ดังนี้</h2>
      {result.owners.map((o) => (
        <Section key={o.ownerName} title={`${o.ownerName} — ยอดตั้งต้น ณ ${isoToDmy(result.cutoff)}`}>
          <TableShell className="my-3">
            <Table minWidth={560}>
              <thead>
                <tr>
                  <Th>บัญชี</Th>
                  <Th align="right">เดบิต</Th>
                  <Th align="right">เครดิต</Th>
                </tr>
              </thead>
              <tbody>
                {o.lines.map((l, k) => (
                  <tr key={k}>
                    <Td>
                      {l.code} {l.name}
                      {l.bank ? <div className="text-sm text-ink-600">เข้าบัญชี {l.bank}</div> : null}
                    </Td>
                    <Td align="right">{l.debit ? <Amount value={l.debit} /> : "—"}</Td>
                    <Td align="right">{l.credit ? <Amount value={l.credit} /> : "—"}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </TableShell>
          <div className="flex flex-wrap gap-x-6 gap-y-1 pb-3 text-base">
            <span>สินทรัพย์ {m(o.assets)}</span>
            <span>หนี้สิน {m(o.liabilities)}</span>
            <span>ส่วนของเจ้าของ {m(o.equity)}</span>
            <span className="text-pos-fg">สินทรัพย์ − หนี้สิน − ส่วนของเจ้าของ = {m(o.assets - o.liabilities - o.equity)}</span>
          </div>
        </Section>
      ))}

      {result.lots.length ? (
        <Section title={`หลักทรัพย์รายล็อต (${result.lots.length} ล็อต)`}>
          <TableShell className="my-3">
            <Table minWidth={760}>
              <thead>
                <tr>
                  <Th>ถือในชื่อ</Th>
                  <Th>ชื่อ / ประเภท</Th>
                  <Th>ผูกกับทรัพย์</Th>
                  <Th>วันที่ซื้อ</Th>
                  <Th align="right">หน่วย</Th>
                  <Th align="right">ต้นทุน (บาท)</Th>
                </tr>
              </thead>
              <tbody>
                {result.lots.map((l, k) => (
                  <tr key={k}>
                    <Td>{l.ownerName}</Td>
                    <Td>
                      {l.name} <span className="text-ink-600">({l.kind} → {l.coaCode})</span>
                    </Td>
                    <Td>{l.assetLabel ?? <span className="text-neg-fg">ยังไม่พบทรัพย์</span>}</Td>
                    <Td>{isoToDmy(l.boughtOn)}</Td>
                    <Td align="right" className="tabular-nums">{l.units.toLocaleString("en-US")}</Td>
                    <Td align="right">
                      <Amount value={l.cost} />
                      {l.fxRate !== null && l.amountOriginal !== null ? (
                        <div className="text-sm text-ink-600">
                          {l.amountOriginal.toLocaleString("en-US")} {l.currency} × {l.fxRate}
                        </div>
                      ) : null}
                    </Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </TableShell>
        </Section>
      ) : null}

      {result.evidenceOwners.map((o) => (
        <OwnerEvidence
          key={o.id}
          ownerId={o.id}
          ownerName={o.name}
          value={evidence[o.id] ?? { attachments: [], contactId: "" }}
          onChange={(next) => setEvidence((prev) => ({ ...prev, [o.id]: next }))}
        />
      ))}

      {outcome ? <Outcome outcome={outcome} /> : null}

      {!done ? (
        <div className="flex flex-col gap-3 rounded-card border border-line bg-surface p-4">
          <div className="text-lg font-semibold">ยืนยันลงสมุดบัญชี</div>
          <div className="text-base leading-7">
            กดยืนยัน = ระบบลงยอดตั้งต้น ณ {isoToDmy(result.cutoff)} ตามตัวอย่างข้างบน · ผู้ถือที่เนื้อหาเหมือนเดิมจะไม่ถูกลงซ้ำ ·
            ผู้ถือที่เปลี่ยนจะกลับรายการชุดเดิม (ไม่มีการลบ) แล้วลงชุดใหม่ ทั้งหมดในธุรกรรมเดียวต่อผู้ถือ
            {nothingToDo ? " — ตอนนี้เนื้อหาตรงกับในสมุดทุกคนแล้ว กดยืนยันก็จะไม่มีอะไรเปลี่ยน" : ""}
          </div>
          {!result.canPost ? <div className="text-base text-neg-fg">บัญชีนี้ไม่มีสิทธิ์ลงสมุดบัญชี (ต้องมีสิทธิ์อนุมัติเข้าสมุด)</div> : null}
          {evidenceMissing.length ? (
            <div className="text-base text-warn-fg">ยังกดยืนยันไม่ได้: {evidenceMissing.map((o) => o.name).join(", ")} ต้องแนบหลักฐานและเลือกผู้ติดต่อก่อน</div>
          ) : null}
          {blocked ? <div className="text-base text-neg-fg">ยังกดยืนยันไม่ได้: แก้ปัญหาที่แจ้งไว้ด้านบนแล้วตรวจไฟล์ใหม่</div> : null}
          <div>
            <Button type="button" onClick={onConfirm} disabled={!canConfirm || pending} className="w-full sm:w-auto max-sm:min-h-control-mobile">
              {pending ? "กำลังบันทึกลงสมุด… อย่าปิดหน้านี้" : "ยืนยันบันทึกยอดตั้งต้นลงสมุดบัญชี"}
            </Button>
          </div>
        </div>
      ) : null}
      <div className="text-sm text-ink-600">รหัสตรวจเนื้อหา: {result.fingerprint.slice(0, 16)} (เนื้อหาเดิมจะได้รหัสเดิมเสมอ)</div>
    </div>
  );
}

const STATUS_LABEL: Record<OwnerOutcome["status"], string> = {
  posted: "ลงสมุดแล้ว",
  unchanged: "ไม่เปลี่ยน",
  failed: "ไม่สำเร็จ",
  skipped: "ยังไม่ได้ทำ",
};

function Outcome({ outcome }: { outcome: OpeningConfirmOutcome }) {
  const results = outcome.results;
  return (
    <div className="flex flex-col gap-3">
      {outcome.ok ? (
        <Notice tone="ok">
          <strong>บันทึกยอดตั้งต้นเรียบร้อย</strong>
          <div className="text-base">ผลต่อผู้ถือแต่ละคนอยู่ด้านล่าง</div>
        </Notice>
      ) : (
        <Notice tone="neg">
          <strong>{outcome.message}</strong>
          {outcome.problems?.length ? (
            <ul className="mt-2 flex flex-col gap-2 text-base leading-7">
              {outcome.problems.map((p, i) => (
                <li key={i}>
                  {p.ownerName ? <strong>{p.ownerName}: </strong> : null}
                  {p.message}
                </li>
              ))}
            </ul>
          ) : null}
          {outcome.issues?.length ? (
            <ul className="mt-2 flex flex-col gap-2 text-base leading-7">
              {outcome.issues.map((p, i) => (
                <li key={i}>
                  ชีท {p.sheet}
                  {p.row ? ` แถว ${p.row}` : ""}: {p.message}
                </li>
              ))}
            </ul>
          ) : null}
        </Notice>
      )}
      {results?.length ? (
        <Section title="ผลต่อผู้ถือ">
          <ul className="flex flex-col">
            {results.map((r) => (
              <li key={r.ownerId} className="border-t border-line py-3 text-base leading-7 first:border-t-0">
                <strong>{r.ownerName}</strong> — {STATUS_LABEL[r.status]}
                {r.status === "posted" ? ` · กลับรายการชุดเดิม ${r.reversed} ใบ · ลงใหม่ ${r.posted} ใบ · ล็อต ${r.lots} ล็อต` : ""}
                {r.message && r.status !== "posted" ? <div className="text-ink-600">{r.message}</div> : null}
              </li>
            ))}
          </ul>
        </Section>
      ) : null}
    </div>
  );
}
