import { describe, it, expect } from "vitest";
import { TREE, type TreeNode, allocationByClass, allocationGradient } from "../balance";
import { BANKS } from "../banks";
import { ENTITIES, HOLDERS, entityById } from "../entities";
import { LEDGER } from "../ledger";

function node(id: string, nodes: TreeNode[] = TREE): TreeNode | undefined {
  for (const n of nodes) {
    if (n.id === id) return n;
    const found = n.children ? node(id, n.children) : undefined;
    if (found) return found;
  }
  return undefined;
}

function walk(nodes: TreeNode[], fn: (n: TreeNode) => void) {
  for (const n of nodes) {
    fn(n);
    if (n.children) walk(n.children, fn);
  }
}

/**
 * ข้อมูลตัวอย่างก็ต้องลงตัวเหมือนข้อมูลจริง
 * ถ้าตัวเลขบนหน้าจอบวกไม่ได้ ระบบจะดูไม่น่าเชื่อถือตั้งแต่นาทีแรก
 */
describe("งบดุลตัวอย่างต้องลงตัว", () => {
  it("ทุกโหนดที่มีลูก ยอดต้องเท่ากับผลรวมของลูก", () => {
    walk(TREE, (n) => {
      if (!n.children?.length) return;
      const sum = n.children.reduce((t, c) => t + c.value, 0);
      expect(sum, `${n.id} (${n.name})`).toBe(n.value);
    });
  });

  it("สินทรัพย์ = หนี้สิน + ส่วนของเจ้าของ", () => {
    const assets = node("assets")!.value;
    const liab = node("liab")!.value;
    const equity = node("eq")!.value;
    expect(liab + equity).toBe(assets);
  });

  it("ต้นทุนของโหนดที่มีลูก ต้องเท่ากับผลรวมต้นทุนของลูก", () => {
    walk(TREE, (n) => {
      if (!n.children?.length || n.cost == null) return;
      const kids = n.children.filter((c) => c.cost != null);
      if (kids.length !== n.children.length) return; // มีลูกบางตัวไม่มีต้นทุน ข้าม
      const sum = kids.reduce((t, c) => t + (c.cost ?? 0), 0);
      expect(sum, `${n.id} (${n.name}) ต้นทุน`).toBe(n.cost);
    });
  });

  it("กำไรยังไม่รับรู้ = มูลค่าปัจจุบัน − ต้นทุน", () => {
    walk(TREE, (n) => {
      if (n.gl == null || n.cost == null) return;
      expect(n.value - n.cost, `${n.id} (${n.name})`).toBe(n.gl);
    });
  });

  it("บรรทัดมูลค่ายุติธรรมในส่วนของเจ้าของ = ผลรวมกำไรยังไม่รับรู้ของทุกทรัพย์", () => {
    // ถ้าสองตัวนี้ไม่เท่ากัน แปลว่ากำไรจากการตีราคาหายไปหรือถูกนับซ้ำ
    // อ่านหมวดใหญ่จากลูกโดยตรงของโหนด "สินทรัพย์" ไม่ฮาร์ดโค้ดรหัสหมวด
    // เดิมเขียน ["re","fin","inv"] ไว้ พอเปลี่ยนชื่อหมวดแล้วเทสต์เงียบๆ ไม่ครอบคลุมสองหมวด
    const classes = node("assets")!.children ?? [];
    const totalGl = classes.reduce((t, c) => t + (c.gl ?? 0), 0);
    expect(classes.length, "หมวดใหญ่ต้องมี 4 หมวด").toBe(4);
    expect(node("e3")!.value).toBe(totalGl);
  });

  it("รหัสโหนดไม่ซ้ำกัน", () => {
    const ids: string[] = [];
    walk(TREE, (n) => ids.push(n.id));
    expect(new Set(ids).size).toBe(ids.length);
  });
});

describe("เงินสดในงบดุลต้องตรงกับบัญชีที่มีอยู่จริง", () => {
  it("ทุกบรรทัดเงินสดมีบัญชีรองรับ — Money Invariant 2", () => {
    const cash = node("cash")!;
    const names = new Set(BANKS.map((b) => b.name));
    for (const c of cash.children ?? []) {
      expect(names.has(c.name), `${c.name} ไม่มีในรายการบัญชี`).toBe(true);
    }
  });

  it("จำนวนบรรทัดเงินสดเท่ากับจำนวนบัญชีที่มียอด", () => {
    const cash = node("cash")!;
    // บัญชีที่ยอดตั้งต้นเป็น 0 ไม่ต้องขึ้นในงบดุล
    const funded = BANKS.filter((b) => b.opening !== "฿ 0.00");
    expect(cash.children?.length).toBe(funded.length);
  });
});

describe("ผู้ถือกรรมสิทธิ์", () => {
  it("ฝั่งบุคคลมี 5 คนตามที่ลูกพี่ยืนยัน", () => {
    const people = HOLDERS.filter((h) => h.id !== "corp");
    expect(people.map((p) => p.id).sort()).toEqual(
      ["benjaporn", "sudjit", "sutee", "thanakorn", "thanawin"].sort()
    );
  });

  it("มุมมองรวมกองกลางเลือกเป็นผู้ถือในฟอร์มไม่ได้", () => {
    expect(entityById("family").selectableAsHolder).toBe(false);
  });

  it("รหัสผู้ถือไม่ซ้ำกัน", () => {
    const ids = ENTITIES.map((e) => e.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("ทุกบัญชีธนาคารผูกกับผู้ถือที่มีอยู่จริง", () => {
    for (const b of BANKS) {
      expect(ENTITIES.some((e) => e.id === b.ownerId), `${b.name} → ${b.ownerId}`).toBe(true);
    }
  });

  it("ทุกรายการใน ledger ผูกกับผู้ถือที่มีอยู่จริง", () => {
    for (const r of LEDGER) {
      expect(ENTITIES.some((e) => e.id === r.ownerId), `${r.id} → ${r.ownerId}`).toBe(true);
    }
  });
});

/**
 * โดนัทหน้าแรกเคยฮาร์ดโค้ดทั้งชื่อหมวดและเปอร์เซ็นต์
 * พอเปลี่ยนการจัดหมวดแล้วมันยังโชว์ของเก่า โดยไม่มีอะไรฟ้อง
 */
describe("สัดส่วนทรัพย์สินหน้าแรก", () => {
  it("สัดส่วนรวมกันได้ 100%", () => {
    const total = allocationByClass().reduce((t, c) => t + c.pct, 0);
    expect(total).toBeCloseTo(100, 6);
  });

  it("มีครบ 4 หมวดใหญ่ และชื่อตรงกับที่ลูกพี่กำหนด", () => {
    expect(allocationByClass().map((c) => c.name)).toEqual([
      "Businesses",
      "Real Estate",
      "Paper Asset",
      "Commodity & Cash",
    ]);
  });

  it("ยอดของแต่ละหมวดตรงกับงบดุล", () => {
    for (const c of allocationByClass()) {
      expect(node(c.id)!.value, c.name).toBe(c.value);
    }
  });

  it("ผลรวมทุกหมวดต้องเท่ากับสินทรัพย์รวม ไม่ตกหล่น", () => {
    // ถ้ามีทรัพย์ที่ไม่ได้อยู่ในหมวดใหญ่ใดเลย ยอดในโดนัทจะต่ำกว่างบดุล
    // ตอนต่อข้อมูลจริง ลูกหนี้ดำเนินงาน (1200/1210/1600/1310) ไม่ถูกจัดหมวด
    // จึงต้องมีบรรทัด "อื่นๆ" มารับ ไม่งั้นตัวเลขสองหน้าจะไม่ตรงกัน
    const total = allocationByClass().reduce((t, c) => t + c.value, 0);
    expect(total).toBe(node("assets")!.value);
  });

  it("โดนัทไล่สีครบ 100% ไม่มีช่องว่าง", () => {
    const g = allocationGradient();
    expect(g.startsWith("conic-gradient(")).toBe(true);
    expect(g).toContain("100.00%");
    expect(g.split(",").length).toBe(4);
  });
});
