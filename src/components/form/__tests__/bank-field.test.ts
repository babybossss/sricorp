import { describe, it, expect } from "vitest";
import { TX_TYPES, allowedSubs, findSub, movesCash } from "@/lib/rules/tx-rules";
import { isCashAccount } from "@/lib/rules/coa";
import { bankDirectionLabel, bankChoices, showsBankField } from "../bank-field";

const sub = (code: string) => findSub(code)!.sub;

/**
 * ฟอร์มต้องไม่ถามบัญชีธนาคารกับรายการที่ไม่มีเงินเคลื่อน
 *
 * ถ้าถาม: ผู้ใช้เลือกบัญชีมา → engine ปฏิเสธ (บัญชีบนรายการที่ไม่มีขาเงินสด)
 * → ปุ่มบันทึกดับโดยที่ไม่มีช่องไหนบอกว่าต้องแก้อะไร · และถ้าวันหนึ่ง engine
 * เผลอเมินค่านั้นแทนที่จะปฏิเสธ บัญชีจะติดไปกับรายการเงียบๆ แล้วถูกนับเป็น
 * ความเคลื่อนไหวของบัญชีนั้นตอนกระทบยอด
 */
describe("showsBankField — ขั้นเลือกบัญชีต้องไม่โชว์เลยสำหรับหมวดที่ไม่มีเงินเคลื่อน", () => {
  it("หมวดปรับปรุงทางบัญชีทั้งห้า → ไม่โชว์", () => {
    const adj = allowedSubs("adjust");
    expect(adj.length, "ต้องมีหมวดให้ทดสอบ").toBe(5);
    for (const s of adj) expect(showsBankField(s), s.code).toBe(false);
  });

  it("หมวดที่เงินเคลื่อนจริง → โชว์ (ห้ามซ่อนของที่ต้องกรอก)", () => {
    for (const code of ["inc.rent", "exp.repair", "trf.internal", "inv.sell_re", "fin.repay_bank"]) {
      expect(showsBankField(sub(code)), code).toBe(true);
    }
  });

  it("คำตอบตรงกับคู่บัญชีจริงทุกหมวดในตารางกฎ — ไม่ใช่รายชื่อที่ต้องมาเติมมือ", () => {
    for (const s of TX_TYPES.flatMap((t) => t.subs)) {
      expect(showsBankField(s), `${s.code} (cash: ${s.cash})`).toBe(
        isCashAccount(s.dr) || isCashAccount(s.cr)
      );
      expect(showsBankField(s), s.code).toBe(movesCash(s));
    }
  });

  it("ยังไม่เลือกหมวด → โชว์ไว้ก่อน ไม่ให้โครงฟอร์มกระพริบ", () => {
    expect(showsBankField(undefined)).toBe(true);
  });
});

describe("bankDirectionLabel — ป้ายต้องบอกว่าบัญชีเข้าหรือออก", () => {
  it("รายได้ = บัญชีที่เงินเข้า", () => expect(bankDirectionLabel(sub("inc.rent"))).toBe("รับเงินเข้าบัญชี"));
  it("ค่าใช้จ่าย = บัญชีที่จ่ายออก", () => expect(bankDirectionLabel(sub("exp.repair"))).toBe("จ่ายเงินออกจากบัญชี"));
  it("โอน = บัญชีต้นทาง (ดูจาก requires ไม่ใช่รหัสหมวด)", () => {
    expect(sub("trf.internal").requires).toContain("transferTarget");
    expect(bankDirectionLabel(sub("trf.internal"))).toContain("ต้นทาง");
  });
  it("ยังไม่เลือกหมวด → ป้ายกลาง ไม่พัง", () => expect(bankDirectionLabel(undefined)).toBe("บัญชีธนาคาร"));
  it("หมวดที่ไม่มีเงินเคลื่อน → ป้ายของตัวเอง ไม่ใช่คำของ both", () => {
    expect(bankDirectionLabel(sub("adj.doubtful"))).toContain("ไม่มีเงินเคลื่อน");
    expect(bankDirectionLabel(sub("adj.doubtful"))).not.toBe(bankDirectionLabel(sub("trf.internal")));
    expect(bankDirectionLabel(sub("adj.writeoff_rent"))).not.toBe("บัญชีที่เงินเข้า/ออก");
  });
  it("ไม่มีป้ายไหนเป็นคำกลางๆ ว่า \"บัญชี\" เฉยๆ เมื่อรู้หมวดแล้ว", () => {
    for (const code of ["inc.rent", "exp.repair", "trf.internal"]) {
      expect(bankDirectionLabel(sub(code))).not.toBe("บัญชีธนาคาร");
    }
  });
});

describe("bankChoices", () => {
  const banks = [
    { id: "a", ownerId: "corp" },
    { id: "b", ownerId: "corp" }, // ปิดแล้ว
    { id: "c", ownerId: "thanakorn" },
  ];
  const isOff = (id: string) => id === "b";

  it("เฉพาะของผู้ถือที่เลือก และเฉพาะที่ยังเปิด", () => {
    expect(bankChoices(banks, isOff, "corp").map((b) => b.id)).toEqual(["a"]);
  });

  it("บัญชีของรายการเดิมที่ปิดไปแล้ว ต้องยังเลือกได้ (กลับรายการเก่า)", () => {
    expect(bankChoices(banks, isOff, "corp", "b").map((b) => b.id)).toEqual(["a", "b"]);
  });

  it("keepId ของผู้ถือคนอื่นไม่ทำให้บัญชีข้ามผู้ถือโผล่", () => {
    expect(bankChoices(banks, isOff, "corp", "c").map((b) => b.id)).toEqual(["a"]);
  });
});
