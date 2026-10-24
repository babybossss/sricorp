import { cache } from "react";
import { createClient } from "@/lib/supabase/server";
import type { Reference, ReferenceState, RefOwner } from "./reference-types";

/**
 * โหลดข้อมูลอ้างอิงจริงจาก `sri_os` — **ฝั่ง server เท่านั้น** (ใช้ session ของผู้ใช้ ผ่าน RLS)
 *
 * ผังบัญชีและประเภทรายการ **ไม่ได้โหลดจาก DB**: ต้นฉบับอยู่ในโค้ด (`src/lib/rules/coa.ts` ·
 * `tx-rules.ts`) และ DB เป็นสำเนาที่ `npm run check:sync` เทียบให้ตรงกันอยู่แล้ว —
 * โหลดมาอีกชุดจะเป็นแหล่งความจริงที่สอง (บทเรียนข้อ 5) · ที่โหลดคือ `id → code` ของผังบัญชี
 * อย่างเดียว เพราะ `v_ledger_posted` เก็บบรรทัดเป็น uuid
 *
 * ล้มเหลว = คืน `{ ok: false, error }` พร้อมเหตุผล **ไม่ตกกลับไปใช้ข้อมูลจำลองเงียบๆ**
 */

type OwnerRow = {
  id: string;
  code: string;
  policy: RefOwner["policy"];
  name_th: string;
  status: string;
  color: string | null;
  sort_order: number;
};
type BankRow = {
  id: string;
  owner_id: string;
  bank: string;
  display_name: string;
  account_no_last4: string | null;
  is_active: boolean;
  sort_order: number;
};
type AssetRow = { id: string; code: string; name: string; owner_id: string; status: string };
type ContactRow = {
  id: string;
  first_name: string;
  last_name: string | null;
  types: string[] | null;
  phone: string | null;
  line_id: string | null;
  email: string | null;
  is_active: boolean;
};
type CoaRow = { id: string; code: string };

export const loadReference = cache(async (): Promise<ReferenceState> => {
  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }

  const [owners, banks, assets, contacts, coa] = await Promise.all([
    supabase
      .from("owners")
      .select("id, code, policy, name_th, status, color, sort_order")
      .order("sort_order", { ascending: true }),
    supabase
      .from("bank_accounts")
      .select("id, owner_id, bank, display_name, account_no_last4, is_active, sort_order")
      .order("sort_order", { ascending: true }),
    supabase.from("assets").select("id, code, name, owner_id, status").order("name", { ascending: true }),
    supabase
      .from("contacts")
      .select("id, first_name, last_name, types, phone, line_id, email, is_active")
      .eq("is_active", true)
      .order("first_name", { ascending: true })
      .limit(2000),
    supabase.from("chart_of_accounts").select("id, code"),
  ]);

  const failed = [
    ["ผู้ถือ", owners.error],
    ["บัญชีธนาคาร", banks.error],
    ["ทรัพย์", assets.error],
    ["ผู้ติดต่อ", contacts.error],
    ["ผังบัญชี", coa.error],
  ].find(([, err]) => err) as [string, { message: string }] | undefined;
  if (failed) {
    return { ok: false, error: `อ่านข้อมูล${failed[0]}จากฐานข้อมูลไม่สำเร็จ (${failed[1].message})` };
  }

  const ref: Reference = {
    owners: ((owners.data ?? []) as OwnerRow[]).map((o) => ({
      id: o.id,
      code: o.code,
      name: o.name_th,
      policy: o.policy,
      status: o.status,
      color: o.color,
      sortOrder: o.sort_order,
    })),
    banks: ((banks.data ?? []) as BankRow[]).map((b) => ({
      id: b.id,
      ownerId: b.owner_id,
      name: b.display_name,
      bank: b.bank,
      last4: b.account_no_last4,
      isActive: b.is_active,
      sortOrder: b.sort_order,
    })),
    assets: ((assets.data ?? []) as AssetRow[]).map((a) => ({
      id: a.id,
      code: a.code,
      name: a.name,
      ownerId: a.owner_id,
      status: a.status,
    })),
    contacts: ((contacts.data ?? []) as ContactRow[]).map((c) => ({
      id: c.id,
      firstName: c.first_name,
      lastName: c.last_name ?? "",
      types: c.types ?? [],
      phone: c.phone ?? "",
      lineId: c.line_id ?? "",
      email: c.email ?? "",
    })),
    coaCodeById: Object.fromEntries(((coa.data ?? []) as CoaRow[]).map((r) => [r.id, r.code])),
  };
  return { ok: true, ref };
});
