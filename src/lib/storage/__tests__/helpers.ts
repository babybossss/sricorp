import type { StorageBucketApi, StorageClientLike } from "../server";

export const OWNER = "a1b2c3d4-1111-4111-8111-aabbccddeeff";
export const OTHER_OWNER = "b2c3d4e5-2222-4222-8222-bbccddeeff00";
export const USER = "c3d4e5f6-3333-4333-8333-ccddeeff0011";

/** ไบต์ต้นไฟล์ของแต่ละชนิด + เติมให้ไม่ว่าง */
const pad = (head: number[], n = 64) => Uint8Array.from([...head, ...new Array(n).fill(7)]);
export const JPEG = pad([0xff, 0xd8, 0xff, 0xe0]);
export const PNG = pad([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
export const PDF = pad([...Buffer.from("%PDF-1.7\n")]);
export const WEBP = pad([...Buffer.from("RIFF"), 1, 0, 0, 0, ...Buffer.from("WEBPVP8 ")]);
export const HEIC = pad([0, 0, 0, 0x18, ...Buffer.from("ftypheic")]);
export const EXE = pad([...Buffer.from("MZ")]);
export const HTML = Uint8Array.from(Buffer.from("<html><script>alert(1)</script></html>"));
export const SVG = Uint8Array.from(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" onload="x()"/>'));

export type Call = { op: string; args: unknown[] };

/** Storage จำลอง — บันทึกทุกคำสั่งที่ถูกยิง เพื่อเช็คว่า "ไม่ถูกเรียก" ในเคสที่ต้องปฏิเสธก่อน */
export function fakeClient(over: Partial<StorageBucketApi> & { rpc?: StorageClientLike["rpc"] } = {}) {
  const calls: Call[] = [];
  const rec = <T>(op: string, v: T) => (...args: unknown[]) => {
    calls.push({ op, args });
    return v;
  };
  const bucket: StorageBucketApi = {
    upload: async (...a) => (rec("upload", null)(...a), { data: { path: String(a[0]) }, error: null }),
    createSignedUrl: async (...a) => (rec("sign", null)(...a), { data: { signedUrl: `https://x/y?t=1&p=${a[0]}` }, error: null }),
    createSignedUrls: async (paths, ...r) => (
      rec("signMany", null)(paths, ...r),
      { data: (paths as string[]).map((p) => ({ path: p, signedUrl: "u", error: null })), error: null }
    ),
    remove: async (paths) => (rec("remove", null)(paths), { data: (paths as string[]).map((name) => ({ name })), error: null }),
    ...over,
  };
  const client: StorageClientLike = {
    storage: { from: (b) => (rec("from", null)(b), bucket) },
    rpc: over.rpc ?? (async () => ({ data: [], error: null })),
  };
  return { client, calls, count: (op: string) => calls.filter((c) => c.op === op).length };
}
