/**
 * กลับรายการ / ยกเลิกใบ **ผ่าน action ตัวจริง กับ Postgres จริง** (role `authenticated` · RLS บังคับ)
 *
 * ด่านที่พิสูจน์ที่นี่ไม่ใช่สำเนาในเทสต์ แต่เป็น trigger จริงของ D-097/D-098:
 *   `fn_reverse_link_ok` · `fn_assert_reverse_mirrors` · `fn_void_is_terminal` ·
 *   `fn_void_blocked_by_reverse` · `fn_corporate_evidence_ok` · `fn_assert_intercompany_pair`
 *
 * **ไม่แตะ Supabase project จริง** — DB ชั่วคราวในเครื่อง สร้างจาก migration ทุกไฟล์ตามลำดับ
 *
 * เทสต์ท้ายไฟล์ (ข (ก)) **ไม่ใช่เทสต์ของความถูกต้อง** แต่เป็นเทสต์ที่ **ตรึงข้อจำกัดของ schema วันนี้**
 * ว่ารายการข้ามผู้ถือยังกลับรายการไม่ได้จริง (ทั้งสองวิธีที่คิดได้) → ถ้าวันหนึ่งมี migration
 * ย้าย `reverses_id` ไปอยู่ระดับใบ เทสต์นั้นจะแดงและเป็นสัญญาณให้ปลดด่านในแอป
 */
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createTestDb, pgAvailable, type TestDb } from "@/lib/db/import/__tests__/pg-harness";
import { pgClient } from "@/lib/db/import/__tests__/pg-client";

const h = vi.hoisted(() => ({ client: null as unknown, perms: new Set<string>(), uid: "" }));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => h.client }));
vi.mock("@/lib/auth/session", () => ({
  getAccess: async () => ({ user: { id: h.uid, email: "rev@local" }, permissions: h.perms, profile: null, error: null }),
}));

import { postEntry, type PostEntryRequest } from "../post-entry";
import { reverseEntry, voidEntry } from "../reverse-entry";
import { findSub } from "@/lib/rules/tx-rules";

const UID = "0000000e-0000-4000-8000-0000000000e1";
const DAY = "20/10/2026";

describe.skipIf(!pgAvailable)("กลับรายการ / ยกเลิกใบ ผ่าน action → Postgres จริง", { timeout: 180_000 }, () => {
  let db: TestDb;
  let bankTk = "";
  let bankCorp = "";
  let bankSutee = "";
  let assetId = "";
  let contactId = "";
  let evidencePath = "";
  const tk = () => db.su(`select id from sri_os.owners where code='THANAKORN'`);
  const corp = () => db.su(`select id from sri_os.owners where code='SRI_CORP'`);

  /** ยอดสุทธิ (เดบิต − เครดิต) ของบัญชีหนึ่งในสมุดที่ **นับในงบ** (`v_ledger_posted`) */
  const net = (coa: string, ownerId?: string) =>
    db.num(
      `select coalesce(sum(v.debit - v.credit), 0) from sri_os.v_ledger_posted v
         join sri_os.chart_of_accounts c on c.id = v.coa_id
        where c.code = '${coa}' ${ownerId ? `and v.owner_id = '${ownerId}'` : ""}`
    );
  const head = (id: string) =>
    db.rows<{ status: string; source: string; reverses_id: string | null; cash_date: string | null; void_reason: string | null }>(
      `select status::text, source::text, reverses_id::text, cash_date::text, void_reason from sri_os.transactions where id = '${id}'`
    )[0];

  const rentPaid = (over: Partial<PostEntryRequest["input"]> = {}): PostEntryRequest => ({
    input: {
      typeKey: findSub("inc.rent")!.type.key,
      subCode: "inc.rent",
      amount: 30000,
      ownerId: tk(),
      bankAccountId: bankTk,
      assetId,
      contactId,
      ...over,
    },
    docDate: DAY,
    cashDate: DAY,
  });
  const mustPost = async (r: PostEntryRequest) => {
    const out = await postEntry(r);
    expect(out.ok, JSON.stringify(out)).toBe(true);
    return (out as { transactionIds: string[] }).transactionIds;
  };

  beforeAll(async () => {
    db = createTestDb();
    h.uid = UID;
    h.perms = new Set(["ledger.approve", "txn.create", "txn.void"]);
    h.client = pgClient(db, UID);
    db.su(`
      insert into auth.users(id) values ('${UID}');
      insert into sri_os.app_users(id, email, display_name, role, is_active) values ('${UID}', 'rev@local', 'mgmt', 'management', true);
      insert into sri_os.user_owner_access(user_id, owner_id) select '${UID}', id from sri_os.owners;
      insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name)
        select id, 'BBL', 'ธนากร', 'tk-thb' from sri_os.owners where code = 'THANAKORN';
      insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name)
        select id, 'SCB', 'SRI Corp', 'corp-thb' from sri_os.owners where code = 'SRI_CORP';
      insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name)
        select id, 'TTB', 'สุธี', 'sutee-thb' from sri_os.owners where code = 'SUTEE';
      insert into sri_os.assets(code, name, class_id, category_id, owner_id, currency)
        select 'CONDO-R1', 'คอนโดห้องกลับรายการ', ct.class_id, ct.id, (select id from sri_os.owners where code='THANAKORN'), 'THB'
          from sri_os.asset_categories ct where ct.code = 'RE_RENTAL';
      insert into sri_os.contacts(first_name, last_name, types) values ('ผู้เช่า', 'ทดสอบ', array['tenant']);
      insert into storage.buckets(id, name) values ('attachments', 'attachments') on conflict do nothing;
    `);
    bankTk = db.su(`select id from sri_os.bank_accounts where display_name='tk-thb'`);
    bankCorp = db.su(`select id from sri_os.bank_accounts where display_name='corp-thb'`);
    bankSutee = db.su(`select id from sri_os.bank_accounts where display_name='sutee-thb'`);
    assetId = db.su(`select id from sri_os.assets where code='CONDO-R1'`);
    contactId = db.su(`select id from sri_os.contacts limit 1`);
    // ไฟล์หลักฐานจริงของนิติบุคคล (รูป path <owner>/<uploader>/<uuid>.pdf · ต้องมีแถวใน bucket)
    evidencePath = `${corp()}/${UID}/cccccccc-5555-4555-8555-cccccccccccc.pdf`;
    db.su(`insert into storage.objects(bucket_id, name, owner) values ('attachments', '${evidencePath}', '${UID}');`);
  }, 300_000);

  afterAll(() => db?.drop());

  it("กลับรายการค่าเช่า: DB รับใบใหม่ · ยอดทุกบัญชีสุทธิเป็นศูนย์ · ต้นฉบับยัง posted", async () => {
    const [id] = await mustPost(rentPaid());
    expect(net("1100", tk())).toBe(30000);

    const out = await reverseEntry({ transactionId: id, reason: "ลงผิดห้อง" });
    expect(out.ok, JSON.stringify(out)).toBe(true);
    const revId = (out as { transactionIds: string[] }).transactionIds[0];

    expect(net("1100", tk())).toBe(0);
    expect(net("4200", tk())).toBe(0);
    expect(head(id).status).toBe("posted"); // ไม่ลบ ไม่ซ่อน
    const rev = head(revId);
    expect(rev.source).toBe("reverse");
    expect(rev.reverses_id).toBe(id);
    expect(rev.cash_date).not.toBeNull(); // มีบรรทัดเงินสด → ต้องมีวันที่เงินเคลื่อน
    expect(db.num(`select count(*) from sri_os.transactions where reverses_id = '${id}'`)).toBe(1);
  });

  it("กลับรายการใบเดียวกันรอบสอง → ถูกปฏิเสธ และไม่มีใบใหม่เกิดขึ้น", async () => {
    const [id] = await mustPost(rentPaid({ amount: 11000 }));
    expect((await reverseEntry({ transactionId: id, reason: "รอบแรก" })).ok).toBe(true);
    const before = db.num("select count(*) from sri_os.transactions");

    const again = await reverseEntry({ transactionId: id, reason: "รอบสอง" });
    expect(again.ok).toBe(false);
    expect(db.num("select count(*) from sri_os.transactions")).toBe(before);
    expect(net("1100", tk())).toBe(0);
  });

  it("นิติบุคคล: ต้นฉบับต้องมีไฟล์หลักฐานจริง · ใบกลับรายการได้รับการยกเว้น (fn_corporate_evidence_ok)", async () => {
    const [id] = await mustPost({
      input: {
        typeKey: findSub("inc.other")!.type.key,
        subCode: "inc.other",
        amount: 50000,
        ownerId: corp(),
        bankAccountId: bankCorp,
        contactId,
        attachments: [evidencePath],
      },
      docDate: DAY,
      cashDate: DAY,
    });
    const out = await reverseEntry({ transactionId: id, reason: "ลงผิดนิติบุคคล" });
    expect(out.ok, JSON.stringify(out)).toBe(true);
    const revId = (out as { transactionIds: string[] }).transactionIds[0];
    // ใบกลับรายการไม่มีไฟล์แนบของตัวเองเลย แต่ลงได้เพราะลิงก์กลับรายการพิสูจน์ได้
    expect(db.num(`select coalesce(cardinality(attachments), 0) from sri_os.transactions where id='${revId}'`)).toBe(0);
    expect(net("1100", corp())).toBe(0);
    expect(net("4900", corp())).toBe(0);
  });

  it("ยกเลิกใบ (void): หายจาก v_ledger_posted ไปอยู่ v_ledger_voided · แถวยังอยู่ · มีเหตุผลกำกับ", async () => {
    const [id] = await mustPost(rentPaid({ amount: 7000 }));
    const out = await voidEntry({ transactionId: id, reason: "ลงผิดทั้งใบ ลงซ้ำกับใบอื่น" });
    expect(out.ok, JSON.stringify(out)).toBe(true);

    const h2 = head(id);
    expect(h2.status).toBe("void");
    expect(h2.void_reason).toBe("ลงผิดทั้งใบ ลงซ้ำกับใบอื่น");
    expect(db.num(`select count(*) from sri_os.v_ledger_posted where transaction_id='${id}'`)).toBe(0);
    expect(db.num(`select count(*) from sri_os.v_ledger_voided where transaction_id='${id}'`)).toBeGreaterThan(0);
    // แถวยังอยู่ (ไม่มี DELETE ที่ไหนเลย) และยอดในงบเป็นเหมือนไม่เคยมีใบนี้
    expect(db.num(`select count(*) from sri_os.transactions where id='${id}'`)).toBe(1);
    expect(net("1100", tk())).toBe(0);
  });

  it("กลับรายการใบที่ถูกยกเลิกไปแล้ว → ปฏิเสธพร้อมบอกว่า void แล้ว (อ่าน v_ledger_voided ด้วยสิทธิ์ผู้ใช้จริง)", async () => {
    const [id] = await mustPost(rentPaid({ amount: 8000 }));
    expect((await voidEntry({ transactionId: id, reason: "ยกเลิกก่อนเพื่อทดสอบ" })).ok).toBe(true);

    const out = await reverseEntry({ transactionId: id, reason: "ขอกลับรายการต่อ" });
    expect(out.ok).toBe(false);
    // ข้อความต้องชี้เหตุที่ถูกต้อง (ถูกยกเลิกแล้ว) ไม่ใช่ "ไม่พบรายการ" ลอยๆ
    if (!out.ok) expect(out.message).toMatch(/ถูกยกเลิก \(void\) ไปแล้ว/);
    expect(db.num(`select count(*) from sri_os.transactions where reverses_id = '${id}'`)).toBe(0);
  });

  it("ยกเลิกต้นฉบับที่มีใบกลับรายการที่ยังนับอยู่ → DB ปฏิเสธ (D-097 ข้อ 2) · สถานะไม่ขยับ", async () => {
    const [id] = await mustPost(rentPaid({ amount: 9000 }));
    expect((await reverseEntry({ transactionId: id, reason: "กลับก่อน" })).ok).toBe(true);
    const out = await voidEntry({ transactionId: id, reason: "ขอยกเลิกด้วย" });
    expect(out.ok).toBe(false);
    expect(head(id).status).toBe("posted");
  });

  it("ยกเลิกใบกลับรายการที่ลงผิดได้ แล้วต้นฉบับกลับมากลับรายการใหม่ได้ (ไม่ใช่ทางตัน)", async () => {
    const [id] = await mustPost(rentPaid({ amount: 6000 }));
    const rev = await reverseEntry({ transactionId: id, reason: "กลับรอบแรก" });
    const revId = (rev as { transactionIds: string[] }).transactionIds[0];

    expect((await voidEntry({ transactionId: revId, reason: "ใบกลับรายการนี้ลงผิด" })).ok).toBe(true);
    expect(net("1100", tk())).toBe(6000); // ต้นฉบับกลับมานับเดี่ยว

    const again = await reverseEntry({ transactionId: id, reason: "กลับใหม่ให้ถูก" });
    expect(again.ok, JSON.stringify(again)).toBe(true);
    expect(net("1100", tk())).toBe(0);
  });

  it("กลับรายการ 'ใบกลับรายการ' → แอปปฏิเสธก่อนถึง DB (ตัดสินใจไว้ · ดู reverse-entry.ts)", async () => {
    const [id] = await mustPost(rentPaid({ amount: 5000 }));
    const rev = await reverseEntry({ transactionId: id, reason: "กลับ" });
    const revId = (rev as { transactionIds: string[] }).transactionIds[0];
    const before = db.num("select count(*) from sri_os.transactions");

    const out = await reverseEntry({ transactionId: revId, reason: "กลับซ้อน" });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/เป็นใบกลับรายการอยู่แล้ว/);
    expect(db.num("select count(*) from sri_os.transactions")).toBe(before);
    expect((await voidEntry({ transactionId: revId, reason: "เก็บสภาพให้เทสต์ถัดไป" })).ok).toBe(true);
    expect((await voidEntry({ transactionId: id, reason: "เก็บสภาพให้เทสต์ถัดไป" })).ok).toBe(true);
  });

  /**
   * ตรึงข้อจำกัดของ schema วันนี้ — **ไม่ใช่พฤติกรรมที่ต้องการ**
   *
   * ทั้งสองวิธีที่คิดได้ถูก DB ปฏิเสธจริง จึงเป็นเหตุที่ `reverseBlocker()` ปฏิเสธ
   * รายการข้ามผู้ถือไว้ก่อน แทนที่จะส่งไปให้ผู้ใช้เจอ error ดิบ หรือ (แย่กว่า) กลับข้างเดียว
   */
  it("รายการข้ามผู้ถือ: DB ปฏิเสธทั้งสองวิธี → แอปจึงปฏิเสธไว้ก่อนพร้อมเหตุผล", async () => {
    const ids = await mustPost({
      input: {
        typeKey: findSub("trf.internal")!.type.key,
        subCode: "trf.internal",
        amount: 100000,
        ownerId: tk(),
        bankAccountId: bankTk,
        transferToBankAccountId: bankSutee,
        intercompanyNature: "advance",
      },
      docDate: DAY,
      cashDate: DAY,
    });
    expect(ids).toHaveLength(2);

    // แอปปฏิเสธก่อน พร้อมบอกว่าห้ามกลับข้างเดียว
    for (const id of ids) {
      const out = await reverseEntry({ transactionId: id, reason: "โอนผิดคน" });
      expect(out.ok).toBe(false);
      if (!out.ok) expect(out.message).toMatch(/ข้ามผู้ถือ/);
    }

    const legs = db.rows<{ id: string; owner_id: string; counter_owner_id: string }>(
      `select id::text, owner_id::text, counter_owner_id::text from sri_os.transactions where id in ('${ids[0]}', '${ids[1]}')`
    );
    const lineJson = (txn: string) =>
      db.su(
        `select coalesce(json_agg(jsonb_build_object('coa_code', c.code, 'bank_account_id', l.bank_account_id,
                 'asset_id', l.asset_id, 'debit', l.credit, 'credit', l.debit, 'cf_category', l.cf_category))::text, '[]')
           from sri_os.transaction_lines l join sri_os.chart_of_accounts c on c.id = l.coa_id
          where l.transaction_id = '${txn}'`
      );

    // วิธีที่ 1 — สองขาในคำขอเดียว: `reverses_id` เป็นช่องของหัวคำขอ จึงชี้ต้นฉบับได้ใบเดียว
    //   → ขาที่ผู้ถือไม่ตรงกับต้นฉบับถูก fn_reverse_link_ok ปฏิเสธ
    const both = await (h.client as ReturnType<typeof pgClient>).rpc("fn_post_entry", {
      p_payload: {
        txn_type_code: "trf.internal",
        doc_date: "2026-11-11",
        cash_date: "2026-11-11",
        memo: "ทดสอบ: สองขาในคำขอเดียว",
        source: "reverse",
        reverses_id: legs[0].id,
        transactions: legs.map((l) => ({
          owner_id: l.owner_id,
          counter_owner_id: l.counter_owner_id,
          intercompany_nature: "advance",
          lines: JSON.parse(lineJson(l.id)),
        })),
      },
    });
    expect(both.error, "DB ต้องปฏิเสธการชี้ต้นฉบับใบเดียวจากสองขา").not.toBeNull();
    expect(String(both.error?.message)).toMatch(/กลับรายการ|reverses_id/);

    // วิธีที่ 2 — ขาละคำขอ: ผ่านด่านลิงก์ แต่ `fn_assert_intercompany_pair` บังคับว่า
    //   ขาคู่ต้องอยู่ใน **ธุรกรรมฐานข้อมูลเดียวกัน** (write_txn_id) ซึ่ง RPC สองครั้งไม่เท่ากัน
    const oneLeg = await (h.client as ReturnType<typeof pgClient>).rpc("fn_post_entry", {
      p_payload: {
        txn_type_code: "trf.internal",
        doc_date: "2026-11-11",
        cash_date: "2026-11-11",
        memo: "ทดสอบ: ขาเดียวต่อคำขอ",
        source: "reverse",
        reverses_id: legs[0].id,
        transactions: [
          {
            owner_id: legs[0].owner_id,
            counter_owner_id: legs[0].counter_owner_id,
            intercompany_nature: "advance",
            lines: JSON.parse(lineJson(legs[0].id)),
          },
        ],
      },
    });
    expect(oneLeg.error, "DB ต้องปฏิเสธการกลับรายการข้ามผู้ถือขาเดียว").not.toBeNull();
    expect(String(oneLeg.error?.message)).toMatch(/ครบคู่|ข้ามผู้ถือ/);

    // และไม่มีใบกลับรายการของสองขานี้เกิดขึ้นเลย
    expect(db.num(`select count(*) from sri_os.transactions where reverses_id in ('${ids[0]}', '${ids[1]}')`)).toBe(0);
  });
});
