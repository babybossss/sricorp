"use client";

import { create } from "zustand";
import { BANKS } from "@/lib/mock/banks";
import { SEED_CONTACTS, type Contact } from "@/lib/mock/contacts";

/**
 * สถานะทั้งแอป — รอบนี้เป็น mock ในหน่วยความจำ ยังไม่ต่อ Supabase
 * เมื่อต่อฐานข้อมูลจริง ให้แทนที่ตัว action ด้วย mutation แล้ว shape เดิมใช้ต่อได้
 */
type AppState = {
  /** ผู้ถือกรรมสิทธิ์ที่กำลังดู (ค่าเริ่มต้นคือมุมมองรวมกองกลาง) */
  entityId: string;
  setEntityId: (id: string) => void;

  /** เดือนที่กำลังดู 0-11 */
  month: number;
  setMonth: (m: number) => void;
  stepMonth: (delta: number) => void;

  /** โหมดตัวใหญ่ +2px สำหรับผู้สูงอายุ */
  largeText: boolean;
  toggleLargeText: () => void;

  /** ผู้ติดต่อ — สร้างเพิ่มได้จากในฟอร์ม (Backlog ข้อ 3) */
  contacts: Contact[];
  addContact: (c: Omit<Contact, "id">) => Contact;

  /** ลำดับและสถานะเปิด-ปิดบัญชีธนาคาร (ลำดับนี้คือลำดับในทุกฟอร์ม) */
  bankOrder: string[];
  bankOff: Record<string, boolean>;
  moveBank: (id: string, dir: -1 | 1) => void;
  toggleBank: (id: string) => void;

  /** toast แจ้งผล */
  toast: string | null;
  showToast: (msg: string) => void;
  clearToast: () => void;
};

let contactSeq = SEED_CONTACTS.length;

export const useApp = create<AppState>((set, get) => ({
  entityId: "family",
  setEntityId: (entityId) => set({ entityId }),

  month: 8, // ก.ย.
  setMonth: (month) => set({ month }),
  stepMonth: (delta) => set((s) => ({ month: (s.month + delta + 12) % 12 })),

  largeText: false,
  toggleLargeText: () => set((s) => ({ largeText: !s.largeText })),

  contacts: SEED_CONTACTS,
  addContact: (input) => {
    const contact: Contact = { ...input, id: `c${++contactSeq}` };
    set((s) => ({ contacts: [...s.contacts, contact] }));
    return contact;
  },

  bankOrder: BANKS.map((b) => b.id),
  bankOff: Object.fromEntries(BANKS.map((b) => [b.id, b.off])),
  moveBank: (id, dir) => {
    const order = [...get().bankOrder];
    const i = order.indexOf(id);
    const j = i + dir;
    if (i < 0 || j < 0 || j >= order.length) return;
    [order[i], order[j]] = [order[j], order[i]];
    set({ bankOrder: order });
  },
  toggleBank: (id) => set((s) => ({ bankOff: { ...s.bankOff, [id]: !s.bankOff[id] } })),

  toast: null,
  showToast: (toast) => set({ toast }),
  clearToast: () => set({ toast: null }),
}));

/** บัญชีธนาคารเรียงตามลำดับที่ตั้งไว้ใน Config */
export function useOrderedBanks(onlyActive = false) {
  const order = useApp((s) => s.bankOrder);
  const off = useApp((s) => s.bankOff);
  const list = order.map((id) => BANKS.find((b) => b.id === id)!).filter(Boolean);
  return onlyActive ? list.filter((b) => !off[b.id]) : list;
}
