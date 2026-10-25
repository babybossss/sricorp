import type { SupabaseClient } from "@supabase/supabase-js";
import { fetchAllPages } from "./paged";
import { buildFxContext, type FxAccountContext, type FxBankLine, type FxDiffLine, type FxRate } from "./fx-context";
import type { Reference } from "./reference-types";

type Db = Pick<SupabaseClient, "from">;

export type FxContextState = { ok: true; ctx: FxAccountContext } | { ok: false; message: string };

/**
 * อ่านข้อมูลเงินตราของบัญชีหนึ่งจาก **สมุดที่ post แล้ว** (`v_ledger_posted` · D-107) ผ่าน RLS ของผู้ใช้
 *
 * บัญชีและผู้ถือตรวจจาก `Reference` (อ่านสดจาก DB) — ไม่เชื่อ id ที่ส่งมาจากหน้าจอเกินกว่าใช้เป็นกุญแจค้น:
 * บัญชีต้องเป็นของผู้ถือที่ระบุ · ต้องเป็นบัญชีสกุลต่างประเทศ (บัญชีบาทไม่มีเงินตราให้แปลง/แลก)
 */
export async function readFxContext(
  db: Db,
  ref: Pick<Reference, "banks" | "coaCodeById">,
  req: { ownerId: string; bankAccountId: string }
): Promise<FxContextState> {
  const bank = ref.banks.find((b) => b.id === req.bankAccountId);
  if (!bank) return { ok: false, message: "ไม่พบบัญชีธนาคารนี้ในระบบ — โหลดหน้าใหม่แล้วเลือกใหม่" };
  if (bank.ownerId !== req.ownerId) return { ok: false, message: "บัญชีนี้ไม่ใช่ของผู้ถือที่เลือก" };
  if (bank.currency === "THB") return { ok: false, message: `บัญชี "${bank.name}" เป็นบัญชีบาท ไม่มีเงินตราต่างประเทศให้แปลงค่าหรือแลก` };

  const id3410 = Object.entries(ref.coaCodeById).find(([, code]) => code === "3410")?.[0];
  if (!id3410) return { ok: false, message: "หา id ของบัญชีผลต่างอัตราแลกเปลี่ยน (3410) ในผังบัญชีไม่เจอ — ปฏิเสธแทนที่จะเดาผลต่างที่ค้าง" };

  try {
    const [bankLines, diffLines, rates] = await Promise.all([
      fetchAllPages<FxBankLine>(() =>
        db
          .from("v_ledger_posted")
          .select("debit, credit, amount_original, fx_rate_date")
          .eq("bank_account_id", req.bankAccountId)
          .order("line_id", { ascending: true }) as never
      ),
      fetchAllPages<FxDiffLine>(() =>
        db
          .from("v_ledger_posted")
          .select("debit, credit, currency")
          .eq("owner_id", req.ownerId)
          .eq("coa_id", id3410)
          .order("line_id", { ascending: true }) as never
      ),
      db.from("fx_rates").select("currency, rate_date, thb_per_unit").eq("currency", bank.currency).order("rate_date", { ascending: false }).limit(500),
    ]);
    if (!bankLines.ok) return { ok: false, message: `อ่านรายการเงินตราของบัญชีไม่สำเร็จ (${bankLines.error})` };
    if (!diffLines.ok) return { ok: false, message: `อ่านผลต่างอัตราแลกเปลี่ยนที่ค้างไม่สำเร็จ (${diffLines.error})` };
    if (rates.error) return { ok: false, message: `อ่านตารางอัตราแลกเปลี่ยนไม่สำเร็จ (${rates.error.message})` };

    const foreign = new Set(ref.banks.filter((b) => b.ownerId === req.ownerId && b.currency !== "THB").map((b) => b.currency));
    return {
      ok: true,
      ctx: buildFxContext({
        bankAccountId: bank.id,
        ownerId: req.ownerId,
        currency: bank.currency,
        bankLines: bankLines.rows,
        diffLines: diffLines.rows,
        singleCurrencyOwner: foreign.size <= 1,
        rates: ((rates.data ?? []) as { currency: string; rate_date: string; thb_per_unit: number | string }[]).map(
          (r): FxRate => ({ currency: r.currency, rateDate: r.rate_date, thbPerUnit: Number(r.thb_per_unit) })
        ),
      }),
    };
  } catch (e) {
    return { ok: false, message: `อ่านข้อมูลเงินตราไม่สำเร็จ (${e instanceof Error ? e.message : String(e)})` };
  }
}
