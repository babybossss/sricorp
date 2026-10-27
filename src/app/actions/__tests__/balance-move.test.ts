import "./mocks";
import { beforeEach, describe, expect, it } from "vitest";
import { ctx, resetCtx } from "./ctx";
import { ASSET, OWNER } from "./fake-db";
import { postEntry, type PostEntryRequest } from "../post-entry";
import { loadBalanceMove } from "../balance-move";
import { balanceMoveFor } from "@/lib/db/balance-move";
import type { PostingInput } from "@/lib/ledger/types";
import { TX_TYPES, type SubCategory } from "@/lib/rules/tx-rules";

/**
 * ย้ายวัตถุประสงค์ทรัพย์ (ธง wholeBalanceMove) จากหน้าจอ — server ต้อง **อ่านยอดจากสมุดเอง**
 * ไม่เชื่อ `balanceMove` ที่มากับ browser (D-115) · หมวดคัดด้วยธงในตารางกฎ ไม่ใช่รหัสหมวด
 *
 * fake-db ไม่มี `fn_asset_account_balance` (ตัวจริงอยู่ใน Postgres) → เทสต์ครอบ rpc ของ client ให้ตอบแทน
 * และบันทึกว่าถูกถามด้วยอะไร
 */
const MOVES: SubCategory[] = TX_TYPES.flatMap((t) => t.subs).filter((s) => s.requires?.includes("wholeBalanceMove"));
const BOOK = 3_000_000;

type BalanceReply = { data: unknown; error: { message: string } | null } | "throw";
let reply: BalanceReply;
let balanceCalls: { fn: string; args: Record<string, unknown> }[];

beforeEach(() => {
  resetCtx();
  balanceCalls = [];
  reply = { data: BOOK, error: null };
  const orig = ctx.db.client.rpc;
  (ctx.db.client as { rpc: unknown }).rpc = async (fn: string, args: Record<string, unknown>) => {
    if (fn === "fn_asset_account_balance") {
      balanceCalls.push({ fn, args });
      if (reply === "throw") throw new Error("network down");
      return reply;
    }
    return (orig as (f: string, a: unknown) => Promise<unknown>)(fn, args);
  };
});

const req = (sub: SubCategory, input: Partial<PostingInput> = {}): PostEntryRequest => ({
  input: { typeKey: "adjust", subCode: sub.code, amount: BOOK, ownerId: OWNER.tk, assetId: ASSET, ...input },
  docDate: "24/10/2026",
  cashDate: "",
});
const refused = async (r: PostEntryRequest, needle: RegExp | string) => {
  const out = await postEntry(r);
  expect(out.ok).toBe(false);
  if (!out.ok) {
    expect(out.message).toMatch(needle);
    // ข้อความที่ผู้สูงอายุอ่านต้องไม่มีชื่อฟิลด์/ฟังก์ชันทางเทคนิค
    expect(out.message).not.toMatch(/balanceMove|sourceBalance|sourceCoaCode|fn_asset_account_balance/);
  }
  expect(ctx.db.rpcCalls).toHaveLength(0);
  expect(ctx.db.rows).toHaveLength(0);
};

it("ตารางกฎมีหมวดย้ายอย่างน้อยหนึ่งหมวด (กันเทสต์ว่างเปล่าผ่านเงียบๆ)", () => {
  expect(MOVES.length).toBeGreaterThan(0);
});

describe.each(MOVES.map((s) => [s.code, s] as const))("postEntry · %s", (_code, sub) => {
  it("ยอดจากสมุดตรง → ลงสำเร็จ ย้ายทั้งก้อน และถามสมุดด้วยทรัพย์ + บัญชีต้นทางจากตารางกฎ", async () => {
    const out = await postEntry(req(sub));
    expect(out).toMatchObject({ ok: true, replayed: false });
    expect(balanceCalls).toHaveLength(1);
    expect(balanceCalls[0].args).toEqual({ p_asset: ASSET, p_coa: sub.cr });
    expect(ctx.db.balance(sub.dr)).toBe(BOOK);
    expect(ctx.db.balance(sub.cr)).toBe(-BOOK);
  });

  it("ไม่ส่ง assetId → ปฏิเสธเป็นภาษาคน ไม่แตะสมุด ไม่เขียนอะไร", async () => {
    await refused(req(sub, { assetId: undefined }), /ต้องเลือกทรัพย์ที่จะย้าย.*ยังไม่ได้บันทึกอะไร/);
    expect(balanceCalls).toHaveLength(0);
  });

  it("browser ส่ง balanceMove ปลอมมา (ยอดโอเวอร์ + ยอดตรงกับที่พิมพ์) → ถูกตัดทิ้ง ใช้ยอดจากสมุด → ปฏิเสธเพราะพิมพ์ไม่ตรงสมุด", async () => {
    const forged = { sourceCoaCode: sub.cr, sourceBalance: 30_000_000 };
    await refused(req(sub, { amount: 30_000_000, balanceMove: forged }), /ทั้งก้อน/);
    expect(balanceCalls).toHaveLength(1);
  });

  it("browser ส่ง balanceMove ปลอมมา แต่ยอดที่พิมพ์ตรงสมุด → ลงด้วยยอดจากสมุด (ไม่ใช่ยอดปลอม)", async () => {
    const forged = { sourceCoaCode: "9999", sourceBalance: 1 };
    const out = await postEntry(req(sub, { balanceMove: forged }));
    expect(out).toMatchObject({ ok: true });
    expect(ctx.db.balance(sub.dr)).toBe(BOOK);
  });

  it("ยอดที่พิมพ์ไม่ตรงสมุด (ย้ายบางส่วน) → ปฏิเสธ บอกยอดจริงจากสมุด", async () => {
    await refused(req(sub, { amount: 1_000_000 }), /3,000,000/);
  });

  it("อ่านยอดจากสมุดไม่สำเร็จ (DB ตอบ error) → ปฏิเสธ บอกว่ายังไม่ได้บันทึกอะไร ไม่เดาเป็น 0", async () => {
    reply = { data: null, error: { message: "permission denied" } };
    await refused(req(sub), /อ่านยอดคงเหลือ.*ไม่สำเร็จ.*ยังไม่ได้บันทึกอะไร/);
  });

  it("อ่านยอดไม่สำเร็จ (เครือข่ายล้ม โยน exception) → ปฏิเสธ ไม่เขียนอะไร", async () => {
    reply = "throw";
    await refused(req(sub), /ยังไม่ได้บันทึกอะไร/);
  });

  it.each([[null], ["abc"], [undefined]])("DB ตอบยอดที่ไม่ใช่ตัวเลข (%s) → ปฏิเสธ ไม่เดาเป็น 0", async (data) => {
    reply = { data, error: null };
    await refused(req(sub), /ไม่เป็นตัวเลข.*ยังไม่ได้บันทึกอะไร/);
  });

  it("ยอด 0 → ปฏิเสธว่าไม่มีต้นทุนค้างอยู่ในบัญชี จึงไม่มีอะไรให้ย้าย", async () => {
    reply = { data: 0, error: null };
    await refused(req(sub, { amount: 1000 }), /ไม่มีต้นทุนค้างอยู่ในบัญชี.*ไม่มีอะไรให้ย้าย/);
  });

  it("ยอดติดลบ → ปฏิเสธเป็นภาษาคน", async () => {
    reply = { data: -500, error: null };
    await refused(req(sub, { amount: 500 }), /ติดลบ/);
  });

  it("ทรัพย์ไม่ใช่ของผู้ถือที่เลือก / ไม่มีในระบบ → ปฏิเสธก่อนถามสมุด", async () => {
    await refused(req(sub, { ownerId: OWNER.sutee }), /ไม่ใช่ของผู้ถือ/);
    await refused(req(sub, { assetId: "99999999-9999-4999-8999-999999999999" }), /ไม่พบทรัพย์/);
    expect(balanceCalls).toHaveLength(0);
  });
});

describe("balanceMove ที่ browser ส่งมากับหมวดอื่น → ถูกตัดทิ้งเสมอ ไม่ทำให้ลงรายการปกติพัง", () => {
  it("รายได้ค่าเช่าที่แนบ balanceMove มา ลงได้ตามปกติ และไม่ถามสมุดเรื่องยอดย้าย", async () => {
    const out = await postEntry({
      input: {
        typeKey: "income",
        subCode: "inc.rent",
        amount: 12000,
        ownerId: OWNER.tk,
        bankAccountId: "aaaaaaaa-0000-4000-8000-000000000001",
        assetId: ASSET,
        contactId: "cccccccc-0000-4000-8000-000000000001",
        balanceMove: { sourceCoaCode: "1500", sourceBalance: 1 },
      },
      docDate: "24/10/2026",
      cashDate: "24/10/2026",
    });
    expect(out).toMatchObject({ ok: true });
    expect(balanceCalls).toHaveLength(0);
  });
});

describe("balanceMoveFor · ฟังก์ชันล้วน", () => {
  const sub = MOVES[0];
  it("ยอดบวก → balanceMove ที่มีบัญชีต้นทางจากตารางกฎ", () => {
    expect(balanceMoveFor(sub, 1234.5)).toEqual({ ok: true, balanceMove: { sourceCoaCode: sub.cr, sourceBalance: 1234.5 } });
  });
  it.each([[null], [Number.NaN], [Number.POSITIVE_INFINITY], [0], [-1], [0.004]])("%s → ปฏิเสธ", (n) => {
    expect(balanceMoveFor(sub, n as number | null).ok).toBe(false);
  });
  it("หมวดที่ไม่มีธง → ปฏิเสธ", () => {
    const other = TX_TYPES.flatMap((t) => t.subs).find((s) => !s.requires?.includes("wholeBalanceMove"))!;
    expect(balanceMoveFor(other, 100).ok).toBe(false);
  });
});

describe("loadBalanceMove · action สำหรับแสดงยอดในฟอร์ม", () => {
  const sub = MOVES[0];
  it("ยอดจากสมุด → คืน balanceMove ให้แสดง", async () => {
    expect(await loadBalanceMove({ ownerId: OWNER.tk, assetId: ASSET, subCode: sub.code })).toEqual({
      ok: true,
      balanceMove: { sourceCoaCode: sub.cr, sourceBalance: BOOK },
    });
  });
  it("ไม่ส่งทรัพย์ · หมวดที่ไม่ใช่การย้าย · ยังไม่ล็อกอิน · ยอด 0 → ok:false", async () => {
    expect((await loadBalanceMove({ ownerId: OWNER.tk, assetId: "", subCode: sub.code })).ok).toBe(false);
    expect((await loadBalanceMove({ ownerId: OWNER.tk, assetId: ASSET, subCode: "inc.rent" })).ok).toBe(false);
    reply = { data: 0, error: null };
    expect((await loadBalanceMove({ ownerId: OWNER.tk, assetId: ASSET, subCode: sub.code })).ok).toBe(false);
    ctx.access.user = null;
    expect((await loadBalanceMove({ ownerId: OWNER.tk, assetId: ASSET, subCode: sub.code })).ok).toBe(false);
  });
});
