/**
 * ปิด-เปิดบัญชีในหน้าตั้งค่า แล้วเครื่องยนต์ต้องเห็น **ทันที** (D-092)
 *
 * ชุดนี้ทดสอบ **รอยต่อระหว่างแอปกับเครื่องยนต์** ไม่ใช่กฎบัญชี จึงอยู่ที่ `lib/mock`
 * ไม่ใช่ `lib/ledger` (เทสต์ใน `lib/ledger` ห้าม import `lib/mock` — มีเทสต์โครงสร้าง
 * บังคับไว้ที่ `lib/ledger/__tests__/resolver.test.ts` และนั่นคือเหตุผลที่รูนี้
 * รอดสายตามาได้: เทสต์ของเครื่องยนต์ส่ง resolver ของตัวเองเข้าไป จึงไม่เคยแตะรอยต่อนี้)
 *
 * รูที่เคยมี: ช่องเลือกบัญชีในฟอร์มอ่านสถานะปิด-เปิดจาก store (`bankOff`) แต่
 * `MOCK_RESOLVER` อ่านจาก `BANKS[].off` ซึ่งเป็น **ค่าคงที่ในไฟล์** ผลคือผู้ใช้ปิดบัญชี
 * ในหน้าตั้งค่า → หน้าจอซ่อนให้ แต่เครื่องยนต์ยังคิดว่าเปิดอยู่ = การกันบัญชีปิด
 * **ไม่ทำงานจริงในแอป** (ข้อเท็จจริงเดียวอ่านจากสองแหล่ง · บทเรียน mace-windu ข้อ 5)
 *
 * ทิศที่ถูกคือ **เครื่องยนต์อ่านค่าสด** ไม่ใช่ย้อนให้หน้าจออ่านค่าแช่
 *
 * ทำไมยังสำคัญวันที่ต่อ Supabase จริง: resolver ตัวจริงจะอ่าน `sri_os.bank_accounts`
 * ซึ่งเปลี่ยนได้ตลอดเวลาโดยที่โปรเซสของเราไม่ได้ restart ถ้าใครห่อสถานะบัญชีเป็น
 * ก้อนค่าคงที่ที่สร้างครั้งเดียว (snapshot ตอนโหลดหน้า / cache ระดับโมดูล)
 * บัญชีที่ปิดใน DB จะยังรับรายการใหม่ได้จนกว่าจะ deploy ใหม่ — รูเดิมในรูปแบบใหม่
 * เทสต์ชุดนี้จึงยังต้องอยู่ และต้องชี้ไปที่ resolver ตัวที่แอปใช้จริงเสมอ
 */

import { describe, it, expect, afterEach } from "vitest";
import { buildPosting, buildPostingDraft } from "@/lib/ledger/posting";
import { previewPosting } from "@/lib/ledger/preview";
import { PostingError, type PostingInput } from "@/lib/ledger/types";
import { MOCK_RESOLVER } from "../resolver";
import { BANKS } from "../banks";
import { useApp } from "@/lib/store";

/** ค่าเช่าของธนากร (บุคคล จึงไม่ติดกติกาเอกสารของนิติบุคคล) เข้าบัญชี b4 ที่เปิดอยู่ */
const rent: PostingInput = {
  typeKey: "income",
  subCode: "inc.rent",
  amount: 12_000,
  ownerId: "thanakorn",
  bankAccountId: "b4",
  assetId: "rent1",
  contactId: "c1",
};

/** ค่าซ่อมของ SRI Corporation เข้าบัญชี b2 ที่ seed ไว้ว่า "ปิดแล้ว" */
const corpExpense: PostingInput = {
  typeKey: "expense",
  subCode: "exp.repair",
  amount: 5_000,
  ownerId: "corp",
  bankAccountId: "b2",
  assetId: "rent2",
  contactId: "c2",
  attachments: ["ใบเสร็จ.pdf"],
};

/** store เป็นสถานะระดับโมดูล — คืนค่าเดิมทุกเคส ไม่ให้เคสหนึ่งรบกวนอีกเคส */
const seeded = { ...useApp.getState().bankOff };
afterEach(() => useApp.setState({ bankOff: { ...seeded } }));

describe("เครื่องยนต์อ่านสถานะปิด-เปิดบัญชีจากแหล่งเดียวกับหน้าจอ", () => {
  it("ปิดบัญชีในหน้าตั้งค่า แล้วเรียก buildPosting() ทันที → ถูกปฏิเสธ", () => {
    expect(() => buildPosting(rent, MOCK_RESOLVER)).not.toThrow();

    useApp.getState().toggleBank("b4");

    expect(() => buildPosting(rent, MOCK_RESOLVER)).toThrow(PostingError);
    expect(() => buildPosting(rent, MOCK_RESOLVER)).toThrow(/ปิดใช้งาน/);
  });

  it("เปิดกลับ แล้วผ่านเหมือนเดิม และได้ตัวเลขเดิม", () => {
    useApp.getState().toggleBank("b4");
    expect(() => buildPosting(rent, MOCK_RESOLVER)).toThrow(PostingError);

    useApp.getState().toggleBank("b4");
    const r = buildPosting(rent, MOCK_RESOLVER);
    expect(r.transactions).toHaveLength(1);
    expect(r.transactions[0].lines.find((l) => l.bankAccountId === "b4")?.debit).toBe(12_000);
  });

  it("เปิดบัญชีที่ seed ไว้ว่าปิด แล้วเครื่องยนต์ต้องยอมรับทันที", () => {
    expect(() => buildPosting(corpExpense, MOCK_RESOLVER)).toThrow(/ปิดใช้งาน/);

    useApp.getState().toggleBank("b2");
    expect(() => buildPosting(corpExpense, MOCK_RESOLVER)).not.toThrow();
  });

  it("resolver คืน isActive ตามค่าสดใน store ไม่ใช่ค่าคงที่ใน BANKS", () => {
    const b4 = BANKS.find((b) => b.id === "b4")!;
    expect(b4.off, "b4 ใน BANKS ต้องเป็นค่า seed ที่เปิดอยู่").toBe(false);

    useApp.getState().toggleBank("b4");

    // ค่าใน BANKS ไม่เปลี่ยน (เป็นแค่ seed) แต่ resolver ต้องบอกว่าปิดแล้ว
    expect(b4.off).toBe(false);
    expect(MOCK_RESOLVER.bankAccount("b4")?.isActive).toBe(false);
  });

  it("บัญชีที่ปิดยัง **หาเจอ** เพื่อให้รายการย้อนหลังแสดงและกลับรายการได้", () => {
    useApp.getState().toggleBank("b4");

    const b = MOCK_RESOLVER.bankAccount("b4");
    expect(b, "คืน null จะทำให้กลับรายการเก่าของบัญชีนี้ไม่ได้เลย (กฎเหล็กข้อ 1)").not.toBeNull();
    expect(b?.ownerId).toBe("thanakorn");
    expect(() => buildPosting({ ...rent, reversal: true }, MOCK_RESOLVER)).not.toThrow();
  });

  it("พรีวิวในฟอร์มเห็นสถานะสดเหมือนกัน — ไม่โชว์บรรทัดสวยๆ แล้วกดบันทึกเด้ง", () => {
    useApp.getState().toggleBank("b4");

    expect(() => buildPostingDraft(rent, MOCK_RESOLVER)).toThrow(/ปิดใช้งาน/);
    const p = previewPosting(rent, MOCK_RESOLVER);
    expect(p.ok).toBe(false);
    if (!p.ok) expect(p.reason).toMatch(/ปิดใช้งาน/);
  });

  it("บัญชีที่ store ไม่รู้จักสถานะ → ถือว่าปิด ไม่ใช่เดาว่าเปิด", () => {
    // ไม่บอก ≠ เปิดใช้งาน ไม่งั้นวันที่แหล่งข้อมูลลืมส่งสถานะ การกันบัญชีปิดจะหายเงียบๆ
    // (บทเรียน mace-windu ข้อ 1 และ ข้อ 3 — ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่เดา)
    const off = { ...useApp.getState().bankOff };
    delete off["b4"];
    useApp.setState({ bankOff: off });

    expect(MOCK_RESOLVER.bankAccount("b4")?.isActive).toBe(false);
    expect(() => buildPosting(rent, MOCK_RESOLVER)).toThrow(PostingError);
  });

  it("ทุกบัญชีใน BANKS มีสถานะใน store — ไม่มีบัญชีที่ตอบไม่ได้ว่าปิดหรือเปิด", () => {
    const off = useApp.getState().bankOff;
    for (const b of BANKS) expect(b.id in off, b.id).toBe(true);
  });
});
