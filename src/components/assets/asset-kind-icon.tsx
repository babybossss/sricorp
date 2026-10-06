import * as React from "react";
import type { AssetKind } from "@/lib/mock/assets";
import { cn } from "@/lib/utils";

/**
 * ไอคอนประจำชนิดทรัพย์ 7 แบบ
 *
 * เป็นเวกเตอร์ในโค้ด ไม่ใช่ไฟล์รูป — คมทุกขนาด เปลี่ยนสีตามธีมได้
 * และไม่ต้องรอโหลด ซึ่งสำคัญเพราะมันอยู่หน้าชื่อทุกแถวในตาราง
 *
 * ใช้เป็น**ตัวสำรองเมื่อยังไม่มีรูปถ่าย** — ทรัพย์ที่อัพรูปแล้วจะแสดงรูปจริงแทน
 * ทรัพย์ส่วนใหญ่จะไม่มีรูปตั้งแต่วันแรก ช่องว่างเปล่าทั้งคอลัมน์อ่านยากกว่าไอคอน
 */

const PATHS: Record<AssetKind | "other", string[]> = {
  // ตึกสูง ช่องหน้าต่างเป็นตาราง
  condo: ["M7 21V5a1 1 0 0 1 1-1h8a1 1 0 0 1 1 1v16", "M3 21h18", "M10 8h1M14 8h1M10 12h1M14 12h1M10 16h1M14 16h1"],
  // หลังคาจั่ว + ประตู
  house: ["M4 11 12 4l8 7", "M6 10v11h12V10", "M10 21v-6h4v6"],
  // สองคูหาติดกัน มีผนังร่วม
  townhome: ["M3 10 8 5l5 5", "M11 10 16 5l5 5", "M5 9.5V21h14V9.5", "M12 9v12", "M7.5 21v-5h3v5", "M13.5 21v-5h3v5"],
  // แปลงที่ดินมองเฉียง + หมุดปักมุม
  land: ["M3 16 12 11l9 5-9 5-9-5z", "M8 13.3V6", "M8 6h5l-1.6 1.6L13 9.2H8"],
  // ตึกแถว กันสาดหน้าร้าน
  commercial: ["M4 9h16v12H4z", "M3 9 5 4h14l2 5", "M4 13h7v8H4z", "M14 13h6v4h-6z"],
  // โกดัง หลังคาโค้ง ประตูบานใหญ่
  warehouse: ["M3 20V11l9-5 9 5v9", "M3 20h18", "M8 20v-6h8v6", "M8 17h8"],
  // ทรัพย์อื่น — กองซ้อนหลายชั้น
  other: ["M12 3 3 7.5 12 12l9-4.5L12 3z", "M3 16.5 12 21l9-4.5", "M3 12 12 16.5 21 12"],
};

export function AssetKindIcon({
  kind,
  size = 40,
  muted,
  className,
}: {
  kind: AssetKind | "other";
  size?: number;
  /** ทรัพย์ที่หยุดไว้ — จางลงให้ตรงกับที่รูปถ่ายทำ */
  muted?: boolean;
  className?: string;
}) {
  return (
    <span
      className={cn(
        "inline-flex flex-none items-center justify-center rounded-card border",
        muted ? "border-line bg-canvas text-ink-400" : "border-brand-100 bg-brand-50 text-brand",
        className
      )}
      style={{ width: size, height: size }}
      aria-hidden
    >
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
        style={{ width: Math.round(size * 0.6), height: Math.round(size * 0.6) }}
      >
        {PATHS[kind].map((d) => (
          <path key={d} d={d} />
        ))}
      </svg>
    </span>
  );
}

/** ใช้ในหน้าตัวอย่าง/ตัวเลือก — ไม่ใช่ลำดับที่ใช้แสดงผลจริง */
export const ICON_KINDS: (AssetKind | "other")[] = [
  "condo", "house", "townhome", "land", "commercial", "warehouse", "other",
];
