"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { humanizeDbError } from "@/lib/db/post-entry";
import type { RefContact } from "@/lib/db/reference-types";

/**
 * สร้างผู้ติดต่อจากในฟอร์ม (Backlog ข้อ 3) — เขียนลง `sri_os.contacts` จริง
 *
 * ทำไมต้องเป็นของจริง: รายการที่บันทึกอ้าง `contact_id` เป็น uuid ใน DB
 * ผู้ติดต่อที่สร้างแค่ในหน่วยความจำของหน้าจอจะทำให้รายการล้มตอนบันทึก (foreign key)
 *
 * RLS: `contacts_insert` เปิดให้ทุกคนที่ล็อกอินสร้างได้ (20260917000004) · `created_by` ผูกกับผู้สร้าง
 * เพื่อให้แก้ของตัวเองได้ภายหลัง
 */

export type CreateContactInput = {
  firstName: string;
  lastName: string;
  phone: string;
  lineId: string;
  email: string;
  /** บทบาท เช่น tenant · lender · borrower · vendor · other */
  type: string;
};

export type CreateContactOutcome = { ok: true; contact: RefContact } | { ok: false; message: string };

const clean = (s: unknown): string => (typeof s === "string" ? s.trim() : "");
const orNull = (s: string): string | null => (s === "" ? null : s);

export async function createContact(input: CreateContactInput): Promise<CreateContactOutcome> {
  const firstName = clean(input?.firstName);
  if (!firstName) return { ok: false, message: "กรอกชื่อผู้ติดต่อก่อน" };

  const access = await getAccess();
  if (!access.user) return { ok: false, message: "เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วลองอีกครั้ง" };
  if (!access.permissions.has("txn.create")) {
    return { ok: false, message: "บัญชีนี้ไม่มีสิทธิ์สร้างผู้ติดต่อ" };
  }

  const type = clean(input.type) || "other";
  const row = {
    first_name: firstName,
    last_name: orNull(clean(input.lastName)),
    types: [type],
    phone: orNull(clean(input.phone)),
    line_id: orNull(clean(input.lineId)),
    email: orNull(clean(input.email)),
    created_by: access.user.id,
  };

  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
  const { data, error } = await supabase
    .from("contacts")
    .insert(row)
    .select("id, first_name, last_name, types, phone, line_id, email")
    .single();
  if (error || !data) return { ok: false, message: humanizeDbError(error) };

  revalidatePath("/contacts");
  return {
    ok: true,
    contact: {
      id: data.id as string,
      firstName: data.first_name as string,
      lastName: (data.last_name as string | null) ?? "",
      types: (data.types as string[] | null) ?? [],
      phone: (data.phone as string | null) ?? "",
      lineId: (data.line_id as string | null) ?? "",
      email: (data.email as string | null) ?? "",
    },
  };
}
