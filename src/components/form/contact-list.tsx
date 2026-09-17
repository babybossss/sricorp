"use client";

import * as React from "react";
import { useApp } from "@/lib/store";
import { CONTACT_KIND_LABEL, contactFullName } from "@/lib/mock/contacts";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { ContactPicker } from "./contact-picker";

/** รายชื่อผู้ติดต่อทั้งหมด — คนที่สร้างจากในฟอร์มบันทึกรายการจะมาโผล่ที่นี่ด้วย */
export function ContactList() {
  const contacts = useApp((s) => s.contacts);
  const [picked, setPicked] = React.useState("");

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-end gap-4 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
        <div className="min-w-[280px] flex-1">
          <ContactPicker value={picked} onSelect={setPicked} label="ค้นหา / เพิ่มผู้ติดต่อ" hint="ปุ่มเดียวกับที่ใช้ในฟอร์มบันทึกรายการ" layer={0} />
        </div>
        <div className="text-base text-ink-600">
          ทั้งหมด <b className="text-ink-900">{contacts.length} คน</b>
        </div>
      </div>

      <TableShell>
        <Table minWidth={900}>
          <thead>
            <tr>
              <Th className="p-[12px_14px]">ชื่อ-นามสกุล</Th>
              <Th className="p-[12px_14px]">ประเภท</Th>
              <Th className="p-[12px_14px]">เบอร์โทร</Th>
              <Th className="p-[12px_14px]">LINE ID</Th>
              <Th className="p-[12px_14px]">อีเมล</Th>
            </tr>
          </thead>
          <tbody>
            {contacts.map((c) => (
              <tr key={c.id} className={picked === c.id ? "bg-brand-50" : undefined}>
                <Td className="p-[12px_14px] font-semibold">{contactFullName(c)}</Td>
                <Td className="p-[12px_14px]">
                  <Pill className="border-line bg-canvas text-ink-600">{CONTACT_KIND_LABEL[c.kind]}</Pill>
                </Td>
                <Td className="p-[12px_14px] text-ink-600">{c.phone || "—"}</Td>
                <Td className="p-[12px_14px] text-ink-600">{c.lineId || "—"}</Td>
                <Td className="p-[12px_14px] text-ink-600">{c.email || "—"}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
      </TableShell>
    </div>
  );
}
