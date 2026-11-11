/**
 * ทุกการปฏิเสธที่ผู้ใช้มีโอกาสเจอ ต้องเป็น `PostingError` ที่อ่านรู้เรื่อง
 *
 * ที่มา: ไม่ส่ง `typeKey` แล้ว `isValidPair()` เรียก `getTxType()` ซึ่งโยน **`Error` ธรรมดา**
 * ผลไม่ใช่การหลุดเงียบ (ดีแล้ว) แต่:
 * - `previewPosting()` และ `attempt()` ในหน้าจอจับเฉพาะ `PostingError` แล้ว **re-throw ตัวอื่น**
 *   → error ดิบดังขึ้นจอ ผู้ใช้เห็นข้อความที่อ่านไม่รู้เรื่องและไม่รู้ว่าต้องแก้อะไร
 * - ข้อความไม่บอกว่า "ขาดประเภทรายการ" ซึ่งคือสิ่งเดียวที่คนกรอกต้องรู้
 *
 * เส้นแบ่งที่ชุดนี้ยึด:
 * - **ข้อมูลจากผู้ใช้/DB ไม่ครบ → `PostingError`** (ดักได้ แสดงเป็นข้อความได้)
 * - **bug ของโปรแกรมเมอร์ (ไม่ควรเกิดได้เลย) → `Error` ธรรมดา** ปล่อยให้ดังและเห็น
 *   เช่น `coa()` ที่รับรหัสบัญชีจากตารางกฎเท่านั้น — ถ้าพังคือตารางกฎพัง ไม่ใช่ผู้ใช้กรอกผิด
 */

import { describe, it, expect } from "vitest";
import { buildPosting, buildPostingDraft } from "../posting";
import { buildClearing, buildClearingDraft } from "../clearing";
import { previewPosting } from "../preview";
import { PostingError, type ClearingInput, type PostingInput } from "../types";
import { TEST_RESOLVER } from "./fixture-resolver";

const rent: PostingInput = {
  typeKey: "income",
  subCode: "inc.rent",
  amount: 12_000,
  ownerId: "thanakorn",
  bankAccountId: "b4",
  assetId: "rent1",
  contactId: "c1",
};

const transfer: PostingInput = {
  typeKey: "transfer",
  subCode: "trf.internal",
  amount: 5_000,
  ownerId: "thanakorn",
  bankAccountId: "b4",
  transferToBankAccountId: "b4b",
};

const receivable: ClearingInput = {
  sourceId: "tx-rent-09",
  typeKey: "income",
  subCode: "inc.rent",
  ownerId: "thanakorn",
  accruedAmount: 12_000,
  postedClearings: [],
  amount: 12_000,
  bankAccountId: "b4",
  date: "2026-10-03",
  assetId: "rent1",
  contactId: "c1",
};

/** ตัดช่องออกจริงๆ — TypeScript กันช่องบังคับให้แล้ว แต่ข้อมูลตอน runtime มาจาก DB/ฟอร์ม */
const without = <T extends object>(input: T, key: keyof T): T => {
  const copy = { ...input };
  delete copy[key];
  return copy;
};

/** คืนข้อความ และยืนยันว่าเป็น `PostingError` ไม่ใช่ error ดิบ */
const rejectedWith = (fn: () => unknown): string => {
  try {
    fn();
  } catch (e) {
    expect(e, `ต้องเป็น PostingError ไม่ใช่ ${(e as Error).name}`).toBeInstanceOf(PostingError);
    return (e as Error).message;
  }
  throw new Error("ต้องถูกปฏิเสธ แต่ผ่าน");
};

describe("ไม่ส่ง typeKey — ต้องเป็น PostingError ที่บอกว่าขาดประเภทรายการ", () => {
  const noType = (i: PostingInput) => without(i, "typeKey");

  it("buildPosting / buildPostingDraft ปฏิเสธด้วยข้อความภาษาไทยที่บอกว่าขาดอะไร", () => {
    const m = rejectedWith(() => buildPosting(noType(rent), TEST_RESOLVER));
    expect(m).toMatch(/ประเภทรายการ/);
    expect(rejectedWith(() => buildPostingDraft(noType(rent), TEST_RESOLVER))).toMatch(
      /ประเภทรายการ/
    );
  });

  it("เส้นทางโอน (สาขาอื่นของ engine) ก็ปฏิเสธแบบเดียวกัน", () => {
    expect(rejectedWith(() => buildPosting(noType(transfer), TEST_RESOLVER))).toMatch(
      /ประเภทรายการ/
    );
  });

  it("buildClearing / buildClearingDraft ปฏิเสธแบบเดียวกัน", () => {
    expect(rejectedWith(() => buildClearing(without(receivable, "typeKey"), TEST_RESOLVER))).toMatch(
      /ประเภทรายการ/
    );
    expect(
      rejectedWith(() => buildClearingDraft(without(receivable, "typeKey"), TEST_RESOLVER))
    ).toMatch(/ประเภทรายการ/);
  });

  it("สตริงเปล่า / ช่องว่าง ถือว่าไม่ได้ระบุเหมือนกัน", () => {
    for (const typeKey of ["", "   "] as unknown as PostingInput["typeKey"][]) {
      expect(rejectedWith(() => buildPosting({ ...rent, typeKey }, TEST_RESOLVER))).toMatch(
        /ประเภทรายการ/
      );
    }
  });

  it("ประเภทรายการที่ไม่มีในตารางกฎ → PostingError ไม่ใช่ Error ดิบ", () => {
    const typeKey = "ghost" as PostingInput["typeKey"];
    expect(rejectedWith(() => buildPosting({ ...rent, typeKey }, TEST_RESOLVER))).toMatch(/ghost/);
  });

  it("previewPosting คืน ok:false พร้อมเหตุผล ไม่โยน error ดิบขึ้นจอ", () => {
    const p = previewPosting(noType(rent), TEST_RESOLVER);
    expect(p.ok).toBe(false);
    if (!p.ok) expect(p.reason).toMatch(/ประเภทรายการ/);
  });

  it("ไม่ส่งหมวดย่อย ก็ต้องเป็น PostingError ที่บอกว่าขาดหมวดย่อย", () => {
    expect(rejectedWith(() => buildPosting(without(rent, "subCode"), TEST_RESOLVER))).toMatch(
      /หมวดย่อย/
    );
    expect(rejectedWith(() => buildPosting({ ...rent, subCode: "  " }, TEST_RESOLVER))).toMatch(
      /หมวดย่อย/
    );
  });
});

/**
 * กวาดทุกช่องทีละช่อง — เทสต์ที่ส่งข้อมูลครบเสมอจะไม่มีวันแตะเส้นทางที่ข้อมูลขาด
 * (บทเรียน mace-windu ข้อ 3) ชุดนี้กันการเพิ่มช่องใหม่ในอนาคตที่ลืมแปลงเป็น `PostingError`
 */
describe("กวาดทุกช่อง: ขาดช่องไหนก็ต้องได้ PostingError ไม่ใช่ error ดิบ", () => {
  const assertOnlyPostingError = (fn: () => unknown, label: string) => {
    try {
      fn();
    } catch (e) {
      expect(e, `ขาด ${label} ต้องได้ PostingError ไม่ใช่ ${(e as Error).name}`).toBeInstanceOf(
        PostingError
      );
    }
  };

  it("buildPosting — รายการรับเงินปกติ", () => {
    for (const key of Object.keys(rent) as (keyof PostingInput)[]) {
      assertOnlyPostingError(() => buildPosting(without(rent, key), TEST_RESOLVER), String(key));
    }
  });

  it("buildPosting — รายการโอน", () => {
    for (const key of Object.keys(transfer) as (keyof PostingInput)[]) {
      assertOnlyPostingError(
        () => buildPosting(without(transfer, key), TEST_RESOLVER),
        String(key)
      );
    }
  });

  it("buildClearing — ยืนยันเงินเข้า-ออกจริง", () => {
    for (const key of Object.keys(receivable) as (keyof ClearingInput)[]) {
      assertOnlyPostingError(
        () => buildClearing(without(receivable, key), TEST_RESOLVER),
        String(key)
      );
    }
  });
});
