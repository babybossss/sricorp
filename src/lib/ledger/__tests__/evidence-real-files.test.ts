import { describe, expect, it } from "vitest";
import { buildObjectPath } from "@/lib/storage/path";
import { buildPosting, buildPostingDraft } from "../posting";
import { PostingError, type LedgerResolver, type PostingInput } from "../types";
import { EVIDENCE, TEST_RESOLVER } from "./fixture-resolver";

/**
 * D-095 · ด่าน corporate_strict ต้องนับ **ไฟล์ที่อัปโหลดจริง** ไม่ใช่จำนวนช่องใน attachments
 *
 * ที่นี่เป็นด่านของเครื่องยนต์ = ข้อความให้ผู้ใช้รู้ตัว **ก่อน** กดบันทึก
 * ตัวบังคับจริงคือ trigger ใน DB (supabase/migrations/20261010000000_evidence_real_files.sql)
 * ซึ่งเป็นที่เดียวที่รู้ว่าไฟล์มีอยู่จริงไหม — เครื่องยนต์เช็คได้แค่ "เป็น path ของไฟล์ใน Storage"
 */

const CORP_UUID = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa";
const OTHER_UUID = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb";
const UPLOADER = "cccccccc-3333-4333-8333-cccccccccccc";

/** resolver ที่ผู้ถือเป็น uuid จริงเหมือนใน DB → เทียบ owner ใน path ได้ */
const UUID_RESOLVER: LedgerResolver = {
  owner: (id) =>
    id === CORP_UUID
      ? { id, name: "SRI Corporation", policy: "corporate_strict", selectableAsHolder: true }
      : id === OTHER_UUID
        ? { id, name: "SRI Holding", policy: "corporate_strict", selectableAsHolder: true }
        : null,
  bankAccount: (id) => (id === "bx" ? { id, name: "SRI - SCB", ownerId: CORP_UUID, isActive: true } : null),
};

const corp: PostingInput = {
  typeKey: "income",
  subCode: "inc.rent",
  amount: 10_000,
  ownerId: "corp",
  bankAccountId: "b1",
  contactId: "c1",
  assetId: "asset-1",
};

const message = (fn: () => unknown) => {
  try {
    fn();
    return "(ไม่โยน)";
  } catch (e) {
    expect(e).toBeInstanceOf(PostingError);
    return (e as Error).message;
  }
};

describe("corporate_strict · ชื่อไฟล์ที่พิมพ์เองไม่ใช่หลักฐาน", () => {
  it("ไม่แนบไฟล์เลย → ปฏิเสธ (เคสเดิม)", () => {
    expect(message(() => buildPosting(corp, TEST_RESOLVER))).toMatch(/หลักฐาน/);
    expect(message(() => buildPosting({ ...corp, attachments: [] }, TEST_RESOLVER))).toMatch(/หลักฐาน/);
  });

  it("แนบชื่อไฟล์ที่ผู้ใช้พิมพ์ → ปฏิเสธ และข้อความต้องบอกว่าต้องอัปโหลดไฟล์จริง", () => {
    for (const fake of [["สลิป.jpg"], ["slip.pdf"], ["หลักฐาน-1.pdf", "หลักฐาน-2.pdf"]]) {
      const m = message(() => buildPosting({ ...corp, attachments: fake }, TEST_RESOLVER));
      expect(m).toMatch(/อัปโหลด/);
      expect(m).toMatch(/หลักฐาน/);
    }
  });

  it("แนบ path ของไฟล์ใน Storage → ผ่าน", () => {
    expect(() => buildPosting({ ...corp, attachments: EVIDENCE }, TEST_RESOLVER)).not.toThrow();
    expect(() =>
      buildPosting({ ...corp, attachments: ["สลิป.jpg", ...EVIDENCE] }, TEST_RESOLVER)
    ).not.toThrow();
  });

  it("ผู้ถือที่เป็นบุคคล ไม่เปลี่ยนนโยบาย (ไม่แนบไฟล์ก็ลงได้)", () => {
    expect(() =>
      buildPosting(
        { ...corp, ownerId: "thanakorn", bankAccountId: "b4" },
        TEST_RESOLVER
      )
    ).not.toThrow();
  });

  it("พรีวิว (buildPostingDraft) ยังแสดงบรรทัดได้ทั้งที่ยังไม่มีไฟล์จริง — ไฟล์ไม่เปลี่ยนคู่บัญชี", () => {
    const draft = buildPostingDraft({ ...corp, attachments: ["สลิป.jpg"] }, TEST_RESOLVER);
    const real = buildPosting({ ...corp, attachments: EVIDENCE }, TEST_RESOLVER);
    expect(draft.transactions[0].lines.map((l) => l.coaCode)).toEqual(
      real.transactions[0].lines.map((l) => l.coaCode)
    );
  });

  it("ผู้ถือเป็น uuid (เหมือนใน DB): ไฟล์ของผู้ถืออื่นใช้อ้างเป็นหลักฐานของตัวเองไม่ได้", () => {
    const input: PostingInput = {
      ...corp,
      ownerId: CORP_UUID,
      bankAccountId: "bx",
      attachments: [buildObjectPath({ ownerId: OTHER_UUID, uploaderId: UPLOADER, ext: "pdf" })],
    };
    expect(message(() => buildPosting(input, UUID_RESOLVER))).toMatch(/ผู้ถือ|หลักฐาน/);

    const own = buildObjectPath({ ownerId: CORP_UUID, uploaderId: UPLOADER, ext: "pdf" });
    expect(() => buildPosting({ ...input, attachments: [own] }, UUID_RESOLVER)).not.toThrow();
    // ของผู้ถืออื่นปนมากับของตัวเอง → ยังผ่านเพราะมีของตัวเองอย่างน้อยหนึ่ง
    expect(() =>
      buildPosting({ ...input, attachments: [...input.attachments!, own] }, UUID_RESOLVER)
    ).not.toThrow();
  });

  it("โอนข้ามผู้ถือไปหานิติบุคคล: ขาของฝ่ายนั้นก็ต้องมีไฟล์จริง (ไล่จากทุกผู้ถือที่รายการแตะ)", () => {
    const cross: PostingInput = {
      typeKey: "transfer",
      subCode: "trf.internal",
      amount: 20_000,
      ownerId: "thanakorn",
      bankAccountId: "b4",
      transferToBankAccountId: "b1",
      intercompanyNature: "loan",
      contactId: "c1",
    };
    expect(message(() => buildPosting({ ...cross, attachments: ["สลิป.jpg"] }, TEST_RESOLVER))).toMatch(
      /หลักฐาน/
    );
    expect(() => buildPosting({ ...cross, attachments: EVIDENCE }, TEST_RESOLVER)).not.toThrow();
  });
});
