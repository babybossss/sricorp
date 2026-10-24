import { describe, it, expect } from "vitest";
import { dmyToIso, isoToDmy, todayDmy } from "../format";

describe("dmyToIso · วันที่ในฟอร์มก่อนส่งลง DB", () => {
  it("แปลง วว/ดด/ปปปป (ค.ศ.) เป็น YYYY-MM-DD รวมรูปที่พิมพ์ไม่ครบหลัก", () => {
    expect(dmyToIso("24/10/2026")).toBe("2026-10-24");
    expect(dmyToIso("1/9/2026")).toBe("2026-09-01");
    expect(dmyToIso(" 03/09/2026 ")).toBe("2026-09-03");
  });

  it("รับ YYYY-MM-DD ที่ถูกต้องเท่านั้น", () => {
    expect(dmyToIso("2026-10-24")).toBe("2026-10-24");
    expect(dmyToIso("2026-13-01")).toBeNull();
  });

  it("ไม่ใช่วันที่จริง = null (ไม่เดา · ไม่ปัดให้)", () => {
    expect(dmyToIso("31/02/2026")).toBeNull();
    expect(dmyToIso("00/10/2026")).toBeNull();
    expect(dmyToIso("24/13/2026")).toBeNull();
    expect(dmyToIso("")).toBeNull();
    expect(dmyToIso("เมื่อวาน")).toBeNull();
    expect(dmyToIso("24-10-2026")).toBeNull();
  });

  it("29 ก.พ. ผ่านเฉพาะปีอธิกสุรทิน", () => {
    expect(dmyToIso("29/02/2028")).toBe("2028-02-29");
    expect(dmyToIso("29/02/2026")).toBeNull();
  });

  it("ปี พ.ศ. ถูกปฏิเสธ ไม่แปลงเอง — แปลงผิดทิศ = ลงบัญชีผิดปีเงียบๆ", () => {
    expect(dmyToIso("24/10/2569")).toBeNull();
  });
});

describe("todayDmy · isoToDmy", () => {
  it("ใช้เวลากรุงเทพฯ: 17:30 UTC ของวันที่ 24 คือเช้าวันที่ 25 ที่ไทย", () => {
    expect(todayDmy(new Date("2026-10-24T17:30:00Z"))).toBe("25/10/2026");
    expect(todayDmy(new Date("2026-10-24T16:30:00Z"))).toBe("24/10/2026");
  });

  it("ผลของ todayDmy อ่านกลับเป็นวันที่ได้เสมอ", () => {
    expect(dmyToIso(todayDmy())).not.toBeNull();
  });

  it("isoToDmy แสดงผลกลับ · ว่างคือขีด", () => {
    expect(isoToDmy("2026-10-24")).toBe("24/10/2026");
    expect(isoToDmy(null)).toBe("—");
  });
});
