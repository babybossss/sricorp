import { describe, it, expect } from "vitest";
import { findSub } from "@/lib/rules/tx-rules";
import { bankDirectionLabel, bankChoices } from "../bank-field";

const sub = (code: string) => findSub(code)!.sub;

describe("bankDirectionLabel — ป้ายต้องบอกว่าบัญชีเข้าหรือออก", () => {
  it("รายได้ = บัญชีที่เงินเข้า", () => expect(bankDirectionLabel(sub("inc.rent"))).toBe("รับเงินเข้าบัญชี"));
  it("ค่าใช้จ่าย = บัญชีที่จ่ายออก", () => expect(bankDirectionLabel(sub("exp.repair"))).toBe("จ่ายเงินออกจากบัญชี"));
  it("โอน = บัญชีต้นทาง (ดูจาก requires ไม่ใช่รหัสหมวด)", () => {
    expect(sub("trf.internal").requires).toContain("transferTarget");
    expect(bankDirectionLabel(sub("trf.internal"))).toContain("ต้นทาง");
  });
  it("ยังไม่เลือกหมวด → ป้ายกลาง ไม่พัง", () => expect(bankDirectionLabel(undefined)).toBe("บัญชีธนาคาร"));
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
