import { NextResponse } from "next/server";
import { parseGoogleMapsUrl, isShortLink } from "@/lib/maps/google-url";

/**
 * ตามลิงก์ย่อของ Google Maps เพื่อเอาพิกัดออกมา
 *
 * ต้องทำฝั่งเซิร์ฟเวอร์ เพราะเบราว์เซอร์อ่านปลายทางของรีไดเรกต์ข้ามโดเมนไม่ได้ (CORS)
 *
 * **รับเฉพาะโดเมนของ Google Maps เท่านั้น** ถ้าปล่อยให้ใส่ URL อะไรก็ได้
 * จะกลายเป็นช่องให้ยิงไปหาเครื่องภายในผ่านเซิร์ฟเวอร์ของเรา (SSRF)
 */
const ALLOWED = /^https:\/\/(maps\.app\.goo\.gl|goo\.gl)\//i;

export async function POST(req: Request) {
  let url: string;
  try {
    ({ url } = await req.json());
  } catch {
    return NextResponse.json({ ok: false, reason: "bad_request" }, { status: 400 });
  }

  if (typeof url !== "string" || !ALLOWED.test(url.trim())) {
    return NextResponse.json({ ok: false, reason: "not_a_google_short_link" }, { status: 400 });
  }

  try {
    const res = await fetch(url.trim(), {
      redirect: "follow",
      signal: AbortSignal.timeout(8000),
      headers: { "user-agent": "Mozilla/5.0 (compatible; SRI-OS/1.0)" },
    });
    const finalUrl = res.url;
    if (isShortLink(finalUrl)) return NextResponse.json({ ok: false, reason: "still_short" });

    const parsed = parseGoogleMapsUrl(finalUrl);
    if (!parsed.ok) return NextResponse.json({ ok: false, reason: parsed.reason, finalUrl });
    return NextResponse.json({ ok: true, lat: parsed.lat, lng: parsed.lng, source: parsed.source, finalUrl });
  } catch {
    return NextResponse.json({ ok: false, reason: "fetch_failed" }, { status: 502 });
  }
}
