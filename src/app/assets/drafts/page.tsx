import { PageShell } from "@/components/layout/page-shell";
import { DraftQueue } from "@/components/assets/draft-queue";
import { Notice } from "@/components/assets/asset-parts";
import { loadDraftPage } from "@/lib/db/assets-server";
import { gateDraftPages } from "../_gate";

export default async function AssetDraftsPage() {
  const g = await gateDraftPages("ร่างทรัพย์รออนุมัติ");
  if (g.denied) return g.denied;

  // ร่างที่เห็นให้ RLS `asset_drafts_read` กรอง (Staff เห็นแค่ของตัวเอง) — ไม่กรองสิทธิ์ใน TS
  const data = await loadDraftPage();

  return (
    <PageShell title="ร่างทรัพย์รออนุมัติ">
      {data.ok ? (
        <DraftQueue drafts={data.drafts} assets={data.assets} taxonomy={data.taxonomy} owners={data.owners} currentUser={g.user} />
      ) : (
        <Notice tone="neg">โหลดคิวร่างจากฐานข้อมูลไม่สำเร็จ: {data.error}</Notice>
      )}
    </PageShell>
  );
}
