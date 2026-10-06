"use client";

import * as React from "react";
import type { AssetRef } from "@/lib/mock/assets";
import { HOLDING_LABEL, monthlyFor } from "@/lib/mock/assets";
import { signedMoney } from "@/lib/format";
import { entityById } from "@/lib/mock/entities";

const KEY = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;

/** โหลดสคริปต์ Google Maps ครั้งเดียวต่อหน้า — สลับแบบไปมาแล้วไม่โหลดซ้ำ */
let loader: Promise<void> | null = null;
function loadGoogleMaps(key: string): Promise<void> {
  if (loader) return loader;
  loader = new Promise<void>((resolve, reject) => {
    if (typeof window !== "undefined" && window.google?.maps) return resolve();
    const s = document.createElement("script");
    s.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(key)}&language=th&region=TH`;
    s.async = true;
    s.onload = () => resolve();
    s.onerror = () => reject(new Error("load failed"));
    document.head.appendChild(s);
  });
  return loader;
}

/**
 * แผนที่ดาวเทียมของ Google พร้อมหมุดทรัพย์
 *
 * ใช้ `hybrid` ไม่ใช่ `satellite` เปล่าๆ — ภาพดาวเทียมล้วนไม่มีชื่อถนนและชื่อหมู่บ้าน
 * ซึ่งเป็นสิ่งที่คนใช้ยืนยันว่าหมุดอยู่ถูกที่จริงไหม
 *
 * **ทรัพย์ที่ไม่มีพิกัดไม่หายเงียบๆ** — ขึ้นรายชื่อใต้แผนที่พร้อมบอกว่าทำไม
 */
export function AssetMap({ rows, onOpen }: { rows: AssetRef[]; onOpen: (id: string) => void }) {
  const ref = React.useRef<HTMLDivElement>(null);
  const [error, setError] = React.useState<string | null>(null);

  const pinned = React.useMemo(
    () => rows.filter((a) => a.location?.lat != null && a.location?.lng != null),
    [rows]
  );
  const missing = rows.filter((a) => a.location?.lat == null || a.location?.lng == null);

  React.useEffect(() => {
    if (!KEY || pinned.length === 0) return;
    let dead = false;

    loadGoogleMaps(KEY)
      .then(() => {
        if (dead || !ref.current) return;
        const g = window.google.maps;
        const map = new g.Map(ref.current, { mapTypeId: "hybrid", mapTypeControl: true, streetViewControl: false });
        const bounds = new g.LatLngBounds();

        for (const a of pinned) {
          const pos = { lat: a.location!.lat!, lng: a.location!.lng! };
          bounds.extend(pos);
          const live = a.status === "active";
          const marker = new g.Marker({
            map,
            position: pos,
            title: a.name,
            icon: {
              path: g.SymbolPath.CIRCLE,
              scale: 10,
              fillColor: live ? "#22c55e" : "#cbd5e1",
              fillOpacity: 1,
              strokeColor: live ? "#15803d" : "#94a3b8",
              strokeWeight: 3,
            },
          });
          const info = new g.InfoWindow({
            content:
              `<div style="font:16px/1.5 system-ui"><b>${a.name}</b><br>` +
              `${HOLDING_LABEL[a.holding]} · ${entityById(a.ownerId).name}<br>` +
              (live ? `สุทธิ/เดือน ${signedMoney(monthlyFor(a).net)}` : "หยุดไว้") +
              `</div>`,
          });
          marker.addListener("mouseover", () => info.open({ map, anchor: marker }));
          marker.addListener("mouseout", () => info.close());
          marker.addListener("click", () => onOpen(a.id));
        }

        map.fitBounds(bounds, 64);
        if (pinned.length === 1) map.setZoom(17);
      })
      .catch(() => !dead && setError("โหลดแผนที่ไม่สำเร็จ — ตรวจว่า API key ใช้ได้และเปิด Maps JavaScript API แล้ว"));

    return () => {
      dead = true;
    };
  }, [pinned, onOpen]);

  return (
    <div className="flex flex-col gap-3">
      {!KEY ? (
        <div className="flex flex-col gap-2 rounded-card border border-warn bg-warn-bg p-[16px_20px] text-base leading-7 text-warn-fg">
          <b>ยังไม่ได้ใส่กุญแจ Google Maps</b>
          <span>
            แผนที่ดาวเทียมของ Google ต้องมี API key ของตัวเอง — สร้างที่ Google Cloud Console
            เปิด <b>Maps JavaScript API</b> แล้วใส่ค่าเป็น <code>NEXT_PUBLIC_GOOGLE_MAPS_API_KEY</code> ใน Vercel
          </span>
          <span>
            ตอนสร้างกุญแจ ให้<b>จำกัดโดเมนที่เรียกได้</b>เป็นเว็บของเราเท่านั้น
            ไม่งั้นคนอื่นเอากุญแจไปใช้แล้วบิลมาที่เรา
          </span>
        </div>
      ) : error ? (
        <div className="rounded-card border border-warn bg-warn-bg p-[14px_18px] text-base leading-7 text-warn-fg">{error}</div>
      ) : pinned.length === 0 ? (
        <div className="rounded-card border border-line bg-surface p-[14px_18px] text-base leading-7">
          ยังไม่มีทรัพย์ที่มีพิกัดให้ปักหมุด
        </div>
      ) : (
        <div ref={ref} className="h-[560px] w-full overflow-hidden rounded-card border border-line shadow-card" role="application" aria-label="แผนที่ทรัพย์" />
      )}

      {missing.length ? (
        <div className="rounded-card border border-line bg-surface p-[14px_18px] text-base leading-7">
          <b>ยังปักหมุดไม่ได้ {missing.length} รายการ</b> — เปิดทรัพย์แล้ววางลิงก์ Google Maps
          ระบบจะดึงพิกัดให้เอง: {missing.map((a) => a.name).join(" · ")}
        </div>
      ) : null}
    </div>
  );
}
