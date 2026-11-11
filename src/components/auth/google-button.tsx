"use client";

import * as React from "react";
import { Button } from "@/components/ui/button";
import { createClient } from "@/lib/supabase/client";

/**
 * ปุ่ม "เข้าสู่ระบบด้วย Google" — Google OAuth จริงผ่าน Supabase
 * `next` คือหน้าที่ผู้ใช้ตั้งใจจะไป (callback ตรวจอีกชั้นว่าเป็นทางภายในเท่านั้น)
 */
export function GoogleSignInButton({ next }: { next?: string }) {
  const [busy, setBusy] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  async function signIn() {
    setBusy(true);
    setError(null);
    try {
      const supabase = createClient();
      const callback = new URL("/auth/callback", window.location.origin);
      if (next) callback.searchParams.set("next", next);
      const { error } = await supabase.auth.signInWithOAuth({
        provider: "google",
        options: { redirectTo: callback.toString() },
      });
      if (error) throw error;
      // สำเร็จ = browser กำลังถูกพาไปหน้า Google ไม่ต้องทำอะไรต่อ
    } catch (e) {
      setError(e instanceof Error ? e.message : "เข้าสู่ระบบไม่สำเร็จ");
      setBusy(false);
    }
  }

  return (
    <>
      <Button onClick={signIn} disabled={busy}>
        {busy ? "กำลังพาไปหน้า Google…" : "เข้าสู่ระบบด้วย Google"}
      </Button>
      {error ? (
        <p role="alert" className="rounded border border-neg-bd bg-neg-bg p-[12px_16px] text-sm text-neg-fg">
          {error}
        </p>
      ) : null}
    </>
  );
}
