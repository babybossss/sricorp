import { describe, expect, it } from "vitest";
import { MAX_ATTACHMENT_BYTES } from "../config";
import { sniffType } from "../sniff";
import { validateUpload } from "../validate";
import { EXE, HEIC, HTML, JPEG, PDF, PNG, SVG, WEBP } from "./helpers";

describe("sniffType — ดูชนิดจากไบต์จริง", () => {
  it.each([
    ["jpeg", JPEG, "image/jpeg", "jpg"],
    ["png", PNG, "image/png", "png"],
    ["webp", WEBP, "image/webp", "webp"],
    ["pdf", PDF, "application/pdf", "pdf"],
    ["heic (รูปจาก iPhone)", HEIC, "image/heic", "heic"],
  ])("รู้จัก %s", (_n, bytes, mime, ext) => {
    expect(sniffType(bytes)).toEqual({ mime, ext });
  });

  it("brand อื่นของ HEIF ที่มือถือใช้ก็รับ (mif1)", () => {
    const b = Uint8Array.from([0, 0, 0, 0x18, ...Buffer.from("ftypmif1"), 0, 0, 0, 0]);
    expect(sniffType(b)?.mime).toBe("image/heic");
  });

  it.each([
    ["exe", EXE],
    ["html", HTML],
    ["svg (รันสคริปต์ได้)", SVG],
    ["zip", Uint8Array.from([0x50, 0x4b, 3, 4, 0, 0, 0, 0])],
    ["gif", Uint8Array.from(Buffer.from("GIF89a....."))],
    ["ftyp แต่ brand เป็นวิดีโอ mp4", Uint8Array.from([0, 0, 0, 0x18, ...Buffer.from("ftypisom"), 0, 0, 0, 0])],
    ["RIFF แต่ไม่ใช่ WEBP (wav)", Uint8Array.from([...Buffer.from("RIFF"), 1, 0, 0, 0, ...Buffer.from("WAVEfmt ")])],
    ["PDF ที่มีขยะนำหน้า (polyglot)", Uint8Array.from(Buffer.from("junk%PDF-1.4"))],
    ["ไฟล์สั้นเกินกว่าจะเป็นหัวไฟล์", Uint8Array.from([0xff, 0xd8])],
  ])("ปฏิเสธ %s", (_n, bytes) => {
    expect(sniffType(bytes)).toBeNull();
  });

  it("ไม่ล้มกับ input ว่าง", () => {
    expect(sniffType(new Uint8Array(0))).toBeNull();
  });
});

describe("validateUpload — ตรวจที่ฝั่ง server จากไบต์จริง", () => {
  it("ผ่าน: jpeg ปกติ คืนชนิดจากไบต์", () => {
    expect(validateUpload(JPEG)).toMatchObject({ ok: true, mime: "image/jpeg", ext: "jpg", size: JPEG.byteLength });
  });

  // เคส "ไม่ส่งข้อมูล" (บทเรียนข้อ 3)
  it("ไม่มีไฟล์ (null / undefined) → empty_file", () => {
    expect(validateUpload(null)).toMatchObject({ ok: false, code: "empty_file" });
    expect(validateUpload(undefined)).toMatchObject({ ok: false, code: "empty_file" });
  });
  it("ไฟล์ว่าง 0 ไบต์ → empty_file", () => {
    expect(validateUpload(new Uint8Array(0))).toMatchObject({ ok: false, code: "empty_file" });
  });

  it("ขนาดพอดีเพดาน ผ่าน · เกิน 1 ไบต์ ไม่ผ่าน", () => {
    const at = new Uint8Array(MAX_ATTACHMENT_BYTES);
    at.set(JPEG);
    expect(validateUpload(at)).toMatchObject({ ok: true });
    const over = new Uint8Array(MAX_ATTACHMENT_BYTES + 1);
    over.set(JPEG);
    expect(validateUpload(over)).toMatchObject({ ok: false, code: "too_large" });
  });

  it("ชนิดที่ไม่อนุญาต → unsupported_type (exe/html/svg)", () => {
    for (const b of [EXE, HTML, SVG]) {
      expect(validateUpload(b)).toMatchObject({ ok: false, code: "unsupported_type" });
    }
  });

  it("ไม่รับ Content-Type/นามสกุลที่ client อ้างมาเป็นหลักฐาน: exe ที่ตั้งชื่อ .jpg ก็ยังถูกปฏิเสธ", () => {
    // validateUpload ไม่มีพารามิเตอร์ชื่อไฟล์/ชนิดเลย — โดยโครงสร้าง ปลอมไม่ได้
    expect(validateUpload.length).toBe(1);
    expect(validateUpload(EXE)).toMatchObject({ ok: false });
  });

  it("jpeg จริงที่ client อ้างว่าเป็น text/html → ตัดสินจากไบต์: เป็น jpeg", () => {
    expect(validateUpload(JPEG)).toMatchObject({ ok: true, mime: "image/jpeg" });
  });
});
