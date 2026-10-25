import type { TxTypeKey } from "@/lib/rules/tx-rules";
import type { PostedClearing } from "@/lib/ledger/types";

/**
 * รายการค้างรับ-ค้างจ่ายที่รอยืนยันว่าเงินเคลื่อนจริง
 *
 * ขั้นยืนยันเป็นขั้นที่ทำให้งบกระแสเงินสดวิ่ง จึงต้องรู้บัญชีเสมอ — รายการที่คีย์ตอนยังไม่มีขาเงินสด
 * ไม่มีบัญชีมาด้วย (`bankAccountId` ว่าง) ต้องให้เลือกตอนยืนยัน
 * `ownerId` ใช้กรองตัวเลือก: เงินของคนหนึ่งจะไปโผล่ในบัญชีของอีกคนไม่ได้
 *
 * **ข้อมูลที่กติกาใช้ตัดสินต้องเดินทางมากับตัวรายการ** (เหตุผลเดียวกับ `Approval.notYetPaid` /
 * `bankAccountId` / `attachments`) — ไม่ใช่ให้ตัวยืนยันเดาจากชื่อรายการหรือจากข้อความที่แสดง:
 * - `typeKey` / `subCode`  ตารางกฎใช้หาบัญชีพักและทางล้าง · เดาผิดคือล้างผิดบัญชี
 * - `accruedAmount`        ยอดที่ตั้งค้างไว้ตอนต้นทาง (บวกเสมอ) ทิศทางรับ/จ่ายอ่านจากตารางกฎ ไม่เก็บเครื่องหมายซ้ำ
 * - `postedClearings`      ประวัติการยืนยันที่ post แล้ว · engine ใช้กันยืนยันซ้ำและล้างเกิน
 *                          ห้ามให้หน้าจอสรุปเป็น "ยอดที่เคยล้าง" ส่งไปเอง ถ้าละไว้ engine ต้องปฏิเสธ ไม่ใช่เดาว่า []
 * - `attachments`          ฝั่ง `corporate_strict` กติกาของ `buildClearing()` ใช้ตัดสินว่ายืนยันได้ไหม
 *                          ไม่มีฟิลด์นี้ทุกรายการของนิติบุคคลจะถูกยืนยันโดยไม่มีหลักฐาน = override กติกาที่ห้าม override
 *                          ฝั่งบุคคลเว้นว่างได้ — ใครบังคับหรือไม่ engine เป็นคนตัดสิน
 * - `assetId` / `contactId` บัญชีย่อยรายทรัพย์และกติกาคู่ค้าของนิติบุคคล
 */
export type PendingCashRow = {
  id: string;
  name: string;
  sub: string;
  ownerId: string;
  due: string;
  typeKey: TxTypeKey;
  subCode: string;
  accruedAmount: number;
  postedClearings: PostedClearing[];
  assetId?: string;
  contactId?: string;
  /**
   * รหัสบัญชีที่เงินเข้า-ออก — ไม่ใช่ชื่อ · ว่างได้เฉพาะรายการที่ยังไม่เคยระบุบัญชี (ต้องเลือกตอนยืนยัน)
   * ถ้าไม่ว่าง ใช้ค่านี้เสมอ ไม่ให้ช่องเลือกบัญชีทับ
   */
  bankAccountId?: string;
  attachments?: string[];
  /** ค่าเริ่มต้นของช่องกรอก — ผู้ใช้แก้ได้ */
  actual: string;
  date: string;
  checked?: boolean;
};
