/**
 * ขั้นยืนยันเงินเข้า-ออก — หน้าจอต้องถาม engine ไม่ใช่ตัดสินเอง
 *
 * ชุดนี้ทดสอบด้วยข้อมูลจำลองของแอปจริง (ต่างจากเทสต์ของ engine ที่ห้ามแตะ `lib/mock`)
 * เพราะสิ่งที่ทดสอบคือ "ข้อมูลที่หน้าจอส่งให้ engine ครบไหม" ไม่ใช่กฎบัญชี
 *
 * ทุกฟิลด์ใหม่มีเคส **"ไม่ส่ง"** (บทเรียนข้อ 3) — เทสต์ที่ส่งข้อมูลครบเสมอจะไม่มีวันแตะเส้นทางที่ข้อมูลขาด
 */

import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { CASH_GROUPS, UNASSIGNED_CASH_ROWS, mockEvidenceRef, type PendingCashRow } from "@/lib/mock/ledger";
import { MOCK_RESOLVER } from "@/lib/mock/resolver";
import { TX_TYPES, accrualCheck } from "@/lib/rules/tx-rules";
import {
  checkRow,
  clearingInputOf,
  confirmRows,
  directionOf,
  initialDraft,
  initialPosted,
  type PostedMap,
  type RowDraft,
} from "../confirm-flow";

const ALL = [...UNASSIGNED_CASH_ROWS, ...CASH_GROUPS.flatMap((g) => g.rows)];
const find = (id: string): PendingCashRow => ALL.find((r) => r.id === id)!;

const cu1 = find("cu1"); // corp · ค้างจ่าย 8,600 · ยังไม่มีบัญชี · มีหลักฐานเดิม
const cu2 = find("cu2"); // ธนากร · ค้างรับ 12,000 · ยังไม่มีบัญชี
const cc1 = find("cc1"); // corp · ผูก b1 · มีหลักฐานและคู่ค้า
const cc3 = find("cc3"); // corp · ผูก b1 · ไม่มีหลักฐาน · ค้างรับ 45,000
const cc4 = find("cc4"); // ธนากร · ผูก b4

const fresh = (): PostedMap => initialPosted(ALL);
const draft = (r: PendingCashRow, p: Partial<RowDraft> = {}): RowDraft => ({ ...initialDraft(r), ...p });
const check = (r: PendingCashRow, d: RowDraft = draft(r), posted: PostedMap = fresh()) => checkRow(r, d, posted, MOCK_RESOLVER);
const confirm = (rows: PendingCashRow[], drafts: Record<string, RowDraft> = {}, posted: PostedMap = fresh()) =>
  confirmRows(rows, drafts, posted, MOCK_RESOLVER);

/** ตัดฟิลด์ออกจริงๆ — เลียนแบบข้อมูลที่ขาดมาจาก DB ตอน runtime */
const without = (r: PendingCashRow, key: keyof PendingCashRow): PendingCashRow => {
  const copy = { ...r };
  delete copy[key];
  return copy;
};

describe("ข้อมูลจำลอง — แถวทุกแถวผูกรหัสบัญชี ไม่ใช่ชื่อธนาคาร", () => {
  it("กลุ่มไม่เก็บชื่อธนาคารเป็นข้อความ เก็บรหัสบัญชีที่ resolver รู้จัก", () => {
    for (const g of CASH_GROUPS) {
      expect("bank" in g).toBe(false);
      expect(MOCK_RESOLVER.bankAccount(g.bankAccountId), g.bankAccountId).not.toBeNull();
    }
  });
  it("ทุกแถวในกลุ่มถือรหัสบัญชีเดียวกับกลุ่ม (แถวคือสิ่งที่ส่งเข้า engine)", () => {
    for (const g of CASH_GROUPS) for (const r of g.rows) expect(r.bankAccountId, r.id).toBe(g.bankAccountId);
  });
  it("ข้อมูลจำลองไม่มีข้อความยอดค้างที่พิมพ์ไว้เอง", () => {
    for (const r of ALL) expect("partial" in r || "expect" in r, r.id).toBe(false);
  });
  it("ทุกแถวส่งฟิลด์ที่กติกาใช้ตัดสินมาครบ", () => {
    for (const r of ALL) {
      expect(r.typeKey, r.id).toBeTruthy();
      expect(r.subCode, r.id).toBeTruthy();
      expect(r.accruedAmount, r.id).toBeGreaterThan(0);
      expect(Array.isArray(r.postedClearings), r.id).toBe(true);
    }
  });
});

describe("ปุ่มยืนยันกั้นด้วย buildClearing() ตัวจริง ไม่ใช่ draft", () => {
  it("นิติบุคคลไม่มีหลักฐาน → พรีวิวได้ แต่ยืนยันไม่ได้", () => {
    const c = check(cc3);
    expect(c.preview.ok).toBe(true); // draft ไม่บังคับหลักฐาน
    expect(c.canConfirm).toBe(false); // ตัวจริงบังคับ
    expect(c.blockedReason).toContain("หลักฐาน");
    expect(confirm([cc3]).ok).toBe(false);
  });
  it("แนบสลิปแล้ว → ยืนยันได้", () => {
    const d = draft(cc3, { slips: [mockEvidenceRef(11)] });
    expect(check(cc3, d).canConfirm).toBe(true);
    expect(confirm([cc3], { cc3: d }).ok).toBe(true);
  });
  it("ฝั่งบุคคลไม่ต้องมีหลักฐาน → ยืนยันได้", () => {
    expect(cc4.attachments).toBeUndefined();
    expect(check(cc4).canConfirm).toBe(true);
  });
});

describe("บัญชี — engine เป็นคนตัดสิน", () => {
  it("ยังไม่เลือกบัญชี → ไม่ได้", () => {
    const c = check(cu1);
    expect(c.canConfirm).toBe(false);
    expect(c.blockedReason).toContain("บัญชี");
    expect(confirm([cu1]).ok).toBe(false);
  });
  it("บัญชีของผู้ถืออื่น → ไม่ได้", () => {
    const c = check(cu1, draft(cu1, { bankAccountId: "b4" }));
    expect(c.canConfirm).toBe(false);
    expect(c.blockedReason).toBeTruthy();
  });
  it("บัญชีที่ปิดแล้ว → ไม่ได้", () => {
    expect(MOCK_RESOLVER.bankAccount("b2")?.isActive).toBe(false);
    const c = check(cu1, draft(cu1, { bankAccountId: "b2" }));
    expect(c.canConfirm).toBe(false);
  });
  it("บัญชีที่ไม่มีในระบบ → ไม่ได้", () => {
    expect(check(cu1, draft(cu1, { bankAccountId: "b-ghost" })).canConfirm).toBe(false);
  });
  it("บัญชีของผู้ถือรายการนั้นและเปิดอยู่ → ได้", () => {
    expect(check(cu1, draft(cu1, { bankAccountId: "b1" })).canConfirm).toBe(true);
    expect(check(cu2, draft(cu2, { bankAccountId: "b4" })).canConfirm).toBe(true);
  });
  it("บัญชีในตัวรายการชนะช่องเลือกบัญชีเสมอ — เลือกบัญชีคนอื่นทับไม่ได้", () => {
    const d = draft(cc4, { bankAccountId: "b1" });
    expect(clearingInputOf(cc4, d, fresh()).bankAccountId).toBe("b4");
    expect(check(cc4, d).canConfirm).toBe(true);
  });
  it("แถวที่ผูกบัญชีไว้แต่บัญชีนั้นเป็นของคนอื่น → ไม่ได้ (ไม่แก้ให้ผ่าน)", () => {
    const wrong: PendingCashRow = { ...cc4, bankAccountId: "b1" };
    expect(check(wrong).canConfirm).toBe(false);
  });
  it("ตัวเลือกผลลัพธ์พรีวิวผูกรหัสบัญชีที่เลือก ไม่ใช่ชื่อ", () => {
    const c = check(cu1, draft(cu1, { bankAccountId: "b1" }));
    const input = clearingInputOf(cu1, draft(cu1, { bankAccountId: "b1" }), fresh());
    expect(input.bankAccountId).toBe("b1");
    expect(c.canConfirm).toBe(true);
  });
});

describe("ยืนยันซ้ำและยืนยันบางส่วน — ประวัติมาจากสิ่งที่ post จริง", () => {
  it("ยืนยันสำเร็จแล้วกดซ้ำรายการเดิม → ไม่ได้ และยอดไม่เพิ่มสองเท่า", () => {
    const first = confirm([cc4]);
    if (!first.ok) throw new Error("รอบแรกต้องผ่าน");
    expect(first.posted.cc4).toHaveLength(1);
    expect(first.posted.cc4[0].amount).toBe(12_000);

    const again = confirm([cc4], {}, first.posted);
    expect(again.ok).toBe(false);
    expect(again.posted).toBe(first.posted); // ไม่คืนประวัติใหม่
    expect(first.posted.cc4).toHaveLength(1);
    expect(first.posted.cc4.reduce((t, c) => t + c.amount, 0)).toBe(12_000);

    // ปุ่มสะท้อนสถานะ: หลังยืนยันครบ แถวนี้ต้องถูก engine ปฏิเสธ
    const after = check(cc4, draft(cc4), first.posted);
    expect(after.canConfirm).toBe(false);
    expect(after.blockedReason).toContain("ครบแล้ว");
  });

  it("ส่ง postedClearings ตามประวัติจริง ไม่ใช่ยอดสรุปที่หน้าจอคิดเอง", () => {
    const first = confirm([cc4]);
    if (!first.ok) throw new Error("รอบแรกต้องผ่าน");
    const input = clearingInputOf(cc4, draft(cc4), first.posted);
    expect(input.postedClearings).toBe(first.posted.cc4);
    expect(Object.keys(input)).not.toContain("clearedAmount");
  });

  it("ยืนยันบางส่วน แล้วยืนยันส่วนที่เหลือ → ได้ และรวมกันไม่เกินยอดค้าง", () => {
    const slip = [mockEvidenceRef(12)];
    const part1 = confirm([cc3], { cc3: draft(cc3, { slips: slip, amount: "30,000.00" }) });
    if (!part1.ok) throw new Error("ส่วนแรกต้องผ่าน");
    expect(part1.posted.cc3.map((c) => c.amount)).toEqual([30_000]);

    // ส่วนที่เหลือเกินไม่ได้ — engine บอกยอดคงเหลือเอง
    const tooMuch = confirm([cc3], { cc3: draft(cc3, { slips: slip, amount: "15,000.01" }) }, part1.posted);
    expect(tooMuch.ok).toBe(false);
    if (!tooMuch.ok) expect(tooMuch.failures[0].reason).toContain("เกินยอดค้าง");

    const part2 = confirm([cc3], { cc3: draft(cc3, { slips: slip, amount: "15,000" }) }, part1.posted);
    if (!part2.ok) throw new Error("ส่วนที่เหลือต้องผ่าน");
    expect(part2.posted.cc3.map((c) => c.amount)).toEqual([30_000, 15_000]);
    expect(part2.posted.cc3.reduce((t, c) => t + c.amount, 0)).toBe(cc3.accruedAmount);

    // ครบแล้ว กดอีกไม่ได้ แม้ยอดเล็กน้อย
    expect(confirm([cc3], { cc3: draft(cc3, { slips: slip, amount: "1" }) }, part2.posted).ok).toBe(false);
  });

  it("แถวเดียวกันซ้ำสองครั้งในชุดเดียว → ครั้งที่สองถูกปฏิเสธ ทั้งชุดไม่บันทึก", () => {
    const r = confirm([cc4, cc4]);
    expect(r.ok).toBe(false);
  });

  it("ประวัติที่ส่งมากับตัวรายการ (ยืนยันครบไปแล้ว) → ยืนยันไม่ได้", () => {
    const done: PendingCashRow = { ...cc4, postedClearings: [{ id: "old-1", amount: 12_000 }] };
    expect(check(done, draft(done), initialPosted([done])).canConfirm).toBe(false);
  });

  it("ยอดที่ลงประวัติคือยอดที่ engine ปัดแล้ว ไม่ใช่ตัวเลขดิบที่พิมพ์", () => {
    const r = confirm([cc4], { cc4: draft(cc4, { amount: "11,999.996" }) });
    if (!r.ok) throw new Error("ต้องผ่าน");
    expect(r.posted.cc4[0].amount).toBe(12_000);
  });

  it("ยอดอ่านไม่ออก / ติดลบ / ศูนย์ → ไม่ได้ ไม่ปัดเป็นศูนย์เงียบๆ", () => {
    for (const amount of ["", "abc", "(100)", "-5", "0"]) {
      expect(check(cc4, draft(cc4, { amount })).canConfirm, amount).toBe(false);
    }
  });
});

describe("รายการที่ไม่ใช่ค้างรับ-ค้างจ่าย", () => {
  const nonAccrual = TX_TYPES.flatMap((t) => t.subs.map((s) => ({ t, s }))).find(({ s }) => !accrualCheck(s).ok)!;

  it("หมวดที่ตั้งค้างไม่ได้ → ยืนยันไม่ได้ พร้อมเหตุผลของ engine", () => {
    const row: PendingCashRow = { ...cc4, typeKey: nonAccrual.t.key, subCode: nonAccrual.s.code };
    const c = check(row);
    expect(c.canConfirm).toBe(false);
    expect(c.blockedReason).toBeTruthy();
  });
  it("หมวดไม่อยู่ใต้ประเภท → ไม่ได้", () => {
    expect(check({ ...cc4, typeKey: "expense" }).canConfirm).toBe(false);
  });
  it("ยอดค้างเป็นศูนย์ → ไม่ได้", () => {
    expect(check({ ...cc4, accruedAmount: 0 }).canConfirm).toBe(false);
  });
});

describe("เคส 'ไม่ส่ง' ทุกฟิลด์ใหม่ — ต้องถูกปฏิเสธ ไม่ตกไปเส้นทางปกติ", () => {
  // ข้อสังเกตถึง engine: ไม่ส่ง typeKey ทำให้ `isValidPair()` โยน Error ธรรมดา (ไม่ใช่ PostingError)
  // หน้าจอจึงไม่กลืนและปล่อยให้ดังขึ้นไป — ไม่มีทางผ่านเงียบๆ แต่ผู้ใช้จะไม่เห็นข้อความที่อ่านรู้เรื่อง
  // เคสนี้ยอมรับทั้ง "ปฏิเสธ" และ "โยน" · ถ้า engine เปลี่ยนเป็น PostingError ก็ยังผ่าน
  it("ไม่ส่ง typeKey → ไม่มีทางยืนยันได้", () => {
    const row = without(cc4, "typeKey");
    let confirmed: boolean;
    try {
      confirmed = check(row).canConfirm;
    } catch {
      confirmed = false;
    }
    expect(confirmed).toBe(false);
    let outcome: boolean;
    try {
      outcome = confirm([row], {}, initialPosted([row])).ok;
    } catch {
      outcome = false;
    }
    expect(outcome).toBe(false);
  });
  it("ไม่ส่ง subCode", () => expect(check(without(cc4, "subCode")).canConfirm).toBe(false));
  it("ไม่ส่ง accruedAmount", () => expect(check(without(cc4, "accruedAmount")).canConfirm).toBe(false));
  it("ไม่ส่ง postedClearings → engine ปฏิเสธ ไม่ใช่เดาว่ายังไม่เคยยืนยัน", () => {
    const row = without(cc4, "postedClearings");
    const c = check(row, draft(row), initialPosted([row]));
    expect(c.canConfirm).toBe(false);
    expect(c.blockedReason).toContain("ประวัติ");
  });
  it("ไม่ส่ง ownerId", () => expect(check(without(cc4, "ownerId")).canConfirm).toBe(false));
  it("ไม่ส่ง bankAccountId และไม่ได้เลือก (แถวในกลุ่ม)", () => {
    expect(check(without(cc4, "bankAccountId")).canConfirm).toBe(false);
  });
  it("นิติบุคคลไม่ส่ง attachments → ไม่ได้", () => {
    expect(check(cc1).canConfirm).toBe(true);
    expect(check(without(cc1, "attachments")).canConfirm).toBe(false);
  });
  it("นิติบุคคลส่ง attachments เป็นอาร์เรย์ว่าง → ไม่ได้", () => {
    expect(check({ ...cc1, attachments: [] }).canConfirm).toBe(false);
  });
  it("นิติบุคคลไม่ส่ง contactId → ไม่ได้", () => {
    expect(check(without(cc1, "contactId")).canConfirm).toBe(false);
  });
  it("ไม่ส่งวันที่ → ไม่ได้", () => {
    expect(check(cc4, draft(cc4, { date: "" })).canConfirm).toBe(false);
  });
  it("ทุกกรณีข้างต้นผ่าน confirmRows แล้วไม่ทิ้งประวัติใหม่", () => {
    for (const key of ["subCode", "accruedAmount", "ownerId", "bankAccountId"] as const) {
      const row = without(cc4, key);
      const r = confirm([row], {}, initialPosted([row]));
      expect(r.ok, key).toBe(false);
    }
  });
});

describe("ทั้งหมดหรือไม่มีเลย", () => {
  it("มีแถวหนึ่งไม่ผ่าน → ไม่มีแถวใดถูกบันทึก ประวัติไม่เปลี่ยน", () => {
    const posted = fresh();
    const r = confirm([cc4, cc3], {}, posted); // cc3 ไม่มีหลักฐาน
    expect(r.ok).toBe(false);
    expect(r.posted).toBe(posted);
    expect(posted.cc4).toEqual([]);
    if (!r.ok) expect(r.failures.map((f) => f.row.id)).toEqual(["cc3"]);
  });
  it("ไม่ได้เลือกอะไรเลย → ไม่ได้", () => {
    expect(confirm([]).ok).toBe(false);
  });
  it("ทุกแถวผ่าน → คืนผลของ engine ที่พร้อมบันทึก และประวัติต่อท้ายของเดิม", () => {
    const r = confirm([cc4, cc1]);
    if (!r.ok) throw new Error("ต้องผ่าน");
    expect(r.confirmed.map((c) => c.row.id)).toEqual(["cc4", "cc1"]);
    for (const c of r.confirmed) expect(c.result.transactions.length).toBeGreaterThan(0);
  });
});

describe("ทิศทางรับ-จ่ายอ่านจากตารางกฎ", () => {
  it("ค่าเช่า = รับ · ค่าส่วนกลาง = จ่าย", () => {
    expect(directionOf(cc4)).toBe("in");
    expect(directionOf(find("cc5"))).toBe("out");
  });
  it("ไม่รู้หมวด → null ไม่เดา", () => {
    expect(directionOf({ subCode: "ghost" })).toBeNull();
    expect(directionOf({ subCode: undefined as unknown as string })).toBeNull();
  });
});

describe("ข้อมูลที่กติกาใช้ต้องเดินทางไปกับ input", () => {
  it("ส่งทรัพย์ คู่ค้า หลักฐาน และเลขอ้างอิงตามตัวรายการ", () => {
    const input = clearingInputOf(cc1, draft(cc1, { slips: [mockEvidenceRef(12)] }), fresh());
    expect(input.assetId).toBe(cc1.assetId);
    expect(input.contactId).toBe(cc1.contactId);
    expect(input.attachments).toEqual([...(cc1.attachments ?? []), mockEvidenceRef(12)]);
    expect(input.clearingRef).toBe("cc1-clr-1");
    expect(input.typeKey).toBe(cc1.typeKey);
    expect(input.subCode).toBe(cc1.subCode);
    expect(input.accruedAmount).toBe(cc1.accruedAmount);
  });
  it("เลขอ้างอิงเดินตามประวัติ — ยืนยันครั้งถัดไปได้เลขใหม่", () => {
    const r = confirm([cc4]);
    if (!r.ok) throw new Error("ต้องผ่าน");
    expect(clearingInputOf(cc4, draft(cc4), r.posted).clearingRef).toBe("cc4-clr-2");
  });
});

describe("ทางล้าง — ไม่หยิบตัวแรกให้", () => {
  it("ไม่เลือกทางล้าง → ส่ง undefined ไม่เติมค่าเริ่มต้น", () => {
    expect(clearingInputOf(cc4, draft(cc4), fresh()).clearingSubCode).toBeUndefined();
  });
  it("ทางที่เลือกเองถูกส่งต่อตามจริง และถ้าไม่ใช่ทางของรายการนี้ engine ปฏิเสธ", () => {
    const d = draft(cc4, { clearingSubCode: "ghost.route" });
    expect(clearingInputOf(cc4, d, fresh()).clearingSubCode).toBe("ghost.route");
    expect(check(cc4, d).canConfirm).toBe(false);
  });
});

describe("ไม่มีกฎบัญชีเหลืออยู่ในหน้าจอ", () => {
  const dir = path.resolve(__dirname, "..");
  const read = (f: string) => fs.readFileSync(path.join(dir, f), "utf8");
  /** ตัดคอมเมนต์ออก — คอมเมนต์พูดถึงชื่อฟังก์ชันได้ แต่โค้ดห้ามเรียกผิดตัว */
  const code = (f: string) => read(f).replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1");

  it("confirm-gate.ts ถูกลบ และไม่มีใครอ้างถึง", () => {
    expect(fs.existsSync(path.join(dir, "confirm-gate.ts"))).toBe(false);
    for (const f of ["confirm-tab.tsx", "confirm-flow.ts", "ledger-tabs.tsx"]) {
      expect(code(f), f).not.toContain("confirm-gate");
      expect(code(f), f).not.toContain("confirmBankError");
    }
  });
  it("ตัวต่อไม่เขียนคู่บัญชีหรือรหัสบัญชีเอง", () => {
    const flow = code("confirm-flow.ts");
    expect(flow).not.toMatch(/["']\d{4}["']/); // รหัสบัญชีสี่หลัก
    expect(flow).not.toMatch(/\b(dr|cr):/);
  });
  it("ตัวต่อใช้ buildClearing ตัวจริงตอนกดยืนยัน (confirmRows) และ draft เฉพาะพรีวิว", () => {
    const flow = code("confirm-flow.ts");
    const confirmBody = flow.slice(flow.indexOf("export function confirmRows"));
    expect(confirmBody).toContain("buildClearing(input, resolve)");
    expect(confirmBody).not.toContain("buildClearingDraft");
  });
  it("หน้าจอไม่เรียก engine เอง — ตัดสินผ่าน checkRow / confirmRows เท่านั้น", () => {
    const tab = code("confirm-tab.tsx");
    expect(tab).toContain("confirmRows(");
    expect(tab).not.toContain("buildClearing");
    expect(tab).not.toMatch(/canConfirm\s*=|\.canConfirm\s*=/);
  });
});
