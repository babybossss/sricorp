import { BS_SIDE_TH } from "@/lib/rules/statements";
import type { BalanceSheet } from "@/lib/db/statements";
import { Amount, Notice, Row, Section, m } from "./parts";

export function BalanceSheetView({ bs, ownerLabel }: { bs: BalanceSheet; ownerLabel: string }) {
  const sides = ["asset", "liability", "equity"] as const;
  const totals = { asset: bs.totalAssets, liability: bs.totalLiabilities, equity: bs.totalEquity };

  return (
    <div className="flex flex-col gap-4">
      <div className="text-base text-ink-600">
        {ownerLabel} · ณ วันที่ 31 ธ.ค. {bs.year}
        {bs.consolidated ? " · งบรวม (ตัดรายการระหว่างกันที่หักกันได้พอดี)" : ""}
      </div>

      {bs.balanced ? (
        <Notice tone="ok">
          งบดุล: สินทรัพย์ {m(bs.totalAssets)} = หนี้สิน + ส่วนของเจ้าของ {m(bs.totalLiabilitiesAndEquity)}
        </Notice>
      ) : (
        <Notice tone="neg">
          <b>งบไม่ดุล</b> — สินทรัพย์ {m(bs.totalAssets)} ต่างจากหนี้สิน + ส่วนของเจ้าของ {m(bs.totalLiabilitiesAndEquity)} อยู่ {m(bs.difference)} บาท
          มีรายการที่บันทึกไม่สมบูรณ์ ห้ามใช้ตัวเลขนี้ก่อนหาสาเหตุ
        </Notice>
      )}
      {bs.anomalies.map((a) => (
        <Notice key={a} tone="warn">
          {a}
        </Notice>
      ))}

      {sides.map((side) => (
        <Section key={side} title={BS_SIDE_TH[side]}>
          {bs.groups
            .filter((g) => g.side === side)
            .map((g) => (
              <div key={g.group} className="border-t border-line first:border-t-0">
                <div className="pt-3 text-sm font-semibold text-ink-600">{g.group}</div>
                {g.lines.map((l) => (
                  <Row key={l.line} label={l.line} value={l.amount} note={l.note} indent />
                ))}
              </div>
            ))}
          <div className="flex items-start justify-between gap-3 border-t-2 border-line py-3 text-base font-semibold">
            <span>รวม{BS_SIDE_TH[side]}</span>
            <Amount value={totals[side]} />
          </div>
        </Section>
      ))}

      <Section title="รวมหนี้สินและส่วนของเจ้าของ">
        <Row label="รวมหนี้สิน" value={bs.totalLiabilities} />
        <Row label="รวมส่วนของเจ้าของ" value={bs.totalEquity} />
        <Row label="รวมหนี้สินและส่วนของเจ้าของ" value={bs.totalLiabilitiesAndEquity} strong />
      </Section>

      {bs.eliminated !== 0 ? (
        <Notice tone="info">ตัดรายการระหว่างกัน (ลูกหนี้/เจ้าหนี้ระหว่างกัน) ออกจากงบรวมแล้ว {m(bs.eliminated)} บาทต่อฝั่ง</Notice>
      ) : null}
    </div>
  );
}
