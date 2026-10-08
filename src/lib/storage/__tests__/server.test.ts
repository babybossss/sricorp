import { describe, expect, it } from "vitest";
import { SIGNED_URL_MAX_SECONDS, SIGNED_URL_MIN_SECONDS, SIGNED_URL_TTL_SECONDS } from "../config";
import { buildObjectPath } from "../path";
import { clampTtl, createAttachmentUrl, mapStorageError, removeAttachments, sweepOwnOrphans, uploadAttachment, verifyAttachmentsExist } from "../server";
import { EXE, fakeClient, JPEG, OWNER, PDF, USER } from "./helpers";

const ref = (tag = "jpg") => buildObjectPath({ ownerId: OWNER, uploaderId: USER, ext: tag as "jpg" });

describe("uploadAttachment", () => {
  it("สำเร็จ: ส่งชนิดจากไบต์ · upsert=false · path ตามรูปแบบ", async () => {
    const f = fakeClient();
    const r = await uploadAttachment(f.client, { userId: USER, ownerId: OWNER, bytes: PDF });
    expect(r).toMatchObject({ ok: true, mime: "application/pdf" });
    const call = f.calls.find((c) => c.op === "upload")!;
    expect(call.args[2]).toMatchObject({ contentType: "application/pdf", upsert: false });
    expect((r as { ref: string }).ref).toBe(call.args[0]);
    expect((r as { ref: string }).ref.startsWith(`${OWNER}/${USER}/`)).toBe(true);
  });

  // เคส "ไม่ส่งข้อมูล" + ปฏิเสธก่อนแตะ Storage
  it.each([
    ["ไม่มีไฟล์", undefined, "empty_file"],
    ["ไฟล์ว่าง", new Uint8Array(0), "empty_file"],
    ["ชนิดไม่อนุญาต", EXE, "unsupported_type"],
    ["ใหญ่เกิน", (() => { const b = new Uint8Array(4 * 1024 * 1024 + 1); b.set(JPEG); return b; })(), "too_large"],
  ])("%s → ปฏิเสธ ไม่เรียก Storage เลย", async (_n, bytes, code) => {
    const f = fakeClient();
    const r = await uploadAttachment(f.client, { userId: USER, ownerId: OWNER, bytes });
    expect(r).toMatchObject({ ok: false, code });
    expect(f.calls).toHaveLength(0);
  });

  it("ไม่รู้ผู้ใช้/ไม่รู้ owner → ปฏิเสธก่อนแตะ Storage", async () => {
    const f = fakeClient();
    expect(await uploadAttachment(f.client, { userId: "", ownerId: OWNER, bytes: JPEG })).toMatchObject({ ok: false, code: "not_signed_in" });
    expect(await uploadAttachment(f.client, { userId: USER, ownerId: "../x", bytes: JPEG })).toMatchObject({ ok: false, code: "bad_request" });
    expect(await uploadAttachment(f.client, { userId: USER, ownerId: undefined as never, bytes: JPEG })).toMatchObject({ ok: false, code: "bad_request" });
    expect(f.calls).toHaveLength(0);
  });

  it("RLS ปฏิเสธ (ผู้ถือที่ไม่มีสิทธิ์) → forbidden ข้อความไทย", async () => {
    const f = fakeClient({ upload: async () => ({ data: null, error: { message: "new row violates row-level security policy", statusCode: "403" } }) });
    const r = await uploadAttachment(f.client, { userId: USER, ownerId: OWNER, bytes: JPEG });
    expect(r).toMatchObject({ ok: false, code: "forbidden" });
    expect((r as { message: string }).message).toMatch(/ไม่มีสิทธิ์/);
  });

  it("ยังไม่ได้ apply migration (ไม่มี bucket) → บอกชื่อไฟล์ migration", async () => {
    const f = fakeClient({ upload: async () => ({ data: null, error: { message: "Bucket not found", statusCode: "404" } }) });
    const r = await uploadAttachment(f.client, { userId: USER, ownerId: OWNER, bytes: JPEG });
    expect(r).toMatchObject({ ok: false, code: "bucket_missing" });
    expect((r as { message: string }).message).toContain("20261008000009");
  });

  it("Storage ล่ม (throw) → network ไม่ throw ใส่หน้าจอ", async () => {
    const f = fakeClient({ upload: async () => { throw new Error("ECONNRESET"); } });
    expect(await uploadAttachment(f.client, { userId: USER, ownerId: OWNER, bytes: JPEG })).toMatchObject({ ok: false, code: "network" });
  });

  it("Storage ค้าง → timeout (ไม่ค้างตาม)", async () => {
    const f = fakeClient({ upload: () => new Promise(() => undefined) });
    const t0 = Date.now();
    // ใช้ fake timers ไม่ได้กับ Promise.race จริง — ตรวจว่า withTimeout ผูกกับ config โดยย่อเวลาผ่าน vi
    const { vi } = await import("vitest");
    vi.useFakeTimers();
    const p = uploadAttachment(f.client, { userId: USER, ownerId: OWNER, bytes: JPEG });
    await vi.advanceTimersByTimeAsync(26_000);
    expect(await p).toMatchObject({ ok: false, code: "timeout" });
    vi.useRealTimers();
    expect(Date.now() - t0).toBeLessThan(5000);
  });
});

describe("createAttachmentUrl — ลิงก์อายุจำกัด", () => {
  it("clampTtl: ค่าเริ่มต้น 5 นาที · ขอเกินเพดาน/ติดลบ/NaN ถูกบีบ", () => {
    expect(clampTtl(undefined)).toBe(SIGNED_URL_TTL_SECONDS);
    expect(clampTtl(Number.NaN)).toBe(SIGNED_URL_TTL_SECONDS);
    expect(clampTtl(Infinity)).toBe(SIGNED_URL_TTL_SECONDS);
    expect(clampTtl("999999")).toBe(SIGNED_URL_TTL_SECONDS);
    expect(clampTtl(99999999)).toBe(SIGNED_URL_MAX_SECONDS);
    expect(clampTtl(-5)).toBe(SIGNED_URL_MIN_SECONDS);
    expect(clampTtl(0)).toBe(SIGNED_URL_MIN_SECONDS);
    expect(SIGNED_URL_MAX_SECONDS).toBeLessThanOrEqual(15 * 60);
  });

  it("ออกลิงก์ด้วยอายุที่บีบแล้วเท่านั้น", async () => {
    const f = fakeClient();
    const r = await createAttachmentUrl(f.client, ref(), 10 ** 9);
    expect(r).toMatchObject({ ok: true, expiresIn: SIGNED_URL_MAX_SECONDS });
    expect(f.calls.find((c) => c.op === "sign")!.args[1]).toBe(SIGNED_URL_MAX_SECONDS);
  });

  it("ref ผิดรูปแบบ (traversal/ชื่อไทย/null) → ไม่เรียก Storage", async () => {
    const f = fakeClient();
    for (const bad of ["../../x", "สลิป.jpg", "", null, undefined, `${ref()}/../x`]) {
      expect(await createAttachmentUrl(f.client, bad)).toMatchObject({ ok: false, code: "bad_request" });
    }
    expect(f.calls).toHaveLength(0);
  });

  it("ไม่มีสิทธิ์ = ไม่พบ (ตอบเหมือนกัน ไม่บอกว่าไฟล์มีอยู่)", async () => {
    const f = fakeClient({ createSignedUrl: async () => ({ data: null, error: { message: "Object not found" } }) });
    expect(await createAttachmentUrl(f.client, ref())).toMatchObject({ ok: false, code: "not_found" });
  });

  it("เครือข่ายหลุดครั้งแรก อ่านซ้ำ 1 ครั้งแล้วผ่าน", async () => {
    let n = 0;
    const f = fakeClient({
      createSignedUrl: async () => {
        if (n++ === 0) throw new Error("reset");
        return { data: { signedUrl: "https://ok" }, error: null };
      },
    });
    expect(await createAttachmentUrl(f.client, ref())).toMatchObject({ ok: true, url: "https://ok" });
  });
});

describe("removeAttachments — ลบไม่ได้ต้องไม่ทำเป็นว่าลบแล้ว", () => {
  it("ลบสำเร็จ รายงาน removed", async () => {
    const a = ref();
    const f = fakeClient();
    expect(await removeAttachments(f.client, [a, a])).toMatchObject({ ok: true, removed: [a], kept: [] });
  });

  it("RLS/trigger กรองทิ้ง (Storage ตอบสำเร็จแต่ไม่ลบ) → ไฟล์อยู่ใน kept", async () => {
    const a = ref(), b = ref();
    const f = fakeClient({ remove: async () => ({ data: [{ name: a }], error: null }) });
    expect(await removeAttachments(f.client, [a, b])).toMatchObject({ ok: true, removed: [a], kept: [b] });
    const none = fakeClient({ remove: async () => ({ data: [], error: null }) });
    expect(await removeAttachments(none.client, [a])).toMatchObject({ ok: true, removed: [], kept: [a] });
  });

  it("ไม่ส่งข้อมูล: [] → ไม่เรียก Storage · ไม่ใช่ array → bad_request · มีแต่ ref เสีย → bad_request", async () => {
    const f = fakeClient();
    expect(await removeAttachments(f.client, [])).toMatchObject({ ok: true, removed: [], kept: [] });
    expect(await removeAttachments(f.client, undefined)).toMatchObject({ ok: false, code: "bad_request" });
    expect(await removeAttachments(f.client, ["../../etc/passwd", "สลิป.jpg"])).toMatchObject({ ok: false, code: "bad_request" });
    expect(f.calls).toHaveLength(0);
  });

  it("ref เสียปนมา: ไม่ถูกส่งให้ Storage และถูกรายงานว่าไม่ได้ลบ", async () => {
    const a = ref();
    const f = fakeClient();
    const r = await removeAttachments(f.client, [a, "../../x"]);
    expect(f.calls.find((c) => c.op === "remove")!.args[0]).toEqual([a]);
    expect(r).toMatchObject({ ok: true, removed: [a], kept: ["../../x"] });
  });
});

describe("verifyAttachmentsExist — ด่านก่อนบันทึก ไม่รับไฟล์จำลอง", () => {
  it("ไม่มีไฟล์แนบเลย → ปฏิเสธ (ไม่ใช่ผ่านเพราะไม่มีอะไรให้ตรวจ)", async () => {
    const f = fakeClient();
    for (const v of [undefined, null, [], "x"]) {
      expect(await verifyAttachmentsExist(f.client, v)).toMatchObject({ ok: false, code: "bad_request" });
    }
    expect(f.calls).toHaveLength(0);
  });

  it("ชื่อไฟล์จำลองแบบเดิม ('สลิป.jpg') ไม่ผ่าน", async () => {
    const f = fakeClient();
    expect(await verifyAttachmentsExist(f.client, ["สลิป.jpg"])).toMatchObject({ ok: false, code: "bad_request" });
    expect(await verifyAttachmentsExist(f.client, [ref(), "slip.pdf"])).toMatchObject({ ok: false, code: "bad_request" });
    expect(f.calls).toHaveLength(0);
  });

  it("ไฟล์หายไป (ถูกกวาด/ไม่มีสิทธิ์) → not_found บอกจำนวน", async () => {
    const a = ref(), b = ref();
    const f = fakeClient({
      createSignedUrls: async (paths) => ({
        data: paths.map((p) => ({ path: p, signedUrl: p === a ? "u" : "", error: p === a ? null : "Object not found" })),
        error: null,
      }),
    });
    expect(await verifyAttachmentsExist(f.client, [a, b])).toMatchObject({ ok: false, code: "not_found" });
    expect(await verifyAttachmentsExist(f.client, [a])).toMatchObject({ ok: true, count: 1 });
  });
});

describe("sweepOwnOrphans — กวาดไฟล์ลอยของตัวเอง", () => {
  it("ลบเฉพาะที่ DB รายงานว่าลอย", async () => {
    const a = ref(), b = ref();
    const f = fakeClient({ rpc: async (fn, args) => ({ data: fn === "fn_attachment_orphans" && args?.p_scope === "mine" ? [{ path: a }, { path: b }] : [], error: null }) });
    expect(await sweepOwnOrphans(f.client)).toMatchObject({ ok: true, found: 2, removed: 2 });
  });

  it("ไม่มีไฟล์ลอย → ไม่เรียกลบ", async () => {
    const f = fakeClient();
    expect(await sweepOwnOrphans(f.client)).toMatchObject({ ok: true, found: 0, removed: 0 });
    expect(f.count("remove")).toBe(0);
  });

  it("ขอเฉพาะ scope mine เสมอ (ไม่มีทางขอ all จากชั้นนี้)", async () => {
    let seen: unknown;
    const f = fakeClient({ rpc: async (_fn, args) => ((seen = args), { data: [], error: null }) });
    await sweepOwnOrphans(f.client);
    expect(seen).toEqual({ p_scope: "mine" });
  });

  it("DB ตอบ error (ยังไม่ apply migration) → server error ไม่เงียบ", async () => {
    const f = fakeClient({ rpc: async () => ({ data: null, error: { message: "function does not exist" } }) });
    expect(await sweepOwnOrphans(f.client)).toMatchObject({ ok: false, code: "server" });
  });

  it("Storage ปฏิเสธลบบางไฟล์ (เพิ่งมีรายการอ้าง) → นับเฉพาะที่ลบจริง", async () => {
    const a = ref(), b = ref();
    const f = fakeClient({
      rpc: async () => ({ data: [{ path: a }, { path: b }], error: null }),
      remove: async () => ({ data: [{ name: a }], error: null }),
    });
    expect(await sweepOwnOrphans(f.client)).toMatchObject({ ok: true, found: 2, removed: 1 });
  });
});

describe("mapStorageError", () => {
  it("แยกสาเหตุหลัก", () => {
    expect(mapStorageError({ message: "new row violates row-level security policy" }).code).toBe("forbidden");
    expect(mapStorageError({ message: "The object exceeded the maximum allowed size" }).code).toBe("too_large");
    expect(mapStorageError({ message: "mime type text/html is not supported" }).code).toBe("unsupported_type");
    expect(mapStorageError({ message: "boom", statusCode: "500" }).code).toBe("server");
  });
});
