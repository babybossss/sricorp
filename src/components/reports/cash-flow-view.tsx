import type { CashFlowReport } from "@/lib/db/statements";
import { Amount, Notice, Row, Section, m } from "./parts";

/** งบกระแสเงินสด (วิธีตรง) — นับตาม cash_date · รายการที่ยังไม่รับ/จ่ายเงิน (cash_date ว่าง) ไม่อยู่ในงบนี้ */
export function CashFlowView({ cf, ownerLabel }: { cf: CashFlowReport; ownerLabel: string }) {
  const s = cf.statement;
  return (
    <div className="flex flex-col gap-4">
      <div className="text-base text-ink-600">
        {ownerLabel} · 1 ม.ค. – 31 ธ.ค. {cf.year} · นับตามวันที่เงินเข้า/ออกจริง
      </div>

      {s.reconciled ? (
        <Notice tone="ok">งบกระแสเงินสดกระทบยอดลงตัว: เงินสดต้นงวด + การเปลี่ยนแปลง = เงินสดปลายงวด</Notice>
      ) : (
        <Notice tone="neg">
          <b>งบกระแสเงินสดไม่กระทบยอด</b> ต่างกัน {m(s.difference)} บาท — ห้ามใช้ตัวเลขนี้ก่อนหาสาเหตุ
        </Notice>
      )}
      {s.anomalies
        .filter((a) => a.kind !== "unreconciled")
        .map((a, i) => (
          <Notice key={`${a.kind}-${i}`} tone="warn">
            {a.message}
          </Notice>
        ))}

      {s.sections.map((sec) => (
        <Section key={sec.section} title={sec.title}>
          {sec.lines.length === 0 ? <p className="py-3 text-base text-ink-600">ไม่มีเงินเคลื่อนไหวในกิจกรรมนี้</p> : null}
          {sec.lines.map((l) => (
            <Row
              key={l.line}
              label={l.line}
              value={l.amount}
              note={l.inflow > 0 && l.outflow > 0 ? `เข้า ${m(l.inflow)} · ออก ${m(-l.outflow)}` : undefined}
            />
          ))}
          <Row label={`เงินสดสุทธิจาก${sec.sectionTh}`} value={sec.total} strong />
        </Section>
      ))}

      <Section title="สรุปเงินสด">
        <Row label="เงินสดและเงินฝากต้นงวด" value={s.openingCash} note="คำนวณจากทุกรายการที่บันทึกก่อน 1 ม.ค." />
        <Row label="เงินสดสุทธิจากทั้งสามกิจกรรม" value={s.netChange} />
        <Row
          label="ผลกระทบของอัตราแลกเปลี่ยนต่อเงินสด"
          value={s.fxEffect}
          note="ยอดบาทของบัญชีเงินฝากต่างประเทศที่ขยับเพราะค่าเงิน — ไม่ใช่เงินเข้า-ออกจริง"
        />
        <Row label="เงินสดและเงินฝากปลายงวด" value={s.closingCash} strong />
        <Row
          label="เงินสดในงบแสดงฐานะการเงิน ณ 31 ธ.ค."
          value={cf.balanceSheetCash}
          note={
            cf.tiesOut
              ? "ตรงกับเงินสดปลายงวดข้างบนทุกสตางค์"
              : undefined
          }
        />
        {!cf.tiesOut ? (
          <div className="border-t border-line py-3">
            <Notice tone="warn">
              เงินสดระหว่างทาง <Amount value={cf.cashInTransit} /> บาท — มีรายการที่ <b>วันที่เอกสาร</b> อยู่ในปีนี้แต่
              <b>วันที่เงินเข้า/ออกจริง</b> อยู่คนละปี งบแสดงฐานะการเงินนับตามวันที่เอกสาร งบกระแสเงินสดนับตามวันที่เงินจริง
              ส่วนต่างนี้คือยอดเหล่านั้น (ตรวจวันที่ของรายการในสมุดบัญชี)
            </Notice>
          </div>
        ) : null}
      </Section>
    </div>
  );
}
