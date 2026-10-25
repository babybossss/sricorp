import "./mocks";
import { beforeEach, describe, expect, it } from "vitest";
import { ctx, resetCtx } from "./ctx";
import { ASSET, BANK, CONTACT, OWNER } from "./fake-db";
import { postEntry, type PostEntryRequest } from "../post-entry";
import type { PostingInput } from "@/lib/ledger/types";
import { TX_TYPES, accrualCheck, movesCash } from "@/lib/rules/tx-rules";

const rentPaid: PostingInput = {
  typeKey: "income",
  subCode: "inc.rent",
  amount: 12000,
  ownerId: OWNER.tk,
  bankAccountId: BANK.tk,
  assetId: ASSET,
  contactId: CONTACT,
};
/** ไฟล์หลักฐานที่ "อัปโหลดจริง" ของผู้ถือ — path รูปแบบเดียวกับ Storage (ผ่านด่านนิติบุคคลของ engine) */
const evidence = (ownerId: string, n = 1) =>
  `${ownerId}/cccccccc-3333-4333-8333-cccccccccccc/dddddddd-4444-4444-8444-${String(n).padStart(12, "0")}.pdf`;
const req = (over: Partial<PostEntryRequest> = {}, input: Partial<PostingInput> = {}): PostEntryRequest => ({
  input: { ...rentPaid, ...input },
  docDate: "24/10/2026",
  cashDate: "24/10/2026",
  ...over,
});
const refused = async (r: PostEntryRequest | undefined, needle: RegExp | string) => {
  const out = await postEntry(r as PostEntryRequest);
  expect(out.ok).toBe(false);
  if (!out.ok) expect(out.message).toMatch(needle);
  // ปฏิเสธทุกเคสต้อง "ไม่เขียนอะไรลง DB" — ไม่ใช่แค่ตอบว่าไม่ผ่าน
  expect(ctx.db.rpcCalls).toHaveLength(0);
  expect(ctx.db.rows).toHaveLength(0);
};

beforeEach(resetCtx);

describe("postEntry · เส้นทางที่ข้อมูลครบ", () => {
  it("รายการที่จ่ายแล้ว: เขียนผ่าน fn_post_entry ครั้งเดียว ได้ id คืน และสมุดมีรายการนั้น", async () => {
    const out = await postEntry(req());
    expect(out).toMatchObject({ ok: true, replayed: false });
    expect(ctx.db.rpcCalls).toHaveLength(1);
    expect(ctx.db.rpcCalls[0]).toMatchObject({ txn_type_code: "inc.rent", doc_date: "2026-10-24", cash_date: "2026-10-24" });
    expect(ctx.db.balance("1100")).toBe(12000);
    expect(ctx.db.balance("4200")).toBe(-12000);
  });

  it("กดซ้ำคำขอเดิม → DB ตอบ replay และสมุดไม่เพิ่ม", async () => {
    await postEntry(req());
    const again = await postEntry(req());
    expect(again).toMatchObject({ ok: true, replayed: true });
    expect(ctx.db.balance("1100")).toBe(12000);
  });
});

describe("postEntry · ข้อมูลขาด ต้องปฏิเสธ ไม่ตกไปเส้นทางปกติ (บทเรียนข้อ 3)", () => {
  it("ไม่ส่งคำขอเลย / ไม่ส่ง input", async () => {
    await refused(undefined, /ไม่ได้รับข้อมูล/);
    await refused({ docDate: "24/10/2026", cashDate: "" } as unknown as PostEntryRequest, /ไม่ได้รับข้อมูล/);
  });

  it("ไม่ได้ล็อกอิน · ตรวจสิทธิ์ล้ม · ไม่มีสิทธิ์อนุมัติเข้าสมุด", async () => {
    ctx.access.user = null;
    await refused(req(), /หมดอายุ/);
    resetCtx();
    ctx.access.error = "boom";
    await refused(req(), /ตรวจสิทธิ์ไม่สำเร็จ/);
    resetCtx();
    ctx.access.permissions = new Set(["txn.create"]);
    await refused(req(), /ลงสมุดบัญชีโดยตรงไม่ได้/);
  });

  it("ไม่ส่งวันที่เอกสาร / วันที่ไม่จริง / ปี พ.ศ.", async () => {
    await refused(req({ docDate: "" }), /วันที่เอกสารอ่านไม่ออก/);
    await refused(req({ docDate: "31/02/2026" }), /วันที่เอกสารอ่านไม่ออก/);
    await refused(req({ docDate: "24/10/2569" }), /วันที่เอกสารอ่านไม่ออก/);
  });

  it("มีบรรทัดเงินสดแต่ไม่ส่งวันที่เงินจริง · ส่งมาแต่อ่านไม่ออก", async () => {
    await refused(req({ cashDate: "" }), /ต้องระบุวันที่เงินเข้า\/ออกจริง/);
    await refused(req({ cashDate: "เมื่อวาน" }), /วันที่เงินเข้า\/ออกจริงอ่านไม่ออก/);
  });

  it("ไม่ส่งบัญชีทั้งที่เงินเคลื่อนจริง → engine ปฏิเสธ", async () => {
    await refused(req({}, { bankAccountId: undefined }), /บัญชี/);
  });

  it("ไม่ส่งผู้ติดต่อ/ทรัพย์ที่หมวดบังคับ → engine ปฏิเสธ", async () => {
    await refused(req({}, { contactId: undefined }), /./);
    await refused(req({}, { assetId: undefined }), /./);
  });

  it("ผู้ถือที่ DB ไม่รู้จัก · ข้อมูลอ้างอิงโหลดไม่ได้ → ปฏิเสธ", async () => {
    await refused(req({}, { ownerId: "99999999-9999-4999-8999-999999999999", bankAccountId: BANK.tk }), /./);
    ctx.reference = { ok: false, error: "db down" };
    await refused(req(), /โหลดข้อมูลผู้ถือและบัญชีจากฐานข้อมูลไม่ได้/);
  });
});

describe("postEntry · ธง reversal ที่ browser ส่งมาต้องถูกตัดทิ้ง", () => {
  it("ลงรายการใหม่เข้าบัญชีที่ปิดแล้วไม่ได้ แม้ browser แนบ reversal: true มา (D-092)", async () => {
    const r = req({}, { bankAccountId: BANK.tkClosed, reversal: true });
    await refused(r, /ปิดใช้งานแล้ว/);
  });

  it("เทียบกับไม่แนบธง: ผลเหมือนกัน (ธงไม่เปลี่ยนอะไรเลย)", async () => {
    await refused(req({}, { bankAccountId: BANK.tkClosed }), /ปิดใช้งานแล้ว/);
  });
});

describe("postEntry · ผู้ถือที่ยังไม่จดทะเบียน (planned) ห้ามเป็นเจ้าของรายการ", () => {
  it("ทางช่อง owner_id", async () => {
    // แนบหลักฐานครบ + คู่ค้าครบ เพื่อให้ engine ผ่าน — เหลือด่านผู้ถือเป็นเหตุเดียวที่ปฏิเสธ
    // (เทสต์ที่ถูกปฏิเสธเพราะเหตุอื่นจะ "ผ่าน" ทั้งที่ด่านนี้พัง)
    await refused(
      req({}, { ownerId: OWNER.planned, bankAccountId: BANK.planned, attachments: [evidence(OWNER.planned)] }),
      /ยังไม่ได้จดทะเบียน/
    );
  });

  it("ทางช่อง counter_owner_id — ปลายทางที่ engine หามาจากบัญชีเอง ไม่ใช่ช่องที่ผู้ใช้กรอก", async () => {
    const transfer = req(
      {},
      {
        typeKey: "transfer",
        subCode: "trf.internal",
        amount: 5000,
        ownerId: OWNER.corp,
        bankAccountId: BANK.corp,
        assetId: undefined,
        contactId: CONTACT,
        transferToBankAccountId: BANK.planned,
        intercompanyNature: "loan",
        attachments: [evidence(OWNER.corp), evidence(OWNER.planned, 2)],
      }
    );
    await refused(transfer, /ยังไม่ได้จดทะเบียน/);
  });

  it("ผู้ถือที่ active ทั้งสองฝั่ง: ข้ามผู้ถือส่งครบสองก้อนในคำเรียกเดียว", async () => {
    const out = await postEntry(
      req(
        {},
        {
          typeKey: "transfer",
          subCode: "trf.internal",
          amount: 5000,
          ownerId: OWNER.tk,
          bankAccountId: BANK.tk,
          assetId: undefined,
          contactId: undefined,
          transferToBankAccountId: BANK.sutee,
          intercompanyNature: "loan",
        }
      )
    );
    expect(out.ok).toBe(true);
    expect(ctx.db.rpcCalls).toHaveLength(1);
    expect(ctx.db.rpcCalls[0].transactions).toHaveLength(2);
  });
});

describe("postEntry · error จาก DB ต้องถึงผู้ใช้ ไม่ถูกกลืนเป็นสำเร็จ", () => {
  it("DB ปฏิเสธด้วยข้อความไทย → ส่งต่อตามเดิม", async () => {
    ctx.db.control.rpcError = { message: "บันทึกรายการไม่ได้: งวดนี้ปิดแล้ว", code: "P0001" };
    const out = await postEntry(req());
    expect(out).toEqual({ ok: false, message: "บันทึกรายการไม่ได้: งวดนี้ปิดแล้ว" });
  });

  it("RLS ปฏิเสธ (ข้อความอังกฤษ) → แปลเป็นเรื่องสิทธิ์", async () => {
    ctx.db.control.rpcError = { message: 'new row violates row-level security policy for table "transactions"', code: "42501" };
    const out = await postEntry(req());
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/ไม่มีสิทธิ์/);
  });

  it("DB ไม่คืน id ครบทั้งที่ไม่ error → ไม่ตอบว่าสำเร็จ", async () => {
    ctx.db.control.rpcData = { transaction_ids: [], replayed: false };
    const out = await postEntry(req());
    expect(out.ok).toBe(false);
    ctx.db.control.rpcData = null;
    expect((await postEntry(req())).ok).toBe(false);
  });
});

describe("postEntry · หมวดที่เส้นทางนี้ยังต่อไม่ครบ", () => {
  it("สัญญากู้ (loanTerms) และขายทรัพย์ (capitalGain) ถูกกั้น ไม่บันทึกครึ่งเดียว", async () => {
    await refused(
      req({}, { typeKey: "finance_in", subCode: "fin.loan_director", amount: 70000, assetId: undefined }),
      /ยังบันทึกจริงไม่ได้/
    );
  });
});

describe("postEntry · ตั้งค้างรับ-ค้างจ่าย (ด่านชั่วคราวถูกถอดแล้ว เพราะหน้ายืนยันล้างลง DB ได้ — ดู confirm-cash.test.ts)", () => {
  it("หมวดที่ตั้งค้างได้ → ลงลูกหนี้ ไม่มี cash_date และไม่แตะเงินสด", async () => {
    const out = await postEntry(req({ cashDate: "" }, { bankAccountId: undefined, notYetPaid: true }));
    expect(out.ok).toBe(true);
    expect(ctx.db.rpcCalls[0].cash_date).toBeNull();
    expect(ctx.db.balance("1200")).toBe(12000);
    expect(ctx.db.balance("1100")).toBe(0);
  });

  it("หมวดที่ล้างไม่ได้ (ตารางกฎไม่มีทางล้าง) ยังถูกปฏิเสธ — ตั้งค้างแล้วล้างไม่ออกคือรายได้นับซ้ำ", async () => {
    const stuck = TX_TYPES.flatMap((t) => t.subs.map((s) => ({ t, s }))).find(
      ({ s }) => movesCash(s) && !accrualCheck(s).ok && !s.requires?.includes("loanTerms") && !s.requires?.includes("capitalGain")
    );
    expect(stuck, "ต้องมีอย่างน้อยหนึ่งหมวดที่ตั้งค้างไม่ได้ ไม่งั้นเทสต์นี้ไม่ได้ตรวจอะไร").toBeDefined();
    const { t, s } = stuck!;
    const before = ctx.db.rpcCalls.length;
    const out = await postEntry(
      req({ cashDate: "" }, { typeKey: t.key, subCode: s.code, bankAccountId: undefined, notYetPaid: true, assetId: ASSET, contactId: CONTACT })
    );
    expect(out.ok).toBe(false);
    expect(ctx.db.rpcCalls).toHaveLength(before);
  });
});

describe("postEntry · ผู้เช่าหักภาษี ณ ที่จ่าย (D-111)", () => {
  const withWht = { rate: 5, amount: 5000, certificateNo: "WHT-001" };

  it("ค่าเช่า 100,000 หัก 5,000: เงินเข้า 95,000 + ภาษีรอเครดิต 5,000 รายได้เต็ม 100,000 และส่ง wht_* ที่หัวรายการ", async () => {
    const out = await postEntry(req({}, { amount: 100000, wht: withWht }));
    expect(out.ok, JSON.stringify(out)).toBe(true);
    expect(ctx.db.rpcCalls[0]).toMatchObject({ wht_rate: 5, wht_amount: 5000, wht_certificate_no: "WHT-001" });
    expect(ctx.db.balance("1100")).toBe(95000);
    expect(ctx.db.balance("1800")).toBe(5000);
    expect(ctx.db.balance("4200")).toBe(-100000);
  });

  it("กรอกยอดสุทธิ 95,000 ในช่องจำนวนเงิน → engine ปฏิเสธ ไม่ลงรายได้ต่ำกว่าจริง", async () => {
    await refused(req({}, { amount: 95000, wht: withWht }), /ยอดเต็ม/);
  });

  it("ส่งข้อมูลภาษีมากับหมวดที่หักไม่ได้ (รายจ่าย) → ปฏิเสธ ไม่เมินทิ้ง", async () => {
    await refused(
      req({}, { typeKey: "expense", subCode: "exp.common", amount: 100000, wht: withWht }),
      /ถูกหักภาษี ณ ที่จ่ายไม่ได้/
    );
  });

  it("ข้อมูลภาษีไม่ครบ (ไม่มียอด / ไม่มีอัตรา) → ปฏิเสธ ไม่เดา", async () => {
    await refused(req({}, { amount: 100000, wht: { rate: 5, amount: 0 } }), /ภาษี/);
    await refused(req({}, { amount: 100000, wht: { rate: 0, amount: 5000 } }), /อัตรา/);
  });

  it("ตั้งค้างพร้อมถูกหักภาษีไม่ได้ (ยังไม่มีใครหัก)", async () => {
    await refused(
      req({ cashDate: "" }, { amount: 100000, notYetPaid: true, bankAccountId: undefined, wht: withWht }),
      /ยังไม่ได้รับเงิน/
    );
  });
});

describe("postEntry · แปลงค่า/แลกเงินตรา: ข้อมูลที่ต้องอ่านจากสมุดไม่เชื่อ browser (เส้นทางเต็มกับ Postgres จริงอยู่ที่ fx-posting.pg.test.ts)", () => {
  const FCD = "aaaaaaaa-0000-4000-8000-0000000000f1";
  const fxReq = (over: Partial<PostEntryRequest> = {}, input: Partial<PostingInput> = {}): PostEntryRequest => ({
    input: { typeKey: "transfer", subCode: "trf.fx_translate_up", amount: 5000, ownerId: OWNER.tk, bankAccountId: FCD, ...input },
    docDate: "30/11/2026",
    cashDate: "30/11/2026",
    ...over,
  });
  const seedFcd = () => {
    if (ctx.reference.ok) {
      ctx.reference.ref.banks.push({ id: FCD, ownerId: OWNER.tk, name: "ธนากร FCD", bank: "BBL", last4: null, isActive: true, sortOrder: 9, currency: "USD" });
    }
    ctx.db.tables.fx_rates.push({ currency: "USD", rate_date: "2026-11-30", thb_per_unit: 37 });
  };

  it("ไม่ส่ง fx (ไม่ได้เลือกอัตรา) → ปฏิเสธ ไม่เรียก DB เขียนอะไร", async () => {
    seedFcd();
    await refused(fxReq(), /ต้องเลือกอัตรา/);
  });

  it("ไม่เลือกบัญชีเงินตรา → ปฏิเสธ", async () => {
    seedFcd();
    await refused(fxReq({ fx: { newRateDate: "2026-11-30" } }, { bankAccountId: "" }), /เลือกบัญชีเงินตรา/);
  });

  it("บัญชีบาทแต่ขอแปลงค่า → ปฏิเสธ (บัญชีบาทไม่มีเงินตราให้แปลง)", async () => {
    seedFcd();
    await refused(fxReq({ fx: { newRateDate: "2026-11-30" } }, { bankAccountId: BANK.tk }), /เป็นบัญชีบาท/);
  });

  it("บัญชีว่าง (ไม่มีเงินตราคงเหลือในสมุด) → ปฏิเสธ ไม่เดาว่ามี", async () => {
    seedFcd();
    await refused(fxReq({ fx: { newRateDate: "2026-11-30" } }), /ไม่มีUSDคงเหลือ|ไม่มี.*คงเหลือในสมุด/);
  });

  it("ส่ง fxTranslation/fxConversion มากับหมวดธรรมดา → ถูกตัดทิ้ง ไม่ใช่ปฏิเสธ/เชื่อ (ค่านี้ผู้เรียกกรอกได้ ด่านเชื่อไม่ได้)", async () => {
    const forged = req({}, {
      fxTranslation: { currency: "USD", balanceOriginal: 1e9, bookRateToThb: 1, bookRateDate: "2026-01-01", newRateToThb: 99, newRateDate: "2026-01-02" },
      fxConversion: { currency: "USD", amountOriginal: 1, balanceOriginalBefore: 1, bookRateToThb: 1, bookRateDate: "2026-01-01", dealRateToThb: 1, dealRateDate: "2026-01-01", unrealizedBefore: 0 },
    });
    const out = await postEntry(forged);
    expect(out.ok, JSON.stringify(out)).toBe(true);
    expect(ctx.db.balance("1100")).toBe(12000);
  });

  it("ไม่มีสิทธิ์ลงสมุด → ปฏิเสธก่อนอ่านสมุด", async () => {
    seedFcd();
    ctx.access.permissions = new Set(["txn.create"]) as never;
    await refused(fxReq({ fx: { newRateDate: "2026-11-30" } }), /ลงสมุดบัญชีโดยตรงไม่ได้/);
  });
});
