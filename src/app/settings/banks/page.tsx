import { PageShell } from "@/components/layout/page-shell";
import { SettingsLayout } from "@/components/settings/settings-nav";
import { BankSettings } from "@/components/settings/bank-settings";

export default function BanksPage() {
  return (
    <PageShell title="ตั้งค่า · บัญชีธนาคาร">
      <SettingsLayout>
        <BankSettings />
      </SettingsLayout>
    </PageShell>
  );
}
