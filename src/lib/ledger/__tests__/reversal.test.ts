/**
 * เทสต์ของ `buildReversal()`
 *
 * เคสที่ตั้งใจให้มีเยอะกว่าปกติคือ **เคสที่ข้อมูลขาด**
 * (บทเรียน `mace-windu` ข้อ 3: เทสต์ที่ส่งข้อมูลครบเสมอ จะไม่มีวันแตะเส้นทางที่ข้อมูลขาด)
 */
import { describe, expect, it } from "vitest";
import { buildReversal, type ReversalSource } from "../reversal";
import { PostingError, type PostingLine } from "../types";

const OWNER_A = "owner-sri-corp";
const OWNER_B = "owner-thanakorn";

/** รายการค่าเช่ารับปกติ: เงินเข้าธนาคาร / รายได้ค่าเช่า */
function rentSource(over: Partial<ReversalSource> = {}): ReversalSource {
  return {
    txnId: "txn-rent-001",
    ownerId: OWNER_A,
    status: "posted",
    hasLiveReversal: false,
    lines: [
      { coaCode: "1100", bankAccountId: "bank-kbank", debit: 30000, credit: 0, cfCategory: "operating" },
      { coaCode: "4100", assetId: "asset-condo-1", debit: 0, credit: 30000, cfCategory: "operating" },
    ],
    ...over,
  };
}

const reason = "ลงผิดหลัง ที่ถูกคือคอนโดอีกห้อง";

/** ยอดสุทธิต่อรหัสบัญชีของสองใบรวมกัน — ต้องเป็นศูนย์ทุกรหัส */
function netByCoa(a: PostingLine[], b: PostingLine[]): Record<string, number> {
  const net: Record<string, number> = {};
  for (const l of [...a, ...b]) {
    net[l.coaCode] = (net[l.coaCode] ?? 0) + (l.debit ?? 0) - (l.credit ?? 0);
  }
  return net;
}

describe("buildReversal · การสะท้อนบรรทัด", () => {
  it("สลับเดบิต/เครดิต และยอดสุทธิของสองใบรวมกันเป็นศูนย์ทุกรหัสบัญชี", () => {
    const src = rentSource();
    const { transactions } = buildReversal({ originals: [src], reason });

    expect(transactions).toHaveLength(1);
    const rev = transactions[0];
    expect(rev.reversesId).toBe("txn-rent-001");
    expect(rev.ownerId).toBe(OWNER_A);

    expect(rev.lines[0]).toMatchObject({ coaCode: "1100", debit: 0, credit: 30000 });
    expect(rev.lines[1]).toMatchObject({ coaCode: "4100", debit: 30000, credit: 0 });

    // นี่คือคุณสมบัติที่ทั้งหมดนี้มีไว้เพื่อ: หักกันหมดจริง
    const net = netByCoa(src.lines, rev.lines);
    for (const [coa, v] of Object.entries(net)) {
      expect(v, `รหัส ${coa} ต้องหักกันหมด`).toBe(0);
    }
  });

  it("คัดลอกมิติทุกตัวที่ต้นฉบับมี (ธนาคาร · ทรัพย์ · หมวดกระแสเงินสด)", () => {
    const { transactions } = buildReversal({ originals: [rentSource()], reason });
    const [cash, revenue] = transactions[0].lines;

    // ทิ้งไว้ตัวใดตัวหนึ่ง = รายงานเพี้ยนแบบที่งบรวมยังสมดุล จึงไม่มีอะไรดังเตือน
    expect(cash.bankAccountId).toBe("bank-kbank");
    expect(cash.cfCategory).toBe("operating");
    expect(revenue.assetId).toBe("asset-condo-1");
    expect(revenue.cfCategory).toBe("operating");
  });

  it("ไม่ใส่คีย์มิติที่ต้นฉบับไม่มี (null กับ ไม่มีคีย์ เทียบ multiset ฝั่ง DB ไม่ตรงกัน)", () => {
    const accrual: ReversalSource = {
      txnId: "txn-accrual-1",
      ownerId: OWNER_A,
      status: "posted",
      hasLiveReversal: false,
      // รายการตั้งค้างรับ ไม่มีขาเงินสด จึงไม่มี bankAccountId และไม่เข้างบกระแสเงินสด
      lines: [
        { coaCode: "1200", debit: 12000, credit: 0 },
        { coaCode: "4100", debit: 0, credit: 12000 },
      ],
    };
    const { transactions } = buildReversal({ originals: [accrual], reason });
    for (const l of transactions[0].lines) {
      expect("bankAccountId" in l).toBe(false);
      expect("assetId" in l).toBe(false);
      expect("cfCategory" in l).toBe(false);
    }
  });

  it("เศษสตางค์สะท้อนตรงตัว ไม่ปัดใหม่", () => {
    const odd = rentSource({
      lines: [
        { coaCode: "1100", bankAccountId: "bank-kbank", debit: 10000.33, credit: 0 },
        { coaCode: "4100", debit: 0, credit: 10000.33 },
      ],
    });
    const { transactions } = buildReversal({ originals: [odd], reason });
    expect(transactions[0].lines[0].credit).toBe(10000.33);
    expect(transactions[0].lines[1].debit).toBe(10000.33);
  });

  it("สะท้อนบรรทัดเกินสองบรรทัดได้ (รายการที่มีขากำไร/ขาดทุน)", () => {
    const sale = rentSource({
      txnId: "txn-sale-1",
      lines: [
        { coaCode: "1100", bankAccountId: "bank-kbank", debit: 8_000_000, credit: 0, cfCategory: "investing" },
        { coaCode: "1500", assetId: "asset-land-9", debit: 0, credit: 6_000_000, cfCategory: "investing" },
        { coaCode: "4300", debit: 0, credit: 2_000_000, cfCategory: "none" },
      ],
    });
    const { transactions } = buildReversal({ originals: [sale], reason });
    expect(transactions[0].lines).toHaveLength(3);
    const net = netByCoa(sale.lines, transactions[0].lines);
    for (const v of Object.values(net)) expect(v).toBe(0);
  });
});

describe("buildReversal · ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่เดา", () => {
  it("ไม่ส่งรายการมาเลย", () => {
    expect(() => buildReversal({ originals: [], reason })).toThrow(PostingError);
  });

  it("ไม่ใส่เหตุผล", () => {
    expect(() => buildReversal({ originals: [rentSource()], reason: "   " })).toThrow(/เหตุผล/);
  });

  it("ต้นฉบับถูก void ไปแล้ว — กลับอีกจะหักซ้ำ", () => {
    expect(() => buildReversal({ originals: [rentSource({ status: "void" })], reason })).toThrow(
      /ยกเลิก \(void\)/,
    );
  });

  it("ต้นฉบับมีใบกลับรายการที่ยังมีผลอยู่แล้ว", () => {
    expect(() =>
      buildReversal({ originals: [rentSource({ hasLiveReversal: true })], reason }),
    ).toThrow(/หักสองรอบ/);
  });

  it("บรรทัดที่อ่านมามีน้อยกว่าสองบรรทัด", () => {
    expect(() =>
      buildReversal({
        originals: [rentSource({ lines: [{ coaCode: "1100", debit: 30000, credit: 0 }] })],
        reason,
      }),
    ).toThrow(/อย่างน้อยสองบรรทัด/);
  });

  it("บรรทัดที่อ่านมาไม่สมดุล — ห้ามปัดให้ลงตัว", () => {
    expect(() =>
      buildReversal({
        originals: [
          rentSource({
            lines: [
              { coaCode: "1100", debit: 30000, credit: 0 },
              { coaCode: "4100", debit: 0, credit: 29000 },
            ],
          }),
        ],
        reason,
      }),
    ).toThrow(/ไม่สมดุล/);
  });

  it("บรรทัดที่สองข้างเป็นศูนย์", () => {
    expect(() =>
      buildReversal({
        originals: [
          rentSource({
            lines: [
              { coaCode: "1100", debit: 0, credit: 0 },
              { coaCode: "4100", debit: 0, credit: 0 },
            ],
          }),
        ],
        reason,
      }),
    ).toThrow(PostingError);
  });

  it("บรรทัดที่มีทั้งเดบิตและเครดิต", () => {
    expect(() =>
      buildReversal({
        originals: [
          rentSource({
            lines: [
              { coaCode: "1100", debit: 500, credit: 500 },
              { coaCode: "4100", debit: 500, credit: 500 },
            ],
          }),
        ],
        reason,
      }),
    ).toThrow(/เดบิตหรือเครดิตอย่างใดอย่างหนึ่ง/);
  });

  it("ไม่มี id ของต้นฉบับ", () => {
    expect(() => buildReversal({ originals: [rentSource({ txnId: "" })], reason })).toThrow(
      /ไม่มี id/,
    );
  });

  it("ส่งรายการเดิมมาซ้ำสองครั้ง", () => {
    expect(() =>
      buildReversal({ originals: [rentSource(), rentSource()], reason }),
    ).toThrow(/ซ้ำสองครั้ง/);
  });
});

describe("buildReversal · รายการข้ามผู้ถือต้องมาครบคู่", () => {
  const legA = (): ReversalSource => ({
    txnId: "txn-ic-a",
    ownerId: OWNER_A,
    status: "posted",
    hasLiveReversal: false,
    counterOwnerId: OWNER_B,
    intercompanyNature: "advance",
    lines: [
      { coaCode: "1310", debit: 100000, credit: 0 },
      { coaCode: "1100", bankAccountId: "bank-kbank", debit: 0, credit: 100000, cfCategory: "investing" },
    ],
  });

  const legB = (): ReversalSource => ({
    txnId: "txn-ic-b",
    ownerId: OWNER_B,
    status: "posted",
    hasLiveReversal: false,
    counterOwnerId: OWNER_A,
    intercompanyNature: "advance",
    lines: [
      { coaCode: "1100", bankAccountId: "bank-scb", debit: 100000, credit: 0, cfCategory: "financing" },
      { coaCode: "2310", debit: 0, credit: 100000 },
    ],
  });

  it("ส่งมาขาเดียว → ปฏิเสธ (ลูกหนี้/เจ้าหนี้ระหว่างกันจะไม่ตรงกันตลอดไป)", () => {
    expect(() => buildReversal({ originals: [legA()], reason })).toThrow(/ข้ามผู้ถือ/);
  });

  it("ส่งมาครบสองขา → ได้ใบกลับรายการสองใบ แต่ละใบสมดุลในตัว และเก็บลักษณะไว้", () => {
    const { transactions } = buildReversal({ originals: [legA(), legB()], reason });
    expect(transactions).toHaveLength(2);
    for (const t of transactions) {
      expect(t.intercompanyNature).toBe("advance");
      const dr = t.lines.reduce((s, l) => s + l.debit, 0);
      const cr = t.lines.reduce((s, l) => s + l.credit, 0);
      expect(dr).toBe(cr);
    }
    // ขาละใบ ชี้กลับต้นฉบับของตัวเอง
    expect(transactions.map((t) => t.reversesId).sort()).toEqual(["txn-ic-a", "txn-ic-b"]);
    expect(transactions.map((t) => t.ownerId).sort()).toEqual([OWNER_A, OWNER_B].sort());
  });

  it("ขาหนึ่ง void แล้ว → ปฏิเสธทั้งคู่ ไม่กลับข้างเดียว", () => {
    expect(() =>
      buildReversal({ originals: [legA(), { ...legB(), status: "void" }], reason }),
    ).toThrow(PostingError);
  });
});

describe("buildReversal · สิ่งที่ต้องไม่ทำ", () => {
  it("ไม่สร้างบรรทัดจากตารางกฎใหม่ — คัดลอกรหัสบัญชีของต้นฉบับแม้เป็นรหัสที่เลิกใช้", () => {
    // รหัส 9999 ไม่มีในผังบัญชีวันนี้ แต่ถ้าต้นฉบับเคยใช้ ใบกลับรายการต้องใช้ตัวเดียวกัน
    // ไม่งั้นสองใบหักกันไม่หมด แล้วยอดค้างในรหัสเก่าตลอดกาลโดยที่งบยังสมดุล
    const legacy = rentSource({
      lines: [
        { coaCode: "9999", debit: 1000, credit: 0 },
        { coaCode: "4100", debit: 0, credit: 1000 },
      ],
    });
    const { transactions } = buildReversal({ originals: [legacy], reason });
    expect(transactions[0].lines.map((l) => l.coaCode)).toEqual(["9999", "4100"]);
  });

  it("ไม่แตะบรรทัดของต้นฉบับที่ส่งเข้ามา", () => {
    const src = rentSource();
    const before = JSON.stringify(src.lines);
    buildReversal({ originals: [src], reason });
    expect(JSON.stringify(src.lines)).toBe(before);
  });
});
