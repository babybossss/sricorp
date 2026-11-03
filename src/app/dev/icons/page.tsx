import { PageShell } from "@/components/layout/page-shell";
import { AssetKindIcon, ICON_KINDS } from "@/components/assets/asset-kind-icon";
import { KIND_LABEL } from "@/lib/mock/assets";
import { SIDEBAR_ICON_OPTIONS, OptionIcon } from "@/components/dev/sidebar-icon-options";
import { gateRoute } from "@/lib/auth/gate";

/** หน้าดูไอคอน — ไว้ให้ลูกพี่เลือก ไม่ได้อยู่ในเมนู */
export default async function IconsPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/dev", "ไอคอนให้เลือก");
  if (denied) return denied;

  const label: Record<string, string> = { ...KIND_LABEL, other: "ทรัพย์อื่น" };

  return (
    <PageShell title="ไอคอนให้เลือก">
      <div className="flex flex-col gap-5">
        <div className="flex flex-col gap-3 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
          <div>
            <div className="text-h2 font-semibold">เมนู &ldquo;งบดุล &amp; ทรัพย์สิน&rdquo;</div>
            <div className="text-base text-ink-600">แสดงขนาดจริง 22px ในกรอบเมนูจริง — บอกเลขที่ชอบมาได้เลย</div>
          </div>
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {SIDEBAR_ICON_OPTIONS.map((o, i) => (
              <div key={o.key} className="flex flex-col gap-2 rounded-card border border-line bg-canvas p-3">
                <div className="flex items-center gap-2">
                  <span className="inline-flex h-7 w-7 flex-none items-center justify-center rounded-pill border border-line bg-canvas text-sm font-semibold tabular-nums">
                    {i + 1}
                  </span>
                  <span className="text-base font-semibold">{o.label}</span>
                </div>
                {/* กรอบเมนูจริง ทั้งตอนปกติและตอนถูกเลือก */}
                <div className="flex flex-col gap-1 rounded-card border border-line bg-surface p-[8px_6px]">
                  <span className="flex items-center gap-2.5 rounded-card p-[10px_12px] text-base text-ink-600">
                    <OptionIcon paths={o.paths} />
                    งบดุล &amp; ทรัพย์สิน
                  </span>
                  <span className="flex items-center gap-2.5 rounded-card bg-brand-50 p-[10px_12px] text-base font-semibold text-brand">
                    <OptionIcon paths={o.paths} />
                    งบดุล &amp; ทรัพย์สิน
                  </span>
                </div>
                <div className="text-sm text-ink-400">{o.note}</div>
              </div>
            ))}
          </div>
        </div>

        <div className="flex flex-col gap-3 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
          <div className="text-h2 font-semibold">ไอคอนชนิดทรัพย์ (ใช้อยู่แล้ว)</div>
          <div className="flex flex-wrap gap-5">
            {ICON_KINDS.map((k) => (
              <div key={k} className="flex flex-col items-center gap-2">
                <AssetKindIcon kind={k} size={48} />
                <span className="text-sm text-ink-600">{label[k]}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </PageShell>
  );
}
