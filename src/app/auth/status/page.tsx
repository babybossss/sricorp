import Link from "next/link";
import { headers, cookies } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import { readSupabaseEnv } from "@/lib/supabase/env";

/**
 * หน้าตรวจสถานะการเข้าสู่ระบบ — ไว้หาสาเหตุเวลา "ต้องล็อกอินใหม่ทุกรอบ"
 *
 * เปิดได้ทั้งตอนล็อกอินอยู่และตอนยังไม่ล็อกอิน (อยู่ใน PUBLIC_PATHS ของ middleware)
 * เพราะอาการที่ต้องวินิจฉัยคือ "ล็อกอินไม่ติด" — ถ้าหน้านี้ต้องล็อกอินก่อนก็ใช้หาสาเหตุไม่ได้
 *
 * **ห้ามแสดงความลับที่นี่** เพราะเปิดได้โดยไม่ล็อกอิน
 * แสดงได้แค่: origin ที่เปิดอยู่ · ชื่อ cookie (ไม่เอาค่า) · เวลาหมดอายุ · อีเมลของคนที่ล็อกอินอยู่เอง
 * ห้ามพิมพ์ access token, refresh token, หรือ key ใดๆ ลงหน้า
 */
export const dynamic = "force-dynamic";

const BKK = "Asia/Bangkok";

function fmt(epochSeconds: number | undefined): string {
  if (!epochSeconds) return "—";
  return new Intl.DateTimeFormat("th-TH", {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: BKK,
  }).format(new Date(epochSeconds * 1000));
}

/** "อีก 52 นาที" / "หมดอายุไปแล้ว 3 นาที" — ผู้ใช้อ่านเวลาที่เหลือง่ายกว่า timestamp */
function remaining(epochSeconds: number | undefined): string {
  if (!epochSeconds) return "—";
  const secs = epochSeconds - Math.floor(Date.now() / 1000);
  const mins = Math.round(Math.abs(secs) / 60);
  const human = mins >= 60 ? `${Math.floor(mins / 60)} ชม. ${mins % 60} นาที` : `${mins} นาที`;
  return secs >= 0 ? `อีก ${human}` : `หมดอายุไปแล้ว ${human}`;
}

function Row({ label, value, tone }: { label: string; value: React.ReactNode; tone?: "pos" | "neg" | "warn" }) {
  const toneClass =
    tone === "pos" ? "text-pos-fg" : tone === "neg" ? "text-neg-fg" : tone === "warn" ? "text-warn-fg" : "text-ink-900";
  return (
    <div className="flex flex-col gap-0.5 border-b border-line py-3 last:border-b-0 sm:flex-row sm:items-baseline sm:gap-4">
      <div className="shrink-0 text-sm text-ink-600 sm:w-[220px]">{label}</div>
      <div className={`break-all text-base tabular-nums ${toneClass}`}>{value}</div>
    </div>
  );
}

export default async function AuthStatusPage() {
  const h = await headers();
  const env = readSupabaseEnv();

  // origin ที่ browser เปิดอยู่จริง — สำคัญที่สุด เพราะ cookie ของ session ผูกกับ origin
  const host = h.get("x-forwarded-host") ?? h.get("host") ?? "(ไม่ทราบ)";
  const proto = h.get("x-forwarded-proto") ?? "https";
  const origin = `${proto}://${host}`;
  const onVercelHost = host.endsWith(".vercel.app");

  // ชื่อ cookie ของ Supabase ที่ติดมากับ request (ไม่เอาค่า — ค่าคือ token)
  const store = await cookies();
  const sbCookies = store
    .getAll()
    .map((c) => c.name)
    .filter((n) => n.startsWith("sb-"))
    .sort();

  let signedIn = false;
  let email: string | null = null;
  let expiresAt: number | undefined;
  let hasRefreshToken = false;
  let readError: string | null = null;

  if (env.ok) {
    try {
      const supabase = await createClient();
      const { data, error } = await supabase.auth.getSession();
      if (error) throw error;
      const session = data.session;
      signedIn = Boolean(session);
      email = session?.user?.email ?? null;
      expiresAt = session?.expires_at ?? undefined;
      hasRefreshToken = Boolean(session?.refresh_token);
    } catch (e) {
      // อ่านไม่ได้ = บอกตรงๆ ว่าอ่านไม่ได้ ห้ามเดาว่า "ยังไม่ล็อกอิน"
      readError = e instanceof Error ? e.message : String(e);
    }
  }

  return (
    <div className="mx-auto flex max-w-[760px] flex-col gap-6 p-[32px_20px]">
      <div>
        <h1 className="text-h1 font-semibold">ตรวจสถานะการเข้าสู่ระบบ</h1>
        <p className="mt-1 text-base text-ink-600">
          หน้านี้ไว้หาสาเหตุเวลาต้องล็อกอินใหม่ทุกรอบ — ไม่แสดงรหัสหรือ token ใดๆ
        </p>
      </div>

      {onVercelHost ? (
        <div role="alert" className="rounded-card border border-neg-bd bg-neg-bg p-[16px_18px] text-base leading-7 text-neg-fg">
          <b>นี่คือสาเหตุที่ต้องล็อกอินซ้ำ</b>
          <p className="mt-1">
            ลูกพี่กำลังเปิดจากที่อยู่ <code>{host}</code> ซึ่งเป็นที่อยู่ของ Vercel
            ที่อยู่กลุ่มนี้มีประตูล็อกอินของ Vercel คร่อมอยู่อีกชั้น และ cookie ของ SRI OS
            ก็ผูกกับที่อยู่นี้ ไม่ใช่โดเมนจริง — สลับที่อยู่ไปมาเมื่อไรก็ต้องล็อกอินใหม่ทุกครั้ง
          </p>
          <p className="mt-2">
            <b>ให้เปิดจาก <a className="underline" href="https://os.sricorporation.com/auth/status">os.sricorporation.com</a> เท่านั้น</b>{" "}
            แล้วบุ๊กมาร์กที่อยู่นั้นไว้
          </p>
        </div>
      ) : (
        <div className="rounded-card border border-pos-bd bg-pos-bg p-[16px_18px] text-base leading-7 text-pos-fg">
          เปิดจากโดเมนจริง <code>{host}</code> — ถูกต้องแล้ว ที่อยู่นี้ไม่มีประตูของ Vercel คร่อม
        </div>
      )}

      <section className="rounded-card border border-line bg-surface p-[20px_22px] shadow-card">
        <h2 className="text-h2 font-semibold">สถานะตอนนี้</h2>
        <div className="mt-2">
          <Row label="ที่อยู่ที่เปิดอยู่" value={origin} tone={onVercelHost ? "neg" : "pos"} />
          <Row
            label="ล็อกอินอยู่หรือไม่"
            value={readError ? `อ่านไม่ได้: ${readError}` : signedIn ? "ล็อกอินอยู่" : "ยังไม่ได้ล็อกอิน"}
            tone={readError ? "warn" : signedIn ? "pos" : "warn"}
          />
          <Row label="อีเมลที่ล็อกอิน" value={email ?? "—"} />
          <Row
            label="บัตรผ่านหมดอายุ"
            value={expiresAt ? `${fmt(expiresAt)} (${remaining(expiresAt)})` : "—"}
          />
          <Row
            label="บัตรต่ออายุ (refresh token)"
            value={
              signedIn
                ? hasRefreshToken
                  ? "มี — ระบบจะต่ออายุให้เองไม่ต้องล็อกอินใหม่"
                  : "ไม่มี — นี่คือสาเหตุที่ต้องล็อกอินใหม่เมื่อบัตรผ่านหมดอายุ"
                : "—"
            }
            tone={signedIn ? (hasRefreshToken ? "pos" : "neg") : undefined}
          />
          <Row label="cookie ของ Supabase ที่ติดมา" value={sbCookies.length ? sbCookies.join(" · ") : "ไม่มีเลย"} tone={sbCookies.length ? undefined : "warn"} />
          <Row label="ตั้งค่า Supabase ครบหรือไม่" value={env.ok ? "ครบ" : env.problems.join(" · ")} tone={env.ok ? "pos" : "neg"} />
        </div>
      </section>

      <section className="rounded-card border border-info-bd bg-info-bg p-[20px_22px]">
        <h2 className="text-h2 font-semibold text-ink-900">ค่าที่ต้องมีใน Supabase</h2>
        <p className="mt-1 text-base leading-7 text-ink-900">
          ถ้ายังต้องล็อกอินซ้ำแม้เปิดจากโดเมนจริง ให้เปิด Supabase → Authentication → URL Configuration
          แล้วตั้งให้ตรงกับสองค่านี้ (ถ้าไม่ตรง Supabase จะไม่ส่งกลับมาที่โดเมนนี้ และ cookie จะไปตกที่อยู่อื่น)
        </p>
        <dl className="mt-3 flex flex-col gap-3">
          <div>
            <dt className="text-sm text-ink-600">Site URL</dt>
            <dd className="mt-0.5 overflow-x-auto whitespace-nowrap rounded border border-line bg-surface p-[10px_12px] text-base">{origin}</dd>
          </div>
          <div>
            <dt className="text-sm text-ink-600">Redirect URLs (ต้องมีทั้งสองบรรทัด)</dt>
            <dd className="mt-0.5 overflow-x-auto whitespace-nowrap rounded border border-line bg-surface p-[10px_12px] text-base">
              {origin}/auth/callback
              <br />
              {origin}
              {"/**"}
            </dd>
          </div>
        </dl>
      </section>

      <div className="flex flex-col gap-3 sm:flex-row">
        <Link
          href="/dashboard"
          className="flex min-h-control-mobile items-center justify-center rounded border border-brand-600 bg-brand-600 p-[12px_20px] text-base font-semibold text-surface focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600/40 sm:min-h-control"
        >
          ไปหน้าแรก
        </Link>
        <Link
          href="/login"
          className="flex min-h-control-mobile items-center justify-center rounded border border-line bg-surface p-[12px_20px] text-base font-semibold text-ink-900 focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600/40 sm:min-h-control"
        >
          ไปหน้าเข้าสู่ระบบ
        </Link>
      </div>
    </div>
  );
}
