"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

/** ออกจากระบบ — ล้าง session แล้วกลับหน้า login */
export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}
