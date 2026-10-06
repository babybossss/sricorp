"use client";

import * as React from "react";
import "leaflet/dist/leaflet.css";
import type { AssetRef } from "@/lib/mock/assets";
import { HOLDING_LABEL, monthlyFor } from "@/lib/mock/assets";
import { signedMoney } from "@/lib/format";
import { entityById } from "@/lib/mock/entities";

/**
 * แผนที่ปักหมุดทรัพย์ — ใช้ Leaflet ตรงๆ ผ่าน useEffect
 *
 * เลือกโหลดเองแทนที่จะใช้ตัวห่อ React เพราะแผนที่ต้องสร้างหลัง DOM พร้อม
 * และต้องทำลายทิ้งตอนสลับแบบ ไม่งั้นจะเหลือแผนที่ซ้อนกันหลายชั้น
 *
 * **ทรัพย์ที่ไม่มีพิกัดจะไม่หายไปเงียบๆ** — ขึ้นรายการไว้ใต้แผนที่พร้อมบอกว่าทำไม
 * ไฟล์จริงของลูกพี่มีช่อง Google Maps ที่กรอกมาสามแบบปนกัน (พิกัด DMS · ลิงก์ย่อ ·
 * ชื่อสถานที่เฉยๆ) สองแบบหลังปักหมุดไม่ได้จนกว่าจะแปลงเป็นพิกัด
 */
export function AssetMap({ rows, onOpen }: { rows: AssetRef[]; onOpen: (id: string) => void }) {
  const ref = React.useRef<HTMLDivElement>(null);
  const [failed, setFailed] = React.useState(false);
  const pinned = rows.filter((a) => a.location?.lat != null && a.location?.lng != null);
  const missing = rows.filter((a) => a.location?.lat == null || a.location?.lng == null);

  React.useEffect(() => {
    let map: { remove: () => void } | null = null;
    let cancelled = false;

    (async () => {
      try {
        const L = (await import("leaflet")).default;
        if (cancelled || !ref.current || pinned.length === 0) return;

        const m = L.map(ref.current, { scrollWheelZoom: true });
        map = m;
        L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
          attribution: "© OpenStreetMap",
          maxZoom: 19,
        }).addTo(m);

        const group: [number, number][] = [];
        for (const a of pinned) {
          const lat = a.location!.lat!;
          const lng = a.location!.lng!;
          group.push([lat, lng]);
          const net = monthlyFor(a).net;
          const marker = L.circleMarker([lat, lng], {
            radius: 11,
            weight: 3,
            color: a.status === "active" ? "#15803d" : "#94a3b8",
            fillColor: a.status === "active" ? "#22c55e" : "#cbd5e1",
            fillOpacity: 0.9,
          }).addTo(m);
          marker.bindTooltip(
            `<b>${a.name}</b><br>${HOLDING_LABEL[a.holding]} · ${entityById(a.ownerId).name}<br>` +
              (a.status === "active" ? `สุทธิ/เดือน ${signedMoney(net)}` : "หยุดไว้"),
            { direction: "top" }
          );
          marker.on("click", () => onOpen(a.id));
        }
        m.fitBounds(group as [number, number][], { padding: [48, 48], maxZoom: 13 });
      } catch {
        if (!cancelled) setFailed(true);
      }
    })();

    return () => {
      cancelled = true;
      map?.remove();
    };
  }, [pinned, onOpen]);

  return (
    <div className="flex flex-col gap-3">
      {pinned.length === 0 || failed ? (
        <div className="rounded-card border border-warn bg-warn-bg p-[14px_18px] text-base leading-7 text-warn-fg">
          {failed ? "โหลดแผนที่ไม่สำเร็จ — เครื่องนี้อาจต่อออกอินเทอร์เน็ตไม่ได้" : "ยังไม่มีทรัพย์ที่มีพิกัดให้ปักหมุด"}
        </div>
      ) : (
        <div
          ref={ref}
          className="h-[520px] w-full overflow-hidden rounded-card border border-line shadow-card"
          role="application"
          aria-label="แผนที่ทรัพย์"
        />
      )}

      {missing.length ? (
        <div className="rounded-card border border-line bg-surface p-[14px_18px] text-base leading-7">
          <b>ยังปักหมุดไม่ได้ {missing.length} รายการ</b> — ช่องพิกัดกรอกเป็นลิงก์ย่อหรือชื่อสถานที่
          ต้องแปลงเป็นพิกัดก่อน: {missing.map((a) => a.name).join(" · ")}
        </div>
      ) : null}
    </div>
  );
}
