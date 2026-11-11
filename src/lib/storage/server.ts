import {
  ATTACHMENT_BUCKET,
  MAX_ATTACHMENT_BYTES,
  REMOVE_CHUNK,
  SIGNED_URL_MAX_SECONDS,
  SIGNED_URL_MIN_SECONDS,
  SIGNED_URL_TTL_SECONDS,
  STORAGE_TIMEOUT_MS,
  type AllowedMime,
} from "./config";
import { fail, MESSAGES, type Result, type StorageFailure } from "./errors";
import { buildObjectPath, isUuid, parseAttachmentRef, PathError } from "./path";
import { validateUpload } from "./validate";

/**
 * การทำงานกับ Storage — รับ client เข้ามา (ฉีดได้ในเทสต์) · ใช้ client ของผู้ใช้เองเท่านั้น
 *
 * **client ต้องเป็น publishable key + session ของผู้ใช้** (createClient ใน lib/supabase/server)
 * ทุกคำสั่งจึงผ่าน RLS ของ storage.objects ในฐานะผู้ใช้คนนั้น · ไฟล์นี้ไม่รู้จัก service-role
 *
 * ทุกการเรียกมี timeout (กันหน้าเว็บค้างเมื่อ Storage ล่ม) · อ่านซ้ำ 1 ครั้งเมื่อเครือข่ายหลุด
 * ส่วนการเขียน **ไม่ retry อัตโนมัติ** (path ใหม่ทุกครั้ง retry เองอาจได้ไฟล์ซ้ำ) → ให้ผู้ใช้กดลองใหม่
 */

type ApiError = { message?: string; statusCode?: string | number; status?: number; name?: string } | null;

export type StorageBucketApi = {
  upload(
    path: string,
    body: Uint8Array,
    options: { contentType?: string; upsert?: boolean; cacheControl?: string }
  ): PromiseLike<{ data: { path: string } | null; error: ApiError }>;
  createSignedUrl(path: string, expiresIn: number): PromiseLike<{ data: { signedUrl: string } | null; error: ApiError }>;
  createSignedUrls(
    paths: string[],
    expiresIn: number
  ): PromiseLike<{ data: { path: string | null; signedUrl: string; error: string | null }[] | null; error: ApiError }>;
  remove(paths: string[]): PromiseLike<{ data: { name: string }[] | null; error: ApiError }>;
};

export type StorageClientLike = {
  storage: { from(bucket: string): StorageBucketApi };
  rpc(fn: string, args?: Record<string, unknown>): PromiseLike<{ data: unknown; error: { message: string } | null }>;
};

const bucket = (c: StorageClientLike) => c.storage.from(ATTACHMENT_BUCKET);

class TimeoutError extends Error {}

function withTimeout<T>(p: PromiseLike<T>, ms = STORAGE_TIMEOUT_MS): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const t = new Promise<never>((_, rej) => {
    timer = setTimeout(() => rej(new TimeoutError("timeout")), ms);
  });
  return Promise.race([Promise.resolve(p), t]).finally(() => clearTimeout(timer));
}

/** เรียกแล้วแปลง exception เป็น StorageFailure (ไม่ throw ใส่หน้าจอ) */
async function guarded<T>(run: () => PromiseLike<T>, retryReads = false): Promise<T | StorageFailure> {
  const attempts = retryReads ? 2 : 1;
  let last: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await withTimeout(run());
    } catch (e) {
      last = e;
      if (e instanceof TimeoutError) break; // ช้าอยู่แล้ว อย่าซ้ำให้ช้าสองเท่า
    }
  }
  if (last instanceof TimeoutError) return fail("timeout", MESSAGES.timeout);
  return fail("network", MESSAGES.network, { detail: last instanceof Error ? last.message : String(last) });
}

const isFailure = (x: unknown): x is StorageFailure =>
  typeof x === "object" && x !== null && (x as { ok?: unknown }).ok === false;

/** แปลง error ของ Storage API เป็นรหัสของเรา — ดูทั้งข้อความและ status เพราะรูปแบบต่างตามรุ่น */
export function mapStorageError(err: NonNullable<ApiError>): StorageFailure {
  const msg = String(err.message ?? "");
  const status = Number(err.statusCode ?? err.status ?? 0);
  const detail = `${status || "?"} ${msg}`.trim();
  if (/row-level security|unauthorized|not authorized|violates/i.test(msg) || status === 401 || status === 403) {
    return fail("forbidden", MESSAGES.forbidden, { detail });
  }
  if (/bucket not found/i.test(msg)) return fail("bucket_missing", MESSAGES.bucket_missing, { detail });
  if (/maximum allowed size|payload too large|too large/i.test(msg) || status === 413) {
    return fail("too_large", MESSAGES.too_large(MAX_ATTACHMENT_BYTES), { detail });
  }
  if (/mime type|not supported|unsupported/i.test(msg) || status === 415) {
    return fail("unsupported_type", MESSAGES.unsupported_type, { detail });
  }
  if (/not found|does not exist/i.test(msg) || status === 404) return fail("not_found", MESSAGES.not_found, { detail });
  return fail("server", MESSAGES.server, { detail });
}

// ---------------------------------------------------------------- อัปโหลด

export type UploadedAttachment = { ref: string; mime: AllowedMime; size: number };

/**
 * อัปโหลดไฟล์ → คืน `ref` ที่เก็บใน `attachments`
 * ตรวจไบต์จริงก่อนแตะ Storage · ไม่มีอะไรจากชื่อไฟล์ผู้ใช้เข้าไปใน path
 */
export async function uploadAttachment(
  client: StorageClientLike,
  args: { userId: string; ownerId: string; bytes: Uint8Array | null | undefined }
): Promise<Result<UploadedAttachment>> {
  if (!isUuid(args.userId)) return fail("not_signed_in", MESSAGES.not_signed_in);
  if (!isUuid(args.ownerId)) return fail("bad_request", "ต้องระบุผู้ถือ (owner) ของรายการที่ไฟล์นี้สังกัด");

  const v = validateUpload(args.bytes);
  if (!v.ok) return v;

  let path: string;
  try {
    path = buildObjectPath({ ownerId: args.ownerId, uploaderId: args.userId, ext: v.ext });
  } catch (e) {
    return fail("bad_request", e instanceof PathError ? e.message : "path ไม่ถูกต้อง");
  }

  const res = await guarded(() =>
    bucket(client).upload(path, args.bytes as Uint8Array, {
      contentType: v.mime, // ชนิดที่ตรวจจากไบต์ ไม่ใช่ที่ client อ้าง
      upsert: false, // เขียนทับไม่ได้ (policy ก็ไม่มี update)
      cacheControl: "0",
    })
  );
  if (isFailure(res)) return res;
  if (res.error) return mapStorageError(res.error);
  return { ok: true, ref: path, mime: v.mime, size: v.size };
}

// ---------------------------------------------------------------- ลิงก์ดาวน์โหลด

export function clampTtl(ttl: unknown): number {
  const n = typeof ttl === "number" && Number.isFinite(ttl) ? Math.floor(ttl) : SIGNED_URL_TTL_SECONDS;
  return Math.min(SIGNED_URL_MAX_SECONDS, Math.max(SIGNED_URL_MIN_SECONDS, n));
}

/** ลิงก์มีอายุจำกัด · Storage ตรวจสิทธิ์ตอนออกลิงก์ตาม policy select (ไม่มีสิทธิ์ = not_found) */
export async function createAttachmentUrl(
  client: StorageClientLike,
  ref: unknown,
  ttl?: number
): Promise<Result<{ url: string; expiresIn: number }>> {
  if (!parseAttachmentRef(ref)) return fail("bad_request", "รหัสไฟล์ไม่ถูกต้อง");
  const expiresIn = clampTtl(ttl);
  const res = await guarded(() => bucket(client).createSignedUrl(ref as string, expiresIn), true);
  if (isFailure(res)) return res;
  if (res.error || !res.data?.signedUrl) {
    // Storage ตอบเหมือนกันทั้ง "ไม่มีไฟล์" และ "ไม่มีสิทธิ์" — ไม่บอกให้ต่างกัน (กันสืบว่ามีไฟล์ไหม)
    return fail("not_found", MESSAGES.not_found, { detail: res.error?.message });
  }
  return { ok: true, url: res.data.signedUrl, expiresIn };
}

// ---------------------------------------------------------------- ตรวจว่ามีไฟล์จริง

/**
 * ก่อนบันทึกรายการ: ทุก ref ต้องเป็นไฟล์จริงที่ผู้ใช้คนนี้เปิดได้
 * — ไฟล์ถูกกวาดทิ้งระหว่างที่ฟอร์มเปิดค้างข้ามคืน / ref ปลอม / ชื่อไฟล์จำลอง ถูกจับตรงนี้
 */
export async function verifyAttachmentsExist(
  client: StorageClientLike,
  refs: unknown
): Promise<Result<{ count: number }>> {
  if (!Array.isArray(refs) || refs.length === 0) {
    return fail("bad_request", "ไม่มีไฟล์แนบให้ตรวจ");
  }
  const bad = refs.filter((r) => !parseAttachmentRef(r));
  if (bad.length) {
    return fail("bad_request", "มีไฟล์แนบที่ไม่ใช่ไฟล์จริงใน Storage (เช่นชื่อไฟล์จำลอง) — แนบไฟล์ใหม่", {
      detail: bad.map((b) => String(b).slice(0, 80)).join(" | "),
    });
  }
  const unique = [...new Set(refs as string[])];
  const res = await guarded(() => bucket(client).createSignedUrls(unique, SIGNED_URL_MIN_SECONDS), true);
  if (isFailure(res)) return res;
  if (res.error) return mapStorageError(res.error);
  const okPaths = new Set((res.data ?? []).filter((d) => !d.error && d.path).map((d) => d.path as string));
  const missing = unique.filter((u) => !okPaths.has(u));
  if (missing.length) {
    return fail("not_found", `ไฟล์แนบหายไป ${missing.length} ไฟล์ — แนบใหม่ก่อนบันทึก`, { detail: missing.join(", ") });
  }
  return { ok: true, count: unique.length };
}

// ---------------------------------------------------------------- ลบ

export type RemoveReport = { removed: string[]; kept: string[] };

/**
 * ลบไฟล์ — ลบได้เฉพาะ "ของตัวเองที่ยังไม่มีรายการ/ร่างอ้าง" (policy + trigger ใน DB)
 * Storage API ตอบสำเร็จ (ไม่ error) แม้ RLS กรองทิ้งทั้งหมด → ต้องนับว่าลบจริงกี่ไฟล์
 * ไฟล์ที่ไม่ได้ลบอยู่ใน `kept` ให้หน้าจอบอกผู้ใช้ (ไม่ใช่ทำเป็นว่าลบแล้ว)
 */
export async function removeAttachments(client: StorageClientLike, refs: unknown): Promise<Result<RemoveReport>> {
  if (!Array.isArray(refs)) return fail("bad_request", "ต้องส่งรายการไฟล์ที่จะลบ");
  const valid = [...new Set(refs.filter((r): r is string => !!parseAttachmentRef(r)))];
  const invalid = refs.filter((r) => !parseAttachmentRef(r));
  if (valid.length === 0) {
    return invalid.length
      ? fail("bad_request", "รหัสไฟล์ไม่ถูกต้อง")
      : { ok: true, removed: [], kept: [] };
  }

  const removed: string[] = [];
  for (let i = 0; i < valid.length; i += REMOVE_CHUNK) {
    const chunk = valid.slice(i, i + REMOVE_CHUNK);
    const res = await guarded(() => bucket(client).remove(chunk));
    if (isFailure(res)) return res;
    if (res.error) return mapStorageError(res.error);
    const gone = new Set((res.data ?? []).map((d) => d.name));
    for (const p of chunk) if (gone.has(p)) removed.push(p);
  }
  const removedSet = new Set(removed);
  return { ok: true, removed, kept: [...valid.filter((p) => !removedSet.has(p)), ...invalid.map(String)] };
}

// ---------------------------------------------------------------- ไฟล์ลอย

/**
 * กวาดไฟล์ลอยของ "ตัวเอง" (อัปโหลดแล้วบันทึกรายการไม่สำเร็จ แล้วเก่ากว่าช่วงผ่อนผันใน settings)
 * ถามรายการจาก DB (fn_attachment_orphans('mine')) แล้วลบผ่าน Storage API ด้วยสิทธิ์ตัวเอง
 * ไม่ใช้ service-role · ไม่ลบด้วย SQL ตรง (แถวหายแต่ไฟล์จริงค้าง) · ของที่ถูกอ้างลบไม่ได้อยู่แล้ว
 */
export async function sweepOwnOrphans(client: StorageClientLike): Promise<Result<{ found: number; removed: number }>> {
  const res = await guarded(() => client.rpc("fn_attachment_orphans", { p_scope: "mine" }), true);
  if (isFailure(res)) return res;
  if (res.error) {
    return fail("server", "ดึงรายการไฟล์ลอยไม่สำเร็จ — ต้อง apply migration 20261008000009 ก่อน", { detail: res.error.message });
  }
  const rows = Array.isArray(res.data) ? (res.data as { path?: unknown }[]) : [];
  const paths = rows.map((r) => r.path).filter((p): p is string => typeof p === "string");
  if (paths.length === 0) return { ok: true, found: 0, removed: 0 };
  const rm = await removeAttachments(client, paths);
  if (!rm.ok) return rm;
  return { ok: true, found: paths.length, removed: rm.removed.length };
}
