import { PageShell } from "@/components/layout/page-shell";
import { AssetDetail } from "@/components/assets/asset-detail";
import { ASSETS } from "@/lib/mock/assets";

export default async function AssetPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const asset = ASSETS.find((a) => a.id === id) ?? ASSETS[0];

  return (
    <PageShell title={asset.name}>
      <AssetDetail name={asset.name} />
    </PageShell>
  );
}
