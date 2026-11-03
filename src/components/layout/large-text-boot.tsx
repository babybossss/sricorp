"use client";

import * as React from "react";
import { useApp } from "@/lib/store";

/**
 * ติดโหมดตัวใหญ่ไว้ที่ `<html data-large-text>` — **ต้องอยู่ใน layout ราก**
 *
 * เคยอยู่ใน `Topbar` ซึ่งทำให้หน้ามือถือ (`/m`, `/m/new`) ไม่เคยได้โหมดนี้เลย
 * เพราะหน้าชุดนั้นไม่ได้ใช้ `PageShell`/`Topbar` — ผู้สูงอายุที่ใช้มือถือจึง
 * ไม่มีทางขยายตัวอักษรได้ ทั้งที่เป็นข้อกำหนดของระบบ
 *
 * อ่านค่าที่จำไว้ **ใน effect** ไม่ใช่ตอนตั้งค่าตั้งต้นของ store
 * (ตั้งต้นต้องเท่ากับฝั่ง server ไม่งั้น hydration ไม่ตรงกัน — ดูคอมเมนต์ใน lib/store)
 * ตัวนี้ไม่ render อะไร จึงไม่มีผลต่อ hydration ด้วยตัวเอง
 */
export function LargeTextBoot() {
  const largeText = useApp((s) => s.largeText);
  const hydrateLargeText = useApp((s) => s.hydrateLargeText);

  React.useEffect(() => {
    hydrateLargeText();
  }, [hydrateLargeText]);

  React.useEffect(() => {
    document.documentElement.dataset.largeText = String(largeText);
  }, [largeText]);

  return null;
}
