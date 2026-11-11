/**
 * ตรรกะของแผง "แก้รายการที่ลงผิด" — **ไม่มีกติกาบัญชี และไม่มี JSX**
 *
 * ทำไมแยกไฟล์: การกลับรายการคือการเขียนตัวเลขเข้าสมุด ขั้นตอน "ต้องยืนยันก่อน" และ
 * "ต้องมีเหตุผล" จึงต้องมีเทสต์จับได้ · ตรรกะที่ฝังใน JSX ไม่มีเทสต์ไหนแตะได้
 * (vitest ของรีโปนี้รันบน environment node) แล้วการเผลอถอดขั้นยืนยันออกจะเงียบ
 *
 * ไฟล์นี้ตัดสินแค่ **ลำดับขั้นของหน้าจอ** · สิ่งที่ทำได้จริงกับตัวเลขตัดสินที่
 * `src/app/actions/reverse-entry.ts` (และด่านจริงอยู่ที่ DB) — ปุ่มที่นี่
 * **ไม่ใช่ตัวกั้น** ถ้าผู้ใช้กดได้แต่ server ปฏิเสธ ข้อความของ server ชนะเสมอ
 */

/** `reverse` = ลงใบกลับรายการ · `void` = ยกเลิกใบทั้งใบ (D-097 · สองกลไก ห้ามปนกัน) */
export type FixMode = "reverse" | "void";

/** เหตุผลที่สั้นกว่านี้อ่านแล้วตอบผู้สอบบัญชีไม่ได้ ("ผิด" ไม่ใช่เหตุผล) */
export const MIN_REASON_LEN = 8;

export type PanelStep = "idle" | "reason" | "confirm" | "done";

export type PanelState = {
  step: PanelStep;
  mode: FixMode | null;
  reason: string;
  busy: boolean;
  /** ผลจาก server ตรงๆ — ห้ามแต่งข้อความใหม่ที่นี่ */
  result: { ok: boolean; message: string } | null;
};

export const initialState = (): PanelState => ({ step: "idle", mode: null, reason: "", busy: false, result: null });

export type PanelAction =
  | { kind: "choose"; mode: FixMode }
  | { kind: "reason"; value: string }
  | { kind: "ask-confirm" }
  | { kind: "busy" }
  | { kind: "done"; result: { ok: boolean; message: string } }
  | { kind: "cancel" };

const reasonOk = (reason: string): boolean => reason.trim().length >= MIN_REASON_LEN;

/**
 * ขั้นต่อไปของแผง
 *
 * กฎที่ต้องไม่หาย (มีเทสต์จับทุกข้อ):
 * - จาก `idle` ไป `confirm` ตรงๆ **ไม่ได้** ต้องผ่านการพิมพ์เหตุผล
 * - แก้เหตุผล หรือเปลี่ยนวิธี หลังยืนยันแล้ว → **ถอยกลับ** ไปขั้นยืนยันใหม่
 *   (ไม่งั้นผู้ใช้ยืนยันข้อความหนึ่งแล้วส่งอีกข้อความหนึ่งไปลงสมุด)
 * - ระหว่าง `busy` ไม่รับอะไรนอกจากผลลัพธ์ (กันกดรัวซ้ำ · ประตูมีกันซ้ำอีกชั้น)
 */
export function nextState(s: PanelState, a: PanelAction): PanelState {
  if (s.busy && a.kind !== "done") return s;

  switch (a.kind) {
    case "choose":
      // เปลี่ยนวิธีต้องยืนยันใหม่ · ข้อความที่พิมพ์ไว้คงไว้ (ไม่บังคับให้พิมพ์ซ้ำ)
      return { ...s, step: "reason", mode: a.mode, result: null };
    case "reason":
      if (s.step === "idle" || s.step === "done") return s;
      return { ...s, step: "reason", reason: a.value, result: null };
    case "ask-confirm":
      if (s.step !== "reason" || !reasonOk(s.reason)) return s;
      return { ...s, step: "confirm" };
    case "busy":
      if (s.step !== "confirm") return s;
      return { ...s, busy: true, result: null };
    case "done":
      // ล้มเหลว → ถอยกลับให้แก้เหตุผล/ลองใหม่ได้ · สำเร็จ → ปิดแผง
      return { ...s, busy: false, result: a.result, step: a.result.ok ? "done" : "reason" };
    case "cancel":
      return initialState();
  }
}

/** รายการที่แผงนี้กำลังพูดถึง เท่าที่หน้าจอต้องรู้ (ไม่ใช่ทั้ง `LedgerEntry`) */
export type PanelEntry = { id: string; source: string; reversesId: string | null };

export type PanelView = {
  step: PanelStep;
  mode: FixMode | null;
  reason: string;
  busy: boolean;
  result: { ok: boolean; message: string } | null;
  /** มีสิทธิ์แก้รายการที่ post แล้วไหม */
  allowed: boolean;
  offerReverse: boolean;
  offerVoid: boolean;
  showReason: boolean;
  reasonError: string | null;
  canAskConfirm: boolean;
  canSubmit: boolean;
  /** คำอธิบายว่าจะเกิดอะไรกับตัวเลข — ผู้ใช้ต้องรู้ก่อนกด */
  explain: string | null;
  /** ข้อความบนปุ่มยืนยันขั้นสุดท้าย (มีข้อความกำกับเสมอ ห้ามปุ่มไอคอนเดี่ยว) */
  confirmText: string | null;
  /** ข้อความเตือน/บอกเหตุที่บางปุ่มไม่มีให้กด */
  notice: string | null;
};

const EXPLAIN: Record<FixMode, string> = {
  reverse:
    "ระบบจะลงใบใหม่ที่กลับข้างบรรทัดบัญชีของใบนี้ทั้งหมด แล้วผูกกับใบเดิมไว้ · " +
    "ใบเดิมยังอยู่ในสมุดและยังถูกนับ (ไม่ลบ ไม่ซ่อน) ยอดรวมของสองใบจึงเป็นศูนย์ · " +
    "ใช้วิธีนี้เมื่องวดนั้นปิดหรือส่งงบไปแล้ว เพราะงบเดือนเก่าจะไม่ขยับ",
  void:
    "ใบนี้จะถูกยกเลิกทั้งใบและ ตัดออกจากงบ ทันที โดย ยังเห็นได้ ในรายการที่ยกเลิก " +
    "พร้อมชื่อผู้ยกเลิก เวลา และเหตุผล (ไม่มีการลบ) · ใช้เมื่องวดนั้นยังไม่ปิด และใบนี้ผิดทั้งใบ",
};

const CONFIRM: Record<FixMode, string> = {
  reverse: "ยืนยัน ลงใบกลับรายการ",
  void: "ยืนยัน ยกเลิกใบนี้",
};

/**
 * สิ่งที่หน้าจอต้องวาด — คำนวณจาก state + ตัวรายการ + สิทธิ์
 *
 * `offerReverse = false` สำหรับใบที่เป็นใบกลับรายการอยู่แล้ว (กลับซ้อนชั้นไม่ได้
 * ดูเหตุผลที่ `src/lib/db/reverse-entry.ts`) แต่ยัง `offerVoid` ได้ เพราะ D-097
 * เปิดทางให้ยกเลิกใบกลับรายการที่ลงผิดไว้โดยตั้งใจ (ไม่ใช่ทางตัน)
 */
export function panelView(s: PanelState, entry: PanelEntry, permissions: ReadonlySet<string>): PanelView {
  const allowed = permissions.has("txn.void");
  const isReversal = entry.source === "reverse" || entry.reversesId !== null;
  // ลงใบใหม่ต้องมีสิทธิ์เข้าสมุดด้วย (RLS `txn_insert`) — ยกเลิกใบไม่ต้อง
  const offerReverse = allowed && permissions.has("ledger.approve") && !isReversal;
  const offerVoid = allowed;

  const trimmed = s.reason.trim();
  const reasonError =
    s.step === "idle" || s.step === "done" || trimmed.length >= MIN_REASON_LEN
      ? null
      : `เขียนเหตุผลให้ครบอย่างน้อย ${MIN_REASON_LEN} ตัวอักษร (เช่น "ลงผิดห้อง ที่ถูกคือห้อง 2") — คำว่า "ผิด" เพียงคำเดียวตอบผู้สอบบัญชีไม่ได้`;

  const notice = !allowed
    ? "บัญชีนี้ไม่มีสิทธิ์แก้รายการที่บันทึกเข้าสมุดแล้ว — ถ้าใบนี้ลงผิด ให้แจ้งผู้ที่มีสิทธิ์ยกเลิก/กลับรายการ"
    : isReversal
      ? "ใบนี้เป็นใบกลับรายการอยู่แล้ว จึงกลับรายการซ้อนอีกชั้นไม่ได้ — ถ้าใบนี้ลงผิด ให้ยกเลิก (void) ใบนี้ แล้วลงรายการที่ถูกใหม่"
      : null;

  return {
    step: s.step,
    mode: s.mode,
    reason: s.reason,
    busy: s.busy,
    result: s.result,
    allowed,
    offerReverse,
    offerVoid,
    showReason: s.step === "reason" || s.step === "confirm",
    reasonError,
    canAskConfirm: s.step === "reason" && reasonError === null && !s.busy,
    canSubmit: s.step === "confirm" && !s.busy && s.mode !== null,
    explain: s.mode === null ? null : EXPLAIN[s.mode],
    confirmText: s.mode === null ? null : CONFIRM[s.mode],
    notice,
  };
}
