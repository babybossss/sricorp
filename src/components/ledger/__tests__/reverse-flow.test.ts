/**
 * เทสต์ของตรรกะแผง "แก้รายการที่ลงผิด" (`reverse-flow.ts`)
 *
 * ตรรกะนี้ **ไม่อยู่ใน JSX** โดยตั้งใจ: vitest ของโปรเจกต์นี้รันบน environment node
 * ตรรกะที่ฝังใน JSX จะไม่มีเทสต์ไหนแตะได้ แล้วการเผลอถอดขั้นยืนยันออกจะไม่มีใครจับได้
 * (แพทเทิร์นเดียวกับ `confirm-flow.ts` · `accruedAmountText`)
 */
import { describe, expect, it } from "vitest";
import { MIN_REASON_LEN, initialState, nextState, panelView, type PanelState } from "../reverse-flow";

const perms = (...p: string[]) => new Set(p);
const ALL = perms("ledger.approve", "txn.void");

const entry = { id: "txn-1", source: "manual", reversesId: null as string | null };

describe("initialState / panelView · ขั้นแรกต้องไม่ใช่ขั้นที่กดบันทึกได้", () => {
  it("เริ่มที่ 'ยังไม่เลือก' — ไม่มีช่องเหตุผล ไม่มีปุ่มยืนยัน", () => {
    const v = panelView(initialState(), entry, ALL);
    expect(v.step).toBe("idle");
    expect(v.showReason).toBe(false);
    expect(v.canSubmit).toBe(false);
  });

  it("ไม่มีสิทธิ์ → บอกเหตุเป็นคำ ไม่ใช่ซ่อนเงียบๆ แล้วให้ผู้ใช้งงว่าปุ่มหายไปไหน", () => {
    const v = panelView(initialState(), entry, perms("ledger.read"));
    expect(v.allowed).toBe(false);
    expect(v.notice).toMatch(/สิทธิ์/);
    expect(v.canSubmit).toBe(false);
  });

  it("ใบกลับรายการ: เสนอให้ 'ยกเลิกใบ' ได้ แต่ไม่เสนอ 'กลับรายการ' (จะกลับซ้อนชั้น)", () => {
    const v = panelView(initialState(), { ...entry, source: "reverse", reversesId: "txn-0" }, ALL);
    expect(v.offerReverse).toBe(false);
    expect(v.offerVoid).toBe(true);
    expect(v.notice).toMatch(/เป็นใบกลับรายการอยู่แล้ว/);
  });
});

describe("nextState · ต้องผ่านขั้นยืนยันก่อนเสมอ", () => {
  const run = (steps: Parameters<typeof nextState>[1][]) =>
    steps.reduce<PanelState>((s, a) => nextState(s, a), initialState());

  it("เลือกวิธี → กรอกเหตุผล → ยืนยัน → ถึงจะกดบันทึกได้", () => {
    let s = run([{ kind: "choose", mode: "reverse" }]);
    expect(panelView(s, entry, ALL).step).toBe("reason");
    expect(panelView(s, entry, ALL).canSubmit).toBe(false);

    s = nextState(s, { kind: "reason", value: "ลงผิดห้อง ที่ถูกคือห้องอื่น" });
    const v1 = panelView(s, entry, ALL);
    expect(v1.step).toBe("reason");
    expect(v1.canSubmit).toBe(false); // ยังไม่ผ่านขั้นยืนยัน
    expect(v1.canAskConfirm).toBe(true);

    s = nextState(s, { kind: "ask-confirm" });
    const v2 = panelView(s, entry, ALL);
    expect(v2.step).toBe("confirm");
    expect(v2.canSubmit).toBe(true);
    expect(v2.confirmText).toMatch(/กลับรายการ/);
  });

  it("เหตุผลสั้นเกินไป → ยังไปขั้นยืนยันไม่ได้ และบอกว่าต้องยาวเท่าไร", () => {
    let s = nextState(initialState(), { kind: "choose", mode: "void" });
    s = nextState(s, { kind: "reason", value: "ผิด" });
    const v = panelView(s, entry, ALL);
    expect(v.canAskConfirm).toBe(false);
    expect(v.reasonError).toMatch(new RegExp(String(MIN_REASON_LEN)));
    // กดขอยืนยันทั้งที่เหตุผลไม่ผ่าน → สถานะต้องไม่เลื่อน
    expect(panelView(nextState(s, { kind: "ask-confirm" }), entry, ALL).step).toBe("reason");
  });

  it("เหตุผลที่เป็นช่องว่างล้วนไม่นับ", () => {
    let s = nextState(initialState(), { kind: "choose", mode: "reverse" });
    s = nextState(s, { kind: "reason", value: "            " });
    expect(panelView(s, entry, ALL).canAskConfirm).toBe(false);
  });

  it("แก้เหตุผลหลังผ่านขั้นยืนยันแล้ว → **ถอยกลับไปขั้นยืนยันใหม่** (ยืนยันของข้อความเก่าใช้ไม่ได้)", () => {
    let s = run([{ kind: "choose", mode: "reverse" }, { kind: "reason", value: "เหตุผลที่ยาวพอแล้ว" }, { kind: "ask-confirm" }]);
    expect(panelView(s, entry, ALL).canSubmit).toBe(true);
    s = nextState(s, { kind: "reason", value: "เปลี่ยนใจ เขียนเหตุผลใหม่" });
    expect(panelView(s, entry, ALL).step).toBe("reason");
    expect(panelView(s, entry, ALL).canSubmit).toBe(false);
  });

  it("เปลี่ยนวิธี (กลับรายการ ↔ ยกเลิกใบ) → ย้อนกลับไปขั้นยืนยันใหม่ ไม่ยกยอดการยืนยันข้ามวิธี", () => {
    let s = run([{ kind: "choose", mode: "reverse" }, { kind: "reason", value: "เหตุผลที่ยาวพอแล้ว" }, { kind: "ask-confirm" }]);
    s = nextState(s, { kind: "choose", mode: "void" });
    const v = panelView(s, entry, ALL);
    expect(v.step).toBe("reason");
    expect(v.canSubmit).toBe(false);
    expect(v.reason).toBe("เหตุผลที่ยาวพอแล้ว"); // ข้อความที่พิมพ์ไว้ไม่หาย (ไม่ให้พิมพ์ซ้ำ)
  });

  it("ยกเลิกแผง → กลับไปขั้นแรกและลืมข้อความทิ้ง", () => {
    let s = run([{ kind: "choose", mode: "reverse" }, { kind: "reason", value: "เหตุผลที่ยาวพอแล้ว" }, { kind: "ask-confirm" }]);
    s = nextState(s, { kind: "cancel" });
    expect(panelView(s, entry, ALL).step).toBe("idle");
    expect(s.reason).toBe("");
  });

  it("ระหว่างส่ง (busy) กดซ้ำไม่ได้", () => {
    let s = run([{ kind: "choose", mode: "reverse" }, { kind: "reason", value: "เหตุผลที่ยาวพอแล้ว" }, { kind: "ask-confirm" }]);
    s = nextState(s, { kind: "busy" });
    expect(panelView(s, entry, ALL).canSubmit).toBe(false);
    expect(panelView(s, entry, ALL).busy).toBe(true);
  });

  it("ผลจาก server แสดงตามที่ server บอก ไม่แต่งเอง · ล้มเหลวแล้วแก้เหตุผลต่อได้", () => {
    let s = run([{ kind: "choose", mode: "reverse" }, { kind: "reason", value: "เหตุผลที่ยาวพอแล้ว" }, { kind: "ask-confirm" }, { kind: "busy" }]);
    s = nextState(s, { kind: "done", result: { ok: false, message: "ฐานข้อมูลปฏิเสธ: เหตุผลของ DB" } });
    const v = panelView(s, entry, ALL);
    expect(v.busy).toBe(false);
    expect(v.result).toEqual({ ok: false, message: "ฐานข้อมูลปฏิเสธ: เหตุผลของ DB" });
    expect(v.step).toBe("reason"); // ถอยกลับให้แก้ได้ ไม่ค้างที่ขั้นยืนยัน
  });

  it("สำเร็จ → แผงปิดตัวเองและแสดงข้อความสำเร็จของ server", () => {
    let s = run([{ kind: "choose", mode: "reverse" }, { kind: "reason", value: "เหตุผลที่ยาวพอแล้ว" }, { kind: "ask-confirm" }, { kind: "busy" }]);
    s = nextState(s, { kind: "done", result: { ok: true, message: "กลับรายการแล้ว" } });
    const v = panelView(s, entry, ALL);
    expect(v.step).toBe("done");
    expect(v.canSubmit).toBe(false);
    expect(v.result).toEqual({ ok: true, message: "กลับรายการแล้ว" });
  });
});

describe("panelView · ข้อความต้องบอกว่าจะเกิดอะไรขึ้นกับตัวเลข", () => {
  it("กลับรายการ: บอกว่าต้นฉบับยังอยู่และนับต่อ · ยกเลิกใบ: บอกว่าตัดออกจากงบ", () => {
    const rev = panelView(nextState(initialState(), { kind: "choose", mode: "reverse" }), entry, ALL);
    expect(rev.explain).toMatch(/ยังอยู่ในสมุด/);
    expect(rev.explain).toMatch(/ไม่ลบ/);

    const vd = panelView(nextState(initialState(), { kind: "choose", mode: "void" }), entry, ALL);
    expect(vd.explain).toMatch(/ตัดออกจากงบ/);
    expect(vd.explain).toMatch(/ยังเห็นได้/);
  });
});
