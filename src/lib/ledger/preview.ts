/**
 * พรีวิวบรรทัดบัญชีสำหรับแสดงในฟอร์ม ก่อนผู้ใช้กดยืนยัน
 *
 * เรียก engine ตัวเดียวกับที่จะใช้ลงบัญชีจริง — ไม่คำนวณซ้ำเอง
 * เพราะถ้าคำนวณคนละที่ สิ่งที่ผู้ใช้เห็นกับสิ่งที่ระบบบันทึกจะไม่ตรงกันเมื่อไรก็ได้
 *
 * ต่างกันสองอย่าง:
 * 1. ยอมให้ข้อมูลยังไม่ครบ แล้วคืนข้อความอธิบายแทนที่จะโยน error
 * 2. เรียก `buildPostingDraft()` จึงยังไม่บังคับกติกาเอกสารของนิติบุคคล —
 *    ไฟล์แนบไม่เปลี่ยนคู่บัญชี ผู้ใช้จึงควรเห็นบรรทัดก่อนไปหาไฟล์
 *    ตอนกดบันทึกจริงต้องผ่าน `buildPosting()` ซึ่งบังคับครบ
 */

import { buildPostingDraft, allLines } from "./posting";
import { PostingError, type PostingInput, type PostingLine } from "./types";
import { coa } from "@/lib/rules/coa";
import { entityById } from "@/lib/mock/entities";

export type PreviewLine = PostingLine & { label: string };

/** หนึ่งรายการพร้อมชื่อผู้ถือ — รายการข้ามผู้ถือจะได้สองก้อน */
export type PreviewTransaction = {
  ownerId: string;
  ownerName: string;
  counterOwnerName?: string;
  lines: PreviewLine[];
};

export type PreviewResult =
  | { ok: true; transactions: PreviewTransaction[]; lines: PreviewLine[]; summary: string[] }
  | { ok: false; reason: string };

const describe = (l: PostingLine): PreviewLine => ({ ...l, label: coa(l.coaCode).nameTh });

/** ลองสร้างบรรทัดบัญชี — ถ้าข้อมูลยังไม่ครบให้บอกว่าขาดอะไร ไม่ throw */
export function previewPosting(input: PostingInput): PreviewResult {
  try {
    const result = buildPostingDraft(input);
    const transactions = result.transactions.map((t) => ({
      ownerId: t.ownerId,
      ownerName: entityById(t.ownerId).name,
      counterOwnerName: t.counterOwnerId ? entityById(t.counterOwnerId).name : undefined,
      lines: t.lines.map(describe),
    }));

    return {
      ok: true,
      transactions,
      lines: allLines(result).map(describe),
      summary: result.summary,
    };
  } catch (e) {
    if (e instanceof PostingError) return { ok: false, reason: e.message };
    // ข้อผิดพลาดที่ไม่ได้คาดไว้ ปล่อยขึ้นไปให้เห็น ไม่กลืน
    throw e;
  }
}
