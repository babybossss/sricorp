import { PageShell } from "@/components/layout/page-shell";
import { SettingsLayout } from "@/components/settings/settings-nav";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { USERS } from "@/lib/mock/dashboard";

const ROLE_PILL: Record<string, string> = {
  Management: "border-brand-100 bg-brand-50 text-brand-600",
  Manager: "border-info-bd bg-info-bg text-info-fg",
  User: "border-line bg-canvas text-ink-600",
};

export default function UsersPage() {
  return (
    <PageShell title="ตั้งค่า · ผู้ใช้ & สิทธิ์">
      <SettingsLayout>
        <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(280px,1fr))]">
          <div className="rounded-card border border-brand-100 bg-brand-50 p-[16px_18px] text-base leading-7">
            User / Manager สร้างรายการได้ ต้องรอ Management อนุมัติ
          </div>
          <div className="rounded-card border border-brand-100 bg-brand-50 p-[16px_18px] text-base leading-7">
            Management อนุมัติได้ และข้ามขั้นการอนุมัติได้เมื่อจำเป็น
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-3">
          <div className="text-base text-ink-600">
            ผู้ใช้ทั้งหมด <b className="text-ink-900">{USERS.length} คน</b>
          </div>
          <Button className="ml-auto">เชิญผู้ใช้</Button>
        </div>

        <TableShell>
          <Table minWidth={900}>
            <thead>
              <tr>
                <Th className="p-[12px_14px]">ชื่อ</Th>
                <Th className="p-[12px_14px]">อีเมล</Th>
                <Th className="p-[12px_14px]">สิทธิ์</Th>
                <Th className="p-[12px_14px]">ผูกกับผู้ถือ</Th>
                <Th className="p-[12px_14px]">สถานะ</Th>
                <Th className="p-[12px_14px]">เข้าใช้ล่าสุด</Th>
                <Th className="p-[12px_14px]" />
              </tr>
            </thead>
            <tbody>
              {USERS.map((u) => (
                <tr key={u.email}>
                  <Td className="p-[12px_14px]">
                    <div className="flex items-center gap-2.5">
                      <div className="flex h-10 w-10 items-center justify-center rounded-pill bg-brand-50 text-sm font-bold text-brand-600">{u.initial}</div>
                      <b>{u.name}</b>
                    </div>
                  </Td>
                  <Td className="p-[12px_14px] text-ink-600">{u.email}</Td>
                  <Td className="p-[12px_14px]">
                    <Pill className={ROLE_PILL[u.role]}>{u.role}</Pill>
                  </Td>
                  <Td className="p-[12px_14px] text-ink-600">{u.owner}</Td>
                  <Td className="p-[12px_14px]">{u.status}</Td>
                  <Td className="p-[12px_14px] text-ink-600">{u.last}</Td>
                  <Td className="p-[12px_14px]">
                    <Button variant="secondary" size="sm">แก้ไขสิทธิ์</Button>
                  </Td>
                </tr>
              ))}
            </tbody>
          </Table>
        </TableShell>
      </SettingsLayout>
    </PageShell>
  );
}
