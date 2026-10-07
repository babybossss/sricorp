import { PageShell } from "@/components/layout/page-shell";
import { ContactList } from "@/components/form/contact-list";
import { gateRoute } from "@/lib/auth/gate";

export default async function ContactsPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/contacts", "ผู้ติดต่อ");
  if (denied) return denied;

  return (
    <PageShell title="ผู้ติดต่อ">
      <ContactList />
    </PageShell>
  );
}
