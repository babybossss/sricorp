import { PageShell } from "@/components/layout/page-shell";
import { ContactList } from "@/components/form/contact-list";

export default function ContactsPage() {
  return (
    <PageShell title="ผู้ติดต่อ">
      <ContactList />
    </PageShell>
  );
}
