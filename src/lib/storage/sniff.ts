import { ALLOWED_TYPES, type AllowedExt, type AllowedMime } from "./config";

/**
 * ดูชนิดไฟล์จากไบต์ต้นไฟล์ (magic bytes) — **ไม่เชื่อ** Content-Type หรือนามสกุลที่ client ส่งมา
 * เพราะสองอย่างนั้นปลอมได้ในบรรทัดเดียว · คืน null = ไม่รู้จัก = ปฏิเสธ
 *
 * ตั้งใจเข้มกว่าที่จำเป็น: ต้องเริ่มที่ไบต์แรก (PDF ตามสเปคยอมให้มีขยะนำหน้า 1 KB — เราไม่ยอม
 * เพราะนั่นคือช่องของไฟล์ polyglot)
 */

export type Sniffed = { mime: AllowedMime; ext: AllowedExt };

const startsWith = (b: Uint8Array, sig: readonly number[], at = 0) =>
  b.length >= at + sig.length && sig.every((v, i) => b[at + i] === v);

const ascii = (b: Uint8Array, at: number, len: number) =>
  b.length >= at + len ? String.fromCharCode(...b.subarray(at, at + len)) : "";

/** brand ของ HEIF/HEIC ที่มือถือใช้ (iPhone = heic · Android รุ่นใหม่ = heic/mif1) */
const HEIC_BRANDS = new Set(["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "heif"]);

export function sniffType(bytes: Uint8Array): Sniffed | null {
  if (startsWith(bytes, [0xff, 0xd8, 0xff])) return pick("image/jpeg");
  if (startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return pick("image/png");
  if (ascii(bytes, 0, 4) === "RIFF" && ascii(bytes, 8, 4) === "WEBP") return pick("image/webp");
  if (ascii(bytes, 0, 5) === "%PDF-") return pick("application/pdf");
  if (ascii(bytes, 4, 4) === "ftyp" && HEIC_BRANDS.has(ascii(bytes, 8, 4))) return pick("image/heic");
  return null;
}

function pick(mime: AllowedMime): Sniffed {
  return { mime, ext: ALLOWED_TYPES[mime] };
}
