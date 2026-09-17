import { PageShell } from "@/components/layout/page-shell";
import { SettingsLayout } from "@/components/settings/settings-nav";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { TYPE_PILL } from "@/lib/tone";
import {
  TX_TYPES,
  REQUIREMENT_LABEL,
  CASHFLOW_LABEL,
  SIDE_LABEL,
  effectsOf,
} from "@/lib/rules/tx-rules";
import { coa } from "@/lib/rules/coa";

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
          <div className="mt-2 text-sm text-ink-600">
            ผลกระทบต่องบในตารางนี้ <b>คำนวณจากคู่บัญชี</b> ที่แสดงในคอลัมน์ &ldquo;ลงบัญชี&rdquo; ไม่ได้พิมพ์แยกไว้
            คำอธิบายกับการลงบัญชีจริงจึงไม่มีทางไม่ตรงกัน · ผังบัญชีตรวจทานกับ SRI_Transaction_ERP.xlsx แล้ว
          </div>
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
              <Table minWidth={1240}>
                <thead>
                  <tr>
                    <Th className="p-[12px_14px]">หมวดย่อย</Th>
                    <Th>ลงบัญชี</Th>
                    <Th align="right">กำไรขาดทุน (P&amp;L)</Th>
                    <Th>งบดุล (Balance Sheet)</Th>
                    <Th>กระแสเงินสด (CF)</Th>
                    <Th className="p-[12px_14px]">ต้องกรอกเพิ่ม</Th>
                  </tr>
                </thead>
                <tbody>
                  {t.subs.map((s) => {
                    const { pl, bs } = effectsOf(s);
                    return (
                      <tr key={s.code} className="align-top">
                        <Td className="p-[12px_14px]">
                          <div className="font-semibold">{s.label}</div>
                          {s.en ? <div className="text-sm text-ink-400">{s.en}</div> : null}
                          <div className="mt-1 text-sm leading-6 text-ink-600">{s.plain}</div>
                          {s.caution ? (
                            <div className="mt-1.5 rounded border border-warn bg-warn-bg p-[8px_10px] text-sm leading-6 text-warn-fg">
                              ⚠ {s.caution}
                            </div>
                          ) : null}
                        </Td>

                        <Td className="whitespace-nowrap text-sm">
                          <div>
                            <span className="text-ink-400">Dr </span>
                            {s.dr} {coa(s.dr).nameTh}
                          </div>
                          <div>
                            <span className="text-ink-400">Cr </span>
                            {s.cr} {coa(s.cr).nameTh}
                          </div>
                        </Td>

                        <Td align="right" className="whitespace-nowrap">
                          {pl ? (
                            <span className={pl.kind === "expense" ? "text-neg" : "text-pos"}>
                              {pl.kind === "expense" ? "ค่าใช้จ่าย" : "รายได้"}
                              <br />
                              <span className="text-sm text-ink-600">{pl.line}</span>
                            </span>
                          ) : (
                            <span className="text-ink-400">ไม่กระทบ</span>
                          )}
                        </Td>

                        <Td className="text-sm">
                          {bs.length ? (
                            <ul className="m-0 flex list-none flex-col gap-1 p-0">
                              {bs.map((b, i) => (
                                <li key={`${b.line}-${i}`}>
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
                          {CASHFLOW_LABEL[s.cashflow]}
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
                    );
                  })}
                </tbody>
              </Table>
            </TableShell>
          </div>
        ))}

        <div className="rounded-card border border-line bg-surface p-[16px_18px] text-sm leading-6 text-ink-600 shadow-card">
          ข้อ 2 (ฟอร์มเงื่อนไขสัญญากู้), ข้อ 4 (คำนวณ Cap Gain/Loss) และ ข้อ 5 (แยกเงินต้น/ดอกเบี้ย) ใน backlog
          ผูกไว้กับตารางนี้แล้วผ่านคอลัมน์ <b>ต้องกรอกเพิ่ม</b> — ฟอร์มจะรู้ว่าต้องเปิดหน้าต่างไหนเมื่อเลือกหมวดย่อยนั้น
        </div>
      </SettingsLayout>
    </PageShell>
  );
}
