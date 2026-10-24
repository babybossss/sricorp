import type { ProfitLoss, UnrealisedBox } from "@/lib/db/statements";
import { Notice, Row, Section, m } from "./parts";

/**
 * งบกำไรขาดทุน — รายได้ − ค่าใช้จ่ายตาม doc_date ในปีบัญชี ม.ค.–ธ.ค.
 *
 * "กำไร/ขาดทุนที่ยังไม่เกิดขึ้นจริง" (ตีราคาทรัพย์ · แปลงค่าเงินฝากต่างประเทศ) อยู่ในกล่องแยกด้านล่าง
 * **ไม่ใช่บรรทัดต่อท้ายกำไรสุทธิ และไม่รวมกับตัวเลขใดข้างบน** (ลูกพี่สั่ง 24/10 ย้ำ 25/10)
 */
export function ProfitLossView({ pl, unrealised, ownerLabel }: { pl: ProfitLoss; unrealised: UnrealisedBox; ownerLabel: string }) {
  return (
    <div className="flex flex-col gap-4">
      <div className="text-base text-ink-600">
        {ownerLabel} · 1 ม.ค. – 31 ธ.ค. {pl.year} · นับตามวันที่เอกสาร (รวมรายการที่ยังไม่ได้รับ-จ่ายเงิน)
      </div>

      {pl.unmapped.length ? (
        <Notice tone="neg">
          มียอดบัญชีที่โครงงบไม่มีบรรทัดรองรับ: {pl.unmapped.map((u) => `${u.code} (${m(u.amount)})`).join(", ")} — ตัวเลขด้านล่างยังไม่ครบ
        </Notice>
      ) : null}

      {pl.sections.map((s) => (
        <Section key={s.section} title={s.section}>
          {s.lines.map((l) => (
            <Row key={l.line} label={l.line} value={l.amount} />
          ))}
          <Row label={`รวม${s.section}`} value={s.total} strong />
        </Section>
      ))}

      <Section title="กำไร(ขาดทุน)สุทธิ">
        <Row label="รวมรายได้" value={pl.totalRevenue} />
        <Row label="หัก รวมค่าใช้จ่ายทั้งหมด" value={pl.totalExpense} />
        <Row label={`กำไร(ขาดทุน)สุทธิปี ${pl.year}`} value={pl.netProfit} strong />
      </Section>

      <Section title="กำไร/ขาดทุนที่ยังไม่เกิดขึ้นจริง — ไม่รวมในกำไรขาดทุนข้างบน" tone="separate">
        <p className="py-3 text-base leading-7 text-ink-600">
          เป็นผลของการตีราคาทรัพย์หรือการแปลงค่าเงินฝากต่างประเทศ <b>ยังไม่ได้ขาย/แลกจริง</b> จึงไม่ใช่กำไรของงบนี้
          ลงเป็นส่วนของเจ้าของในงบแสดงฐานะการเงิน และจะเข้ากำไรขาดทุนเมื่อขายหรือแลกเป็นบาทจริงเท่านั้น
        </p>
        {unrealised.rows.map((r) => (
          <Row
            key={r.code}
            label={`${r.code} ${r.name}`}
            value={r.closing}
            note={`ยกมาต้นปี ${m(r.opening)} · เปลี่ยนแปลงในปี ${m(r.movement)} · ยอดสิ้นปีคือตัวเลขทางขวา`}
          />
        ))}
        <Row label="รวมที่ยังไม่เกิดขึ้นจริง (ไม่บวกกับกำไรสุทธิ)" value={unrealised.total} strong />
      </Section>
    </div>
  );
}
