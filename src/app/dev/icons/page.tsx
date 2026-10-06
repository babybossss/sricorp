import { PageShell } from "@/components/layout/page-shell";
import { AssetKindIcon, ICON_KINDS } from "@/components/assets/asset-kind-icon";
import { KIND_LABEL } from "@/lib/mock/assets";

/** หน้าดูไอคอนทั้งชุด — ไว้ให้ลูกพี่เลือก ไม่ได้อยู่ในเมนู */
export default function IconsPage() {
  const label: Record<string, string> = { ...KIND_LABEL, other: "ทรัพย์อื่น" };
  return (
    <PageShell title="ไอคอนชนิดทรัพย์">
      <div className="flex flex-col gap-5">
        {[64, 40, 24].map((size) => (
          <div key={size} className="flex flex-col gap-3 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
            <div className="text-base font-semibold">ขนาด {size}px</div>
            <div className="flex flex-wrap gap-5">
              {ICON_KINDS.map((k) => (
                <div key={k} className="flex flex-col items-center gap-2">
                  <AssetKindIcon kind={k} size={size} />
                  <span className="text-sm text-ink-600">{label[k]}</span>
                </div>
              ))}
            </div>
          </div>
        ))}
        <div className="flex flex-col gap-3 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
          <div className="text-base font-semibold">แบบจาง (ทรัพย์ที่หยุดไว้)</div>
          <div className="flex flex-wrap gap-5">
            {ICON_KINDS.map((k) => (
              <AssetKindIcon key={k} kind={k} size={56} muted />
            ))}
          </div>
        </div>
      </div>
    </PageShell>
  );
}
