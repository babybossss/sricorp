import { ALLOWED_TYPES, type AllowedExt } from "./config";

/**
 * path ของไฟล์ใน Storage  =  <owner_id>/<uploader_id>/<uuid>.<ext>
 *
 * - **ชื่อไฟล์ที่ผู้ใช้ตั้งไม่เคยเป็นส่วนหนึ่งของ path** → path traversal เกิดไม่ได้ ชื่อซ้ำไม่ทับกัน
 *   (uuid สุ่มใหม่ทุกครั้ง) ชื่อไทย/ยาว/อักขระพิเศษไม่มีผลอะไร
 * - รูปแบบนี้ **ซ้ำกับ regex ใน policy** ของ migration 20261008000009 → policy เป็นตัวบังคับจริง
 *   ไฟล์นี้แค่สร้างให้ตรงและเช็คก่อนส่ง (เทสต์ path.test.ts เทียบสองฝั่ง)
 * - ref ที่เก็บใน `attachments` (text[]) คือ path ทั้งเส้นนี้
 */

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const EXTS = Object.values(ALLOWED_TYPES).join("|");

export const ATTACHMENT_REF_RE = new RegExp(`^(${UUID})/(${UUID})/(${UUID})\\.(${EXTS})$`);
const UUID_RE = new RegExp(`^${UUID}$`);

export type AttachmentRef = { ownerId: string; uploaderId: string; id: string; ext: AllowedExt };

/** uuid ตัวพิมพ์เล็กเท่านั้น (auth.uid()::text เป็นตัวพิมพ์เล็ก — policy เทียบข้อความตรงๆ) */
export const isUuid = (s: unknown): s is string => typeof s === "string" && UUID_RE.test(s);

export function parseAttachmentRef(ref: unknown): AttachmentRef | null {
  if (typeof ref !== "string") return null;
  const m = ATTACHMENT_REF_RE.exec(ref);
  if (!m) return null;
  return { ownerId: m[1], uploaderId: m[2], id: m[3], ext: m[4] as AllowedExt };
}

/** ref นี้เป็นไฟล์จริงใน Storage (รูปแบบถูก) หรือแค่ข้อความ เช่น "สลิป.jpg" ของเดิม */
export const isAttachmentRef = (ref: unknown): ref is string => parseAttachmentRef(ref) !== null;

export class PathError extends Error {}

export function buildObjectPath(args: {
  ownerId: string;
  uploaderId: string;
  ext: AllowedExt;
  /** ใส่เฉพาะในเทสต์ */
  id?: string;
}): string {
  const owner = String(args.ownerId ?? "").toLowerCase();
  const uploader = String(args.uploaderId ?? "").toLowerCase();
  const id = args.id ?? crypto.randomUUID();
  if (!isUuid(owner)) throw new PathError("owner_id ไม่ใช่ uuid");
  if (!isUuid(uploader)) throw new PathError("uploader_id ไม่ใช่ uuid");
  if (!isUuid(id)) throw new PathError("id ไม่ใช่ uuid");
  if (!(Object.values(ALLOWED_TYPES) as string[]).includes(args.ext)) throw new PathError("นามสกุลไม่อยู่ในรายการที่รับ");
  return `${owner}/${uploader}/${id}.${args.ext}`;
}

/**
 * ชื่อสำหรับ **แสดง** เท่านั้น (ไม่ใช่ path) — ตัดอักขระควบคุม · ตัวคั่น path · ตัวกลับทิศข้อความ (RLO)
 * แล้วจำกัดความยาว · ว่างแล้วคืนค่าเริ่มต้น
 */
export function safeDisplayName(name: unknown, fallback = "ไฟล์แนบ"): string {
  if (typeof name !== "string") return fallback;
  const cleaned = name
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f\u007f‎‏‪-‮⁦-⁩]/g, "")
    .replace(/[\\/]+/g, "_")
    .replace(/^\.+/, "")
    .trim();
  if (!cleaned) return fallback;
  return cleaned.length > 80 ? `${cleaned.slice(0, 77)}...` : cleaned;
}
