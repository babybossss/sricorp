/**
 * ยอดที่ต้องอ่านจากสมุดก่อนย้ายวัตถุประสงค์ทรัพย์ (ธง `wholeBalanceMove` ในตารางกฎ) — ผู้ใช้ไม่ได้กรอก (D-115)
 *
 * หมวดย้ายวัตถุประสงค์อสังหาฯ ย้าย **ทั้งก้อน** เท่านั้น: ยอดคือยอดคงเหลือของทรัพย์ชิ้นนั้นในบัญชีต้นทาง
 * (`sub.cr`) ตามสมุดที่ post แล้ว · ผู้ใช้เลือกแค่ทรัพย์ ไม่มีช่องพิมพ์ยอด
 * (ยอดที่พิมพ์เกินที่ถืออยู่ทำให้บัญชีต้นทางติดลบโดยต้นทุนรวมไม่เปลี่ยน ซึ่งไม่มีด่านต้นทุนตัวไหนฟ้อง)
 *
 * ไฟล์นี้เป็นฟังก์ชันล้วน ใช้ได้ทั้งฟอร์มและ server · ไม่คิดคู่บัญชี (`buildPosting()` เป็นคนคิดและเทียบยอดซ้ำ)
 * ข้อมูลไม่ครบ/ยอดไม่เป็นบวก = ปฏิเสธเป็นภาษาคน ไม่เดา ไม่ปล่อยให้ engine ด่าด้วยศัพท์เทคนิค
 */

import { coaLabel } from "@/lib/rules/coa";
import type { SubCategory } from "@/lib/rules/tx-rules";
import type { PostingInput } from "@/lib/ledger/types";

export type BalanceMove = NonNullable<PostingInput["balanceMove"]>;

export type BalanceMoveBuild = { ok: true; balanceMove: BalanceMove } | { ok: false; message: string };

/** หมวดนี้ย้ายยอดทั้งก้อนไหม — ถามตารางกฎ ไม่เช็ครหัสหมวด */
export const movesWholeBalance = (sub: Pick<SubCategory, "requires"> | undefined): boolean =>
  !!sub?.requires?.includes("wholeBalanceMove");

const thb = (n: number) => n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/**
 * ยอดที่อ่านจากสมุด → `balanceMove` ของ engine
 * `balance` เป็น `null` = อ่านไม่ได้/ไม่ใช่ตัวเลข → ปฏิเสธ (ห้ามเดาเป็น 0 เพราะ 0 แปลว่า "ไม่มีต้นทุนในบัญชีนั้น")
 */
export function balanceMoveFor(
  sub: Pick<SubCategory, "label" | "cr" | "requires">,
  balance: number | null
): BalanceMoveBuild {
  if (!movesWholeBalance(sub)) {
    return { ok: false, message: `หมวด "${sub.label}" ไม่ใช่การย้ายยอดทั้งก้อน` };
  }
  if (balance === null || !Number.isFinite(balance)) {
    return { ok: false, message: "อ่านยอดคงเหลือของทรัพย์ชิ้นนี้จากสมุดไม่ได้" };
  }
  const rounded = Math.round(balance * 100) / 100;
  const account = coaLabel(sub.cr);
  if (rounded === 0) {
    return {
      ok: false,
      message:
        `ทรัพย์ชิ้นนี้ไม่มีต้นทุนค้างอยู่ในบัญชี ${account} จึงไม่มีอะไรให้ย้าย — ` +
        "ตรวจว่าเลือกทรัพย์ถูกชิ้น หรือทรัพย์ชิ้นนี้อยู่ในบัญชีอีกวัตถุประสงค์แล้ว",
    };
  }
  if (rounded < 0) {
    return {
      ok: false,
      message:
        `ยอดของทรัพย์ชิ้นนี้ในบัญชี ${account} ตามสมุดติดลบ (${thb(Math.abs(rounded))} บาท) — ผิดปกติ ย้ายไม่ได้ ` +
        "ให้ตรวจรายการของทรัพย์ชิ้นนี้ในสมุดบัญชีก่อน",
    };
  }
  return { ok: true, balanceMove: { sourceCoaCode: sub.cr, sourceBalance: rounded } };
}
