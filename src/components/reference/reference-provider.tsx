"use client";

import * as React from "react";
import type { RefContact, Reference, ReferenceState } from "@/lib/db/reference-types";
import { makeResolver } from "@/lib/db/resolver";
import type { LedgerResolver } from "@/lib/ledger/types";

/**
 * ส่งข้อมูลอ้างอิงจริง (ผู้ถือ · บัญชี · ทรัพย์ · ผู้ติดต่อ) จาก server ลงไปให้ฟอร์มและหน้าจอใช้
 *
 * - โหลดไม่สำเร็จ = `ok: false` พร้อมเหตุผล → ฟอร์มบอกผู้ใช้ตรงๆ **ไม่ตกกลับไปใช้ข้อมูลจำลอง**
 * - ผู้ติดต่อที่สร้างใหม่จากฟอร์มถูกเติมเข้ารายการทันที (ไม่ต้องรอโหลดหน้าใหม่)
 * - สแนปช็อตนี้ใช้แสดงตัวเลือกและพรีวิวเท่านั้น · ตอนบันทึกจริง server โหลดใหม่เอง
 */

type Ctx = {
  state: ReferenceState;
  /** เติมผู้ติดต่อที่เพิ่งสร้าง */
  addContact: (c: RefContact) => void;
};

const EMPTY_STATE: ReferenceState = { ok: false, error: "ยังไม่ได้โหลดข้อมูลอ้างอิงจากฐานข้อมูล" };
const RefCtx = React.createContext<Ctx>({ state: EMPTY_STATE, addContact: () => undefined });

export function ReferenceProvider({ state, children }: { state: ReferenceState; children: React.ReactNode }) {
  const [extraContacts, setExtra] = React.useState<RefContact[]>([]);

  const value = React.useMemo<Ctx>(() => {
    const addContact = (c: RefContact) => setExtra((prev) => (prev.some((p) => p.id === c.id) ? prev : [...prev, c]));
    if (!state.ok) return { state, addContact };
    const known = new Set(state.ref.contacts.map((c) => c.id));
    const contacts = [...state.ref.contacts, ...extraContacts.filter((c) => !known.has(c.id))];
    return { state: { ok: true, ref: { ...state.ref, contacts } }, addContact };
  }, [state, extraContacts]);

  return <RefCtx.Provider value={value}>{children}</RefCtx.Provider>;
}

/** สถานะข้อมูลอ้างอิง — ตรวจ `ok` ก่อนใช้เสมอ */
export const useReferenceState = (): ReferenceState => React.useContext(RefCtx).state;

export const useAddContact = () => React.useContext(RefCtx).addContact;

const EMPTY_REF: Reference = { owners: [], banks: [], assets: [], contacts: [], coaCodeById: {} };

/** ข้อมูลอ้างอิง (ว่างเมื่อโหลดไม่สำเร็จ — ใช้คู่กับ `useReferenceState()` เพื่อบอกผู้ใช้ว่าทำไมว่าง) */
export function useReference(): Reference {
  const s = useReferenceState();
  return s.ok ? s.ref : EMPTY_REF;
}

/** resolver สำหรับพรีวิว/กั้นปุ่มในฟอร์ม — สร้างจากสแนปช็อตเดียวกับที่หน้าจอแสดง */
export function useResolver(): LedgerResolver {
  const ref = useReference();
  return React.useMemo(() => makeResolver(ref), [ref]);
}
