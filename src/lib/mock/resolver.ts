/**
 * LedgerResolver ที่สร้างจากข้อมูลจำลอง — **ชั้นนอกของ engine**
 *
 * ไฟล์นี้อยู่ใน `lib/mock` โดยตั้งใจ ไม่ใช่ใน `lib/ledger`
 * เพราะ engine ต้องไม่รู้จักข้อมูลจำลองเลย (CLAUDE.md งานถัดไปข้อ 2)
 *
 * ตอนต่อ Supabase จริง: เขียน resolver อีกตัวที่อ่านจาก `sri_os.owners` /
 * `sri_os.bank_accounts` แล้วสลับ **ที่ชั้นนี้** — ไม่ต้องแตะ `lib/ledger` เลย
 *
 * ทุกฟังก์ชันคืน `null` เมื่อหาไม่เจอ ไม่ throw และไม่เดา —
 * engine เป็นคนแปลงเป็น `PostingError` ที่ผู้ใช้อ่านได้ (ที่เดียว ข้อความเดียว)
 */

import type { BankInfo, LedgerResolver, OwnerInfo } from "@/lib/ledger/types";
import { ENTITIES } from "./entities";
import { BANKS } from "./banks";

const toOwnerInfo = (e: (typeof ENTITIES)[number]): OwnerInfo => ({
  id: e.id,
  name: e.name,
  policy: e.policy,
  selectableAsHolder: e.selectableAsHolder,
});

const toBankInfo = (b: (typeof BANKS)[number]): BankInfo => ({
  id: b.id,
  name: b.name,
  ownerId: b.ownerId,
});

/**
 * resolver ตัวที่หน้าจอใช้อยู่ตอนนี้
 *
 * บัญชีที่ปิดใช้งาน (`off`) **ยังต้องหาเจอ** เพราะรายการย้อนหลังที่อ้างถึงมัน
 * ต้องแสดงและ reverse ได้ — การซ่อนจากตัวเลือกเป็นเรื่องของฟอร์ม ไม่ใช่ของ engine
 */
export const MOCK_RESOLVER: LedgerResolver = {
  owner(id) {
    const e = ENTITIES.find((x) => x.id === id);
    return e ? toOwnerInfo(e) : null;
  },
  bankAccount(id) {
    const b = BANKS.find((x) => x.id === id);
    return b ? toBankInfo(b) : null;
  },
};
