import { PageShell } from "@/components/layout/page-shell";
import { DraftQueue } from "@/components/assets/draft-queue";
import { gateDraftPages } from "../_gate";

export default async function AssetDraftsPage() {
  const g = await gateDraftPages("ร่างทรัพย์รออนุมัติ");
  if (g.denied) return g.denied;

  return (
    <PageShell title="ร่างทรัพย์รออนุมัติ">
      <DraftQueue currentUser={g.user} />
    </PageShell>
  );
}
