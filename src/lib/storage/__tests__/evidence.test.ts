import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ALLOWED_TYPES } from "../config";
import { hasRealEvidence, realEvidenceCount, realEvidenceRefs } from "../evidence";
import { buildObjectPath } from "../path";
import { OTHER_OWNER, OWNER, USER } from "./helpers";

const ref = (owner = OWNER, ext: "jpg" | "pdf" = "pdf") =>
  buildObjectPath({ ownerId: owner, uploaderId: USER, ext });

/**
 * D-095 — "หลักฐาน" ต้องเป็นไฟล์ที่อัปโหลดจริง ไม่ใช่ชื่อไฟล์ที่ผู้ใช้พิมพ์
 * ฝั่งนี้เป็นด่านข้อความ (ให้ผู้ใช้รู้ตัวก่อนกดบันทึก) · ตัวบังคับจริงคือ trigger ใน DB
 */
describe("realEvidenceRefs — นับเฉพาะ path ของไฟล์ใน Storage", () => {
  it("ชื่อไฟล์ที่ผู้ใช้พิมพ์ไม่นับ (เคสของ D-095)", () => {
    for (const fake of [
      "สลิป.jpg",
      "slip.pdf",
      "หลักฐาน-1.pdf",
      "ใบเสร็จ 12/10/2569.jpg",
      "",
      "   ",
      "../etc/passwd",
    ]) {
      expect(realEvidenceCount([fake])).toBe(0);
      expect(hasRealEvidence([fake])).toBe(false);
    }
  });

  it("path จริงนับได้ · ปนของปลอมก็นับแค่ของจริง", () => {
    const a = ref();
    expect(realEvidenceCount([a])).toBe(1);
    expect(realEvidenceRefs(["สลิป.jpg", a, "x.pdf"])).toEqual([a]);
    expect(hasRealEvidence(["สลิป.jpg", a])).toBe(true);
  });

  it("path ซ้ำกันสองช่องนับเป็น 1 ไม่ใช่ 2 (เหมือน distinct ฝั่ง DB)", () => {
    const a = ref();
    expect(realEvidenceCount([a, a])).toBe(1);
    expect(realEvidenceCount([a, a, ref()])).toBe(2);
  });

  it("ข้อมูลขาด/ชนิดผิด ไม่ระเบิดและไม่นับ", () => {
    expect(realEvidenceCount(undefined)).toBe(0);
    expect(realEvidenceCount(null)).toBe(0);
    expect(realEvidenceCount([])).toBe(0);
    expect(realEvidenceCount([null, undefined, 0, 1, {}, [], true])).toBe(0);
    expect(hasRealEvidence(undefined)).toBe(false);
  });

  it("path ที่สะกดเพี้ยนจากของจริงไม่นับ (ตัวพิมพ์ใหญ่ · ต่อท้าย · ซ้อนโฟลเดอร์)", () => {
    const a = ref();
    for (const bad of [a.toUpperCase(), `${a} `, `${a}\n`, `attachments/${a}`, `${a}/../${a}`, a.replace(".pdf", ".exe")]) {
      expect(realEvidenceCount([bad])).toBe(0);
    }
  });

  it("owner ใน path ต้องตรงกับผู้ถือของรายการ (ยืมไฟล์คนอื่นมาอ้างไม่ได้)", () => {
    const mine = ref(OWNER);
    const theirs = ref(OTHER_OWNER);
    expect(realEvidenceCount([theirs], { ownerId: OWNER })).toBe(0);
    expect(realEvidenceCount([mine], { ownerId: OWNER })).toBe(1);
    expect(realEvidenceCount([mine], { ownerId: OWNER.toUpperCase() })).toBe(1);
    expect(realEvidenceCount([theirs, mine], { ownerId: OWNER })).toBe(1);
    // ไม่ส่ง ownerId = เทียบไม่ได้ (ข้อมูลจำลองยังใช้รหัสสั้น) → นับแค่รูปแบบ
    expect(realEvidenceCount([theirs])).toBe(1);
  });

  it("ownerId ที่ไม่ใช่ uuid ไม่ทำให้ไฟล์ของผู้ถืออื่นนับได้โดยบังเอิญ", () => {
    const theirs = ref(OTHER_OWNER);
    expect(realEvidenceCount([theirs], { ownerId: "corp" })).toBe(1); // mock: เทียบไม่ได้ → DB เป็นตัวบังคับ
    expect(realEvidenceCount([theirs], { ownerId: "" })).toBe(1);
  });
});

describe("ไม่มีกฎรูปแบบ path สองชุด — ฝั่ง TS กับ migration ต้องตรงกัน", () => {
  const sql = readFileSync(
    join(process.cwd(), "supabase/migrations/20261010000000_evidence_real_files.sql"),
    "utf8"
  );

  it("regex ของ migration = regex ของ path.ts (uuid 3 ชั้น + นามสกุลชุดเดียวกัน)", () => {
    const u = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
    expect(sql).toContain(`select '${u}' as u`);
    const m = /\\\.\(([a-z|]+)\)\$'/.exec(sql);
    const exts = new Set(m?.[1].split("|"));
    expect(exts).toEqual(new Set(Object.values(ALLOWED_TYPES)));
    // นามสกุลที่ migration รับ ต้องเป็นชุดเดียวกับที่ buildObjectPath สร้างได้
    for (const ext of exts) {
      expect(buildObjectPath({ ownerId: OWNER, uploaderId: USER, ext: ext as "jpg" })).toMatch(
        new RegExp(`\\.${ext}$`)
      );
    }
  });

  it("migration ยังถาม storage.objects และปฏิเสธเมื่อไม่มีสคีมา storage", () => {
    expect(sql).toContain("storage.objects");
    expect(sql).toMatch(/to_regclass\('storage\.objects'\) is null/);
    // ด่านต้องตัดสินด้วยการนับไฟล์จริง ไม่ใช่ความยาวอาร์เรย์ (บั๊กเดิมของ D-095)
    expect(sql).toContain("fn_corporate_evidence_ok(new.id, new.owner_id, new.source, new.reverses_id, new.attachments)");
    expect(sql).toContain("fn_real_evidence_count(p_owner, p_attachments) > 0");
  });
});
