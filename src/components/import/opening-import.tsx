"use client";

import * as React from "react";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Table, TableShell, Td, Th } from "@/components/ui/table";
import { Amount, Notice, Section, m } from "@/components/reports/parts";
import { previewOpeningImport, type OpeningPreview } from "@/app/actions/import-opening";
import { isoToDmy } from "@/lib/format";

/**
 * นำเข้ายอดตั้งต้น — ขั้นตรวจไฟล์ + พรีวิว (ยังไม่บันทึกอะไร)
 * ไม่มีปุ่มยืนยันลงสมุดในรอบนี้ โดยตั้งใจ: ลงจริงต้องรอประเภทรายการ "ยอดตั้งต้น" และหลักยึดฝั่ง DB
 */
export function OpeningImport() {
  const [pending, start] = React.useTransition();
  const [result, setResult] = React.useState<OpeningPreview | null>(null);
  const [crash, setCrash] = React.useState<string | null>(null);

  function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    setResult(null);
    setCrash(null);
    start(async () => {
      try {
        setResult(await previewOpeningImport(fd));
      } catch {
        setCrash("ส่งไฟล์ไม่สำเร็จ (อาจใหญ่เกินไปหรือเน็ตหลุด) — ลองใหม่อีกครั้ง ยังไม่มีอะไรถูกบันทึก");
      }
    });
  }

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <Notice tone="info">
        <strong>หน้านี้ตรวจไฟล์และแสดงตัวอย่างเท่านั้น — ยังไม่บันทึกอะไรลงสมุดบัญชี</strong>
        <div className="text-base">ตรวจทั้งไฟล์ในครั้งเดียว ถ้ามีจุดผิดแม้จุดเดียวจะไม่นำเข้าเลย และบอกว่าผิดที่ชีทไหนแถวไหน</div>
      </Notice>

      <form onSubmit={onSubmit} className="flex flex-col gap-4 rounded-card border border-line bg-surface p-4 shadow-card">
        <Field label="วันตัดยอด (วว/ดด/ปปปป)" hint="ต้องเป็นวันเดียวกับที่เขียนไว้ในหัวทุกชีทของไฟล์ เช่น 31/10/2026" required>
          <Input name="cutoff" inputMode="numeric" autoComplete="off" placeholder="31/10/2026" required />
        </Field>
        <Field label="ไฟล์ Excel ยอดตั้งต้น (.xlsx)" hint="ไฟล์ที่กรอกจากเทมเพลต “ยอดตั้งต้นงบดุล” ขนาดไม่เกิน 10 MB" required>
          <Input name="file" type="file" accept=".xlsx" required className="py-3" />
        </Field>
        <div>
          <Button type="submit" disabled={pending} className="w-full sm:w-auto max-sm:min-h-control-mobile">
            {pending ? "กำลังตรวจไฟล์…" : "ตรวจไฟล์และดูตัวอย่าง"}
          </Button>
        </div>
      </form>

      {crash ? <Notice tone="neg">{crash}</Notice> : null}
      {result && !result.ok ? <Rejected result={result} /> : null}
      {result && result.ok ? <Preview result={result} /> : null}
    </div>
  );
}

function Rejected({ result }: { result: Extract<OpeningPreview, { ok: false }> }) {
  const bySheet = new Map<string, typeof result.issues>();
  for (const i of result.issues) bySheet.set(i.sheet, [...(bySheet.get(i.sheet) ?? []), i]);
  return (
    <div className="flex min-w-0 flex-col gap-4">
      <Notice tone="neg">
        <strong>{result.message}</strong>
      </Notice>
      {[...bySheet].map(([sheet, issues]) => (
        <Section key={sheet} title={`ชีท: ${sheet}`}>
          <ul className="flex flex-col">
            {issues.map((i, k) => (
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

function Preview({ result }: { result: Extract<OpeningPreview, { ok: true }> }) {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <Notice tone="ok">
        <strong>ไฟล์ผ่านการตรวจทั้งหมด</strong> · วันตัดยอด {isoToDmy(result.cutoff)} · {result.totals.owners} ผู้ถือ · {result.totals.lines} บรรทัดบัญชี
        <div className="text-base">ยังไม่ได้บันทึก — ด้านล่างคือสิ่งที่จะลงเมื่อเปิดใช้ขั้นบันทึก</div>
      </Notice>
      {result.warnings.map((w) => (
        <Notice key={w} tone="warn">
          {w}
        </Notice>
      ))}

      <h2 className="text-h2 font-semibold">ระบบจะบันทึกให้ดังนี้ (ตัวอย่าง)</h2>
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
            <Table minWidth={640}>
              <thead>
                <tr>
                  <Th>ถือในชื่อ</Th>
                  <Th>ชื่อ / ประเภท</Th>
                  <Th>วันที่ซื้อ</Th>
                  <Th align="right">หน่วย</Th>
                  <Th align="right">ต้นทุนรวมค่าธรรมเนียม</Th>
                </tr>
              </thead>
              <tbody>
                {result.lots.map((l, k) => (
                  <tr key={k}>
                    <Td>{l.ownerName}</Td>
                    <Td>
                      {l.name} <span className="text-ink-600">({l.kind} → {l.coaCode})</span>
                    </Td>
                    <Td>{isoToDmy(l.boughtOn)}</Td>
                    <Td align="right" className="tabular-nums">{l.units.toLocaleString("en-US")}</Td>
                    <Td align="right"><Amount value={l.cost} /></Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </TableShell>
        </Section>
      ) : null}

      <Notice tone="warn">
        <strong>ขั้นบันทึกลงสมุดยังไม่เปิด</strong>
        <div className="text-base">
          ต้องมีประเภทรายการ “ยอดตั้งต้น” ในตารางกฎและหลักยึดฝั่งฐานข้อมูลสำหรับกลับรายการชุดเดิมเมื่ออัปโหลดใหม่ก่อน — ตอนนี้จึงยังไม่มีปุ่มยืนยัน
        </div>
      </Notice>
      <div className="text-sm text-ink-600">รหัสตรวจเนื้อหา: {result.fingerprint.slice(0, 16)} (เนื้อหาเดิมจะได้รหัสเดิมเสมอ)</div>
    </div>
  );
}
