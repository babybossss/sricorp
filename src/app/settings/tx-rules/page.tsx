import { PageShell } from "@/components/layout/page-shell";
import { SettingsLayout } from "@/components/settings/settings-nav";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { TYPE_PILL } from "@/lib/tone";
import { TX_TYPES, REQUIREMENT_LABEL } from "@/lib/rules/tx-rules";

const CF_LABEL: Record<string, string> = { operating: "ดำเนินงาน", investing: "ลงทุน", financing: "จัดหาเงิน" };
const SIDE_LABEL: Record<string, string> = { asset: "สินทรัพย์", liability: "หนี้สิน", equity: "ส่วนของเจ้าของ" };

/**
 * ตารางกฎเดียวที่ระบบอ้างอิง (Backlog ข้อ 1)
 * หน้านี้เป็นมุมมองอ่านอย่างเดียวของ `src/lib/rules/tx-rules.ts`
 * ฟอร์มบันทึกรายการดึงหมวดย่อยจากตารางเดียวกันนี้ จึงไม่มีทางลงผิดหมวด
 */
export default function TxRulesPage() {
  return (
    <PageShell title="ตั้งค่า · ผังบัญชี & ประเภทรายการ">
      <SettingsLayout>
        <div className="rounded-card border border-brand-100 bg-brand-50 p-[16px_18px] text-base leading-7">
          นี่คือ<b>ตารางกฎเดียว</b>ที่ทั้งระบบอ้างอิง — ฟอร์มบันทึกรายการจะให้เลือกหมวดย่อยได้เฉพาะที่อยู่ใต้ประเภทรายการนั้น
          เท่านั้น เช่น <b>กู้เงินเพิ่ม</b> อยู่ใต้ <b>กู้/เพิ่มทุน</b> ไม่มีทางเลือกจาก <b>รายได้</b> ได้ เพราะเงินเข้าบัญชีแต่ไม่ใช่รายได้
        </div>

        {TX_TYPES.map((t) => (
          <div key={t.key} className="flex flex-col gap-2">
            <div className="flex flex-wrap items-center gap-3">
              <Pill size="md" className={TYPE_PILL[t.tone]}>{t.label}</Pill>
              <span className="text-sm text-ink-600">{t.desc}</span>
              <span className="text-sm text-ink-400">
                เงิน{t.cash === "in" ? "เข้า" : t.cash === "out" ? "ออก" : "เข้า/ออก"} · {t.subs.length} หมวดย่อย
              </span>
            </div>

            <TableShell>
              <Table minWidth={1040}>
                <thead>
                  <tr>
                    <Th className="p-[12px_14px]">หมวดย่อย</Th>
                    <Th align="right">กำไรขาดทุน (P&amp;L)</Th>
                    <Th>งบดุล (Balance Sheet)</Th>
                    <Th>กระแสเงินสด (CF)</Th>
                    <Th className="p-[12px_14px]">ต้องกรอกเพิ่ม</Th>
                  </tr>
                </thead>
                <tbody>
                  {t.subs.map((s) => (
                    <tr key={s.code} className="align-top">
                      <Td className="p-[12px_14px]">
                        <div className="font-semibold">{s.label}</div>
                        {s.en ? <div className="text-sm text-ink-400">{s.en}</div> : null}
                        <div className="mt-1 text-sm leading-6 text-ink-600">{s.plain}</div>
                        {s.caution ? (
                          <div className="mt-1.5 rounded border border-warn bg-warn-bg p-[8px_10px] text-sm leading-6 text-warn-fg">⚠ {s.caution}</div>
                        ) : null}
                      </Td>
                      <Td align="right" className="whitespace-nowrap">
                        {s.pl ? (
                          <span className={s.pl.kind === "expense" ? "text-neg" : "text-pos"}>
                            {s.pl.kind === "expense" ? "ค่าใช้จ่าย" : "รายได้"}
                            <br />
                            <span className="text-sm text-ink-600">{s.pl.line}</span>
                          </span>
                        ) : (
                          <span className="text-ink-400">ไม่กระทบ</span>
                        )}
                      </Td>
                      <Td className="text-sm">
                        {s.bs?.length ? (
                          <ul className="m-0 flex list-none flex-col gap-1 p-0">
                            {s.bs.map((b) => (
                              <li key={b.line}>
                                <span className="text-ink-400">{SIDE_LABEL[b.side]} · </span>
                                {b.line}{" "}
                                <span className={b.direction === "increase" ? "text-pos" : "text-neg"}>
                                  {b.direction === "increase" ? "▲ เพิ่ม" : "▼ ลด"}
                                </span>
                              </li>
                            ))}
                          </ul>
                        ) : (
                          <span className="text-ink-400">ไม่กระทบ</span>
                        )}
                      </Td>
                      <Td className="whitespace-nowrap text-sm">
                        {CF_LABEL[s.cashflow]}
                        <br />
                        <span className={s.cash === "out" ? "text-neg" : "text-pos"}>
                          เงิน{s.cash === "in" ? "เข้า" : s.cash === "out" ? "ออก" : "ย้ายบัญชี"}
                        </span>
                      </Td>
                      <Td className="p-[12px_14px]">
                        {s.requires?.length ? (
                          <div className="flex flex-wrap gap-1.5">
                            {s.requires.map((r) => (
                              <Pill key={r} className="border-brand-100 bg-brand-50 text-brand-600">
                                {REQUIREMENT_LABEL[r]}
                              </Pill>
                            ))}
                          </div>
                        ) : (
                          <span className="text-sm text-ink-400">—</span>
                        )}
                      </Td>
                    </tr>
                  ))}
                </tbody>
              </Table>
            </TableShell>
          </div>
        ))}

        <div className="rounded-card border border-line bg-surface p-[16px_18px] text-sm leading-6 text-ink-600 shadow-card">
          ข้อ 2 (ฟอร์มเงื่อนไขสัญญากู้), ข้อ 4 (คำนวณ Cap Gain/Loss) และ ข้อ 5 (แยกเงินต้น/ดอกเบี้ย) ใน backlog
          ผูกไว้กับตารางนี้แล้วผ่านคอลัมน์ <b>ต้องกรอกเพิ่ม</b> — ฟอร์มจะรู้ว่าต้องเปิดหน้าต่างไหนเมื่อเลือกหมวดย่อยนั้น
          ส่วนตัวหน้าต่างกรอกเงื่อนไขจะทำในรอบถัดไป
        </div>
      </SettingsLayout>
    </PageShell>
  );
}
