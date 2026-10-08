import { beforeEach, describe, expect, it, vi } from "vitest";
import { MAX_ATTACHMENT_BYTES } from "../config";
import { isSameOrigin, readCappedBody, readUploadForm } from "../http";
import { buildObjectPath } from "../path";
import { storageReadiness } from "../readiness";
import { fakeClient, JPEG, OWNER, USER } from "./helpers";

const SUPA = "NEXT_PUBLIC_SUPABASE_URL";
const KEY = "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY";
const ANON = "NEXT_PUBLIC_SUPABASE_ANON_KEY";

function setEnv(url?: string, key?: string) {
  for (const [k, v] of [[SUPA, url], [KEY, key], [ANON, undefined]] as const) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
}

function multipart(parts: { file?: Uint8Array | null; ownerId?: string }, headers: Record<string, string> = {}) {
  const fd = new FormData();
  if (parts.ownerId !== undefined) fd.set("ownerId", parts.ownerId);
  if (parts.file !== undefined && parts.file !== null) fd.set("file", new Blob([parts.file as BlobPart], { type: "image/jpeg" }), "สลิป.jpg");
  return new Request("http://localhost/api/attachments", { method: "POST", body: fd, headers });
}

describe("storageReadiness — ไม่มี env ต้องบอก ไม่ตกไปใช้ของจำลอง", () => {
  beforeEach(() => setEnv());

  it("ไม่มี env → not_configured พร้อมชื่อตัวแปร (ไม่มีค่า)", () => {
    const r = storageReadiness();
    expect(r).toMatchObject({ ok: false, code: "not_configured" });
    const f = r as { problems: string[]; message: string };
    expect(f.problems.join()).toContain(SUPA);
    expect(f.problems.join()).toContain(KEY);
    expect(f.message).toContain("ไม่ใช้ไฟล์จำลอง");
  });

  it("ใส่ service-role key มา → ปฏิเสธ (ไม่ใช้คีย์ที่ข้าม RLS)", () => {
    setEnv("https://x.supabase.co", "sb_secret_abc");
    expect(storageReadiness()).toMatchObject({ ok: false, code: "not_configured" });
  });

  it("env ครบ (publishable) → พร้อม", () => {
    setEnv("https://x.supabase.co", "sb_publishable_abc");
    expect(storageReadiness()).toEqual({ ok: true });
  });
});

describe("readCappedBody / readUploadForm", () => {
  it("content-length เกิน → ปฏิเสธโดยไม่อ่าน body", async () => {
    let read = false;
    const body = new ReadableStream({ pull(c) { read = true; c.close(); } }, { highWaterMark: 0 });
    const req = new Request("http://x", { method: "POST", body, headers: { "content-length": String(MAX_ATTACHMENT_BYTES * 3) }, duplex: "half" } as RequestInit);
    expect(await readCappedBody(req, MAX_ATTACHMENT_BYTES)).toMatchObject({ ok: false, code: "too_large" });
    expect(read).toBe(false);
  });

  it("stream ที่โกหก content-length (หรือไม่มี) → หยุดอ่านเมื่อเกินเพดาน", async () => {
    let pulled = 0;
    const body = new ReadableStream({ pull(c) { pulled++; c.enqueue(new Uint8Array(1024 * 1024)); } }, { highWaterMark: 0 });
    const req = new Request("http://x", { method: "POST", body, duplex: "half" } as RequestInit);
    expect(await readCappedBody(req, MAX_ATTACHMENT_BYTES)).toMatchObject({ ok: false, code: "too_large" });
    expect(pulled).toBeLessThan(10);
  });

  it("ไม่ใช่ multipart → bad_request", async () => {
    const req = new Request("http://x", { method: "POST", body: "{}", headers: { "content-type": "application/json" } });
    expect(await readUploadForm(req)).toMatchObject({ ok: false, code: "bad_request" });
  });

  it("multipart ไม่มีฟิลด์ file → empty_file · file ว่าง → ไบต์ว่าง", async () => {
    expect(await readUploadForm(multipart({ ownerId: OWNER }))).toMatchObject({ ok: false, code: "empty_file" });
    const r = await readUploadForm(multipart({ ownerId: OWNER, file: new Uint8Array(0) }));
    expect(r.ok && r.bytes.byteLength).toBe(0);
  });

  it("ปกติ: ได้ไบต์ + ฟิลด์ (ชื่อไฟล์ไทยไม่ถูกใช้)", async () => {
    const r = await readUploadForm(multipart({ ownerId: OWNER, file: JPEG }));
    expect(r.ok && r.fields.ownerId).toBe(OWNER);
    expect(r.ok && Array.from(r.bytes)).toEqual(Array.from(JPEG));
  });
});

describe("isSameOrigin", () => {
  const mk = (h: Record<string, string>) => new Request("http://app.example/api/attachments", { method: "POST", headers: h });
  it("origin ตรง host → ผ่าน · ต่างเว็บ → ไม่ผ่าน · ไม่มี origin (ไม่ใช่ browser) → ผ่าน", () => {
    expect(isSameOrigin(mk({ origin: "http://app.example", host: "app.example" }))).toBe(true);
    expect(isSameOrigin(mk({ origin: "https://evil.example", host: "app.example" }))).toBe(false);
    expect(isSameOrigin(mk({ origin: "null", host: "app.example" }))).toBe(false);
    expect(isSameOrigin(mk({ host: "app.example" }))).toBe(true);
  });
});

// ---- route handler จริง โดยจำลอง session ของ Supabase ----
const auth = { user: { id: USER } as { id: string } | null };
const fake = fakeClient();
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({
    auth: { getUser: async () => ({ data: { user: auth.user }, error: null }) },
    storage: fake.client.storage,
    rpc: fake.client.rpc,
  }),
}));

describe("POST /api/attachments", () => {
  beforeEach(() => {
    setEnv("https://x.supabase.co", "sb_publishable_abc");
    auth.user = { id: USER };
    fake.calls.length = 0;
  });

  it("ไม่มี env → 503 บอกชื่อตัวแปร และไม่แตะ Storage", async () => {
    setEnv();
    const { POST } = await import("@/app/api/attachments/route");
    const res = await POST(multipart({ ownerId: OWNER, file: JPEG }));
    expect(res.status).toBe(503);
    const j = await res.json();
    expect(j).toMatchObject({ ok: false, code: "not_configured" });
    expect(j.problems.join()).toContain(KEY);
    expect(fake.calls).toHaveLength(0);
  });

  it("ไม่ล็อกอิน → 401", async () => {
    auth.user = null;
    const { POST } = await import("@/app/api/attachments/route");
    expect((await POST(multipart({ ownerId: OWNER, file: JPEG }))).status).toBe(401);
    expect(fake.calls).toHaveLength(0);
  });

  it("ข้ามเว็บ (CSRF) → 403", async () => {
    const { POST } = await import("@/app/api/attachments/route");
    const res = await POST(multipart({ ownerId: OWNER, file: JPEG }, { origin: "https://evil.example", host: "localhost" }));
    expect(res.status).toBe(403);
    expect(fake.calls).toHaveLength(0);
  });

  it("ไม่มีไฟล์ / ไฟล์ว่าง / ชนิดผิด → 400/415 ไม่แตะ Storage", async () => {
    const { POST } = await import("@/app/api/attachments/route");
    expect((await POST(multipart({ ownerId: OWNER }))).status).toBe(400);
    expect((await POST(multipart({ ownerId: OWNER, file: new Uint8Array(0) }))).status).toBe(400);
    const exe = Uint8Array.from(Buffer.from("MZ......"));
    expect((await POST(multipart({ ownerId: OWNER, file: exe }))).status).toBe(415);
    expect(fake.calls.filter((c) => c.op === "upload")).toHaveLength(0);
  });

  it("ไม่ส่ง ownerId → 400", async () => {
    const { POST } = await import("@/app/api/attachments/route");
    expect((await POST(multipart({ file: JPEG }))).status).toBe(400);
  });

  it("ใหญ่เกิน → 413 ก่อนอ่านทั้งก้อน", async () => {
    const { POST } = await import("@/app/api/attachments/route");
    const big = new Uint8Array(MAX_ATTACHMENT_BYTES + 200_000);
    big.set(JPEG);
    expect((await POST(multipart({ ownerId: OWNER, file: big }))).status).toBe(413);
  });

  it("สำเร็จ → 201 พร้อม ref ที่ผู้ใช้เป็นเจ้าของ path (ไม่ใช่ชื่อไฟล์ที่ส่งมา)", async () => {
    const { POST } = await import("@/app/api/attachments/route");
    const res = await POST(multipart({ ownerId: OWNER, file: JPEG }));
    expect(res.status).toBe(201);
    const j = await res.json();
    expect(j.ref.startsWith(`${OWNER}/${USER}/`)).toBe(true);
    expect(j.ref).not.toContain("สลิป");
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  it("GET ลิงก์: ref เสีย → 400 · ปกติ → ลิงก์อายุจำกัด", async () => {
    const { GET } = await import("@/app/api/attachments/route");
    expect((await GET(new Request("http://localhost/api/attachments?ref=../../x"))).status).toBe(400);
    expect((await GET(new Request("http://localhost/api/attachments"))).status).toBe(400);
    const p = buildObjectPath({ ownerId: OWNER, uploaderId: USER, ext: "jpg" });
    const res = await GET(new Request(`http://localhost/api/attachments?ref=${encodeURIComponent(p)}`));
    expect(res.status).toBe(200);
    expect((await res.json()).expiresIn).toBeLessThanOrEqual(900);
  });

  it("DELETE: ไม่ส่ง body / ไม่ใช่ JSON → 400", async () => {
    const { DELETE } = await import("@/app/api/attachments/route");
    expect((await DELETE(new Request("http://localhost/api/attachments", { method: "DELETE" }))).status).toBe(400);
    expect((await DELETE(new Request("http://localhost/api/attachments", { method: "DELETE", body: "{}" }))).status).toBe(400);
  });

  it("verify: ชื่อไฟล์จำลองไม่ผ่าน → 400", async () => {
    const { POST } = await import("@/app/api/attachments/verify/route");
    const res = await POST(new Request("http://localhost/api/attachments/verify", { method: "POST", body: JSON.stringify({ refs: ["สลิป.jpg"] }) }));
    expect(res.status).toBe(400);
  });
});
