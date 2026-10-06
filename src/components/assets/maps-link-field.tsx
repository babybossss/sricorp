"use client";

import * as React from "react";
import { parseGoogleMapsUrl, isShortLink, PARSE_MESSAGE, SOURCE_LABEL, looksOutsideThailand } from "@/lib/maps/google-url";
import { Input } from "@/components/ui/input";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";

type Coord = { lat: number; lng: number; note: string };

/**
 * ช่องวางลิงก์ Google Maps — ผู้ใช้วางลิงก์ ระบบดึงพิกัดให้
 *
 * ลิงก์ย่อ (maps.app.goo.gl) ไม่มีพิกัดอยู่ข้างใน ต้องให้เซิร์ฟเวอร์ตามรีไดเรกต์ก่อน
 * จึงมีปุ่มแยกไว้ ไม่ใช่ยิงอัตโนมัติทุกตัวอักษรที่พิมพ์
 *
 * **ไม่มีช่องให้พิมพ์ lat/lng เอง** โดยตั้งใจ — พิมพ์สลับที่กันเมื่อไร ทรัพย์ย้ายจังหวัดทันที
 * โดยที่หน้าจอยังดูปกติทุกอย่าง
 */
export function MapsLinkField({
  value,
  lat,
  lng,
  onChange,
}: {
  value: string;
  lat?: number;
  lng?: number;
  onChange?: (v: { mapsUrl: string; lat?: number; lng?: number }) => void;
}) {
  const [url, setUrl] = React.useState(value);
  const [resolved, setResolved] = React.useState<Coord | null>(
    lat != null && lng != null ? { lat, lng, note: "บันทึกไว้แล้ว" } : null
  );
  const [busy, setBusy] = React.useState(false);
  const [problem, setProblem] = React.useState<string | null>(null);

  const apply = React.useCallback(
    (next: string) => {
      setUrl(next);
      setProblem(null);
      const r = parseGoogleMapsUrl(next);
      if (r.ok) {
        setResolved({ lat: r.lat, lng: r.lng, note: SOURCE_LABEL[r.source] });
        onChange?.({ mapsUrl: next, lat: r.lat, lng: r.lng });
      } else {
        setResolved(null);
        setProblem(next.trim() ? PARSE_MESSAGE[r.reason] : null);
        onChange?.({ mapsUrl: next });
      }
    },
    [onChange]
  );

  async function follow() {
    setBusy(true);
    setProblem(null);
    try {
      const res = await fetch("/api/resolve-maps-link", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ url }),
      });
      const data = await res.json();
      if (data.ok) {
        setResolved({ lat: data.lat, lng: data.lng, note: `ตามลิงก์ย่อแล้ว · ${SOURCE_LABEL[data.source as keyof typeof SOURCE_LABEL]}` });
        onChange?.({ mapsUrl: url, lat: data.lat, lng: data.lng });
      } else {
        setProblem("ตามลิงก์ย่อไม่สำเร็จ — เปิดลิงก์ใน Google Maps แล้วก๊อปลิงก์เต็มจากแถบที่อยู่มาวางแทน");
      }
    } catch {
      setProblem("ต่อเน็ตไม่ได้ ลองใหม่อีกครั้ง");
    } finally {
      setBusy(false);
    }
  }

  const outside = resolved && looksOutsideThailand(resolved.lat, resolved.lng);

  return (
    <Field label="ลิงก์ Google Maps" hint="เปิดทรัพย์ใน Google Maps แล้วก๊อปลิงก์มาวาง ระบบจะดึงพิกัดให้เอง">
      <div className="flex flex-col gap-2">
        <Input value={url} onChange={(e) => apply(e.target.value)} placeholder="https://www.google.com/maps/place/..." />

        {isShortLink(url) && !resolved ? (
          <Button variant="secondary" size="sm" onClick={follow} disabled={busy}>
            {busy ? "กำลังตามลิงก์..." : "ดึงพิกัดจากลิงก์ย่อ"}
          </Button>
        ) : null}

        {resolved ? (
          <div className="flex flex-col gap-1 rounded border border-pos bg-pos-bg p-[10px_12px] text-sm leading-6 text-pos-fg">
            <span>
              ✓ พิกัด <b className="tabular-nums">{resolved.lat.toFixed(6)}, {resolved.lng.toFixed(6)}</b> · {resolved.note}
            </span>
            <a href={`https://www.google.com/maps/search/?api=1&query=${resolved.lat},${resolved.lng}`} target="_blank" rel="noreferrer noopener">
              เปิดดูว่าตรงที่จริงไหม
            </a>
          </div>
        ) : null}

        {outside ? (
          <div className="rounded border border-warn bg-warn-bg p-[10px_12px] text-sm leading-6 text-warn-fg">
            ⚠ พิกัดนี้อยู่นอกประเทศไทย — ถ้าไม่ได้ตั้งใจ ให้ก๊อปลิงก์ใหม่
          </div>
        ) : null}

        {problem ? (
          <div className="rounded border border-warn bg-warn-bg p-[10px_12px] text-sm leading-6 text-warn-fg">{problem}</div>
        ) : null}
      </div>
    </Field>
  );
}
