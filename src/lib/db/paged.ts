/**
 * อ่านทุกแถวของ query เดียวแบบแบ่งหน้า — PostgREST ตัดผลที่ `max-rows` (ค่าตั้งต้นของ Supabase = 1,000)
 * **เงียบๆ** ต่อให้ขอ `.limit(5000)` ก็ได้ 1,000 แถวโดยไม่มี error · งบที่รวมจากแถวที่ถูกตัดคือตัวเลขผิดที่ดูเหมือนถูก
 *
 * - ต้องมี `order` ที่คงที่ (ผู้เรียกใส่ให้ใน `build`) ไม่งั้นหน้าที่ 2 อาจซ้ำ/ข้ามแถวของหน้าที่ 1
 * - เกินเพดาน `maxRows` = ปฏิเสธ ไม่ตัดแล้วบอกว่าครบ · `stopAfter` = ขอแค่ N แถวแรก (คืน `truncated`)
 */
export const PAGE_SIZE = 1000;

type PageQuery<T> = { range: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }> };

export async function fetchAllPages<T>(
  build: () => PageQuery<T>,
  opts: { pageSize?: number; maxRows?: number; stopAfter?: number } = {}
): Promise<{ ok: true; rows: T[]; truncated: boolean } | { ok: false; error: string }> {
  const pageSize = opts.pageSize ?? PAGE_SIZE;
  const maxRows = opts.maxRows ?? 100_000;
  const rows: T[] = [];
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await build().range(from, from + pageSize - 1);
    if (error) return { ok: false, error: error.message };
    const page = data ?? [];
    rows.push(...page);
    // ขอแค่ N แถวแรก (เช่น รายการล่าสุด) — หยุดที่ N แล้วบอกว่าถูกตัด ไม่ใช่ปฏิเสธ
    if (opts.stopAfter !== undefined && rows.length >= opts.stopAfter) {
      return { ok: true, rows: rows.slice(0, opts.stopAfter), truncated: rows.length > opts.stopAfter || page.length === pageSize };
    }
    if (rows.length > maxRows) {
      return { ok: false, error: `มีรายการมากกว่า ${maxRows.toLocaleString("en-US")} บรรทัด — ปฏิเสธแทนที่จะแสดงตัวเลขจากข้อมูลที่ไม่ครบ` };
    }
    if (page.length < pageSize) return { ok: true, rows, truncated: false };
  }
}
