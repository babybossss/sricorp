/**
 * ดึงพิกัดออกจากลิงก์ Google Maps ที่ผู้ใช้วางมา
 *
 * ผู้ใช้กรอก **ลิงก์** ระบบเก็บ **พิกัด** ให้เอง — คนไม่ต้องรู้จักละติจูด-ลองจิจูด
 *
 * **อ่านไม่ออกต้องคืน null ห้ามเดา** พิกัดที่เดาผิดจะวางทรัพย์ไว้ผิดจังหวัด
 * แล้วไม่มีอะไรฟ้อง เพราะหมุดก็ยังขึ้นบนแผนที่เหมือนเดิม ต่างจากช่องว่างที่เห็นชัดว่ายังไม่มี
 */

export type LatLng = { lat: number; lng: number };

/** ที่มาของพิกัด — บอกผู้ใช้ได้ว่าได้มาจากตรงไหนของลิงก์ */
export type CoordSource = "place" | "viewport" | "query" | "dms" | "plain";

export type ParseResult =
  | { ok: true; lat: number; lng: number; source: CoordSource }
  | { ok: false; reason: "short_link" | "no_coords" | "out_of_range" | "empty" };

/**
 * ลิงก์ย่อ (maps.app.goo.gl / goo.gl/maps) **ไม่มีพิกัดอยู่ในตัวมันเอง**
 * ต้องตามรีไดเรกต์ก่อน ซึ่งทำได้แต่ฝั่งเซิร์ฟเวอร์ (เบราว์เซอร์ติด CORS)
 */
export function isShortLink(raw: string): boolean {
  return /^https?:\/\/(maps\.app\.goo\.gl|goo\.gl\/maps)\//i.test(raw.trim());
}

/** ละติจูดอยู่ได้แค่ ±90 ถ้าเกิน แปลว่าสลับกับลองจิจูด ซึ่งเป็นความผิดพลาดที่เจอบ่อยที่สุด */
function inRange(lat: number, lng: number): boolean {
  return Number.isFinite(lat) && Number.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180;
}

function done(lat: number, lng: number, source: CoordSource): ParseResult {
  if (!inRange(lat, lng)) return { ok: false, reason: "out_of_range" };
  return { ok: true, lat, lng, source };
}

/** องศา-ลิปดา-ฟิลิปดา เช่น 13° 47' 4.9636" N 100° 37' 36.2597" E — รูปแบบที่อยู่ในไฟล์เดิมของลูกพี่ */
const DMS = /(\d+(?:\.\d+)?)\s*°\s*(\d+(?:\.\d+)?)\s*['′]\s*(\d+(?:\.\d+)?)\s*["″]?\s*([NSEW])/giu;

function fromDms(raw: string): ParseResult | null {
  const parts: { deg: number; hemi: string }[] = [];
  for (const m of raw.matchAll(DMS)) {
    const deg = Number(m[1]) + Number(m[2]) / 60 + Number(m[3]) / 3600;
    parts.push({ deg, hemi: m[4].toUpperCase() });
  }
  if (parts.length < 2) return null;
  const ns = parts.find((p) => p.hemi === "N" || p.hemi === "S");
  const ew = parts.find((p) => p.hemi === "E" || p.hemi === "W");
  if (!ns || !ew) return null;
  return done(ns.hemi === "S" ? -ns.deg : ns.deg, ew.hemi === "W" ? -ew.deg : ew.deg, "dms");
}

/**
 * แปลงลิงก์หรือข้อความพิกัดเป็น lat/lng
 *
 * ลำดับการหาสำคัญ — `!3d..!4d..` คือ**หมุดของสถานที่** ส่วน `@lat,lng` คือ
 * **จุดกึ่งกลางของภาพที่เห็นตอนก๊อปลิงก์** สองอันนี้ห่างกันได้หลายร้อยเมตร
 * ถ้าหยิบ `@` มาก่อน หมุดจะไปตกกลางถนนแทนที่จะอยู่บนทรัพย์
 */
export function parseGoogleMapsUrl(raw: string): ParseResult {
  const t = (raw ?? "").trim();
  if (!t) return { ok: false, reason: "empty" };
  if (isShortLink(t)) return { ok: false, reason: "short_link" };

  // 1. หมุดของสถานที่ใน data= — แม่นที่สุด
  const place = /!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/.exec(t);
  if (place) return done(Number(place[1]), Number(place[2]), "place");

  // 2. ?q= / &query= / &ll= — ลิงก์แบบแชร์พิกัดตรงๆ
  const q = /[?&](?:q|query|ll|center|daddr)=(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)/.exec(t);
  if (q) return done(Number(q[1]), Number(q[2]), "query");

  // 3. @lat,lng,zoom — จุดกึ่งกลางภาพ ใช้เมื่อไม่มีหมุด
  const at = /@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/.exec(t);
  if (at) return done(Number(at[1]), Number(at[2]), "viewport");

  // 4. องศา-ลิปดา-ฟิลิปดา
  const dms = fromDms(t);
  if (dms) return dms;

  // 5. ตัวเลขคู่เปล่าๆ "13.7563, 100.5018" — ต้องทั้งสตริงพอดี ไม่ใช่หยิบเลขจากข้อความยาวๆ
  const plain = /^(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)$/.exec(t);
  if (plain) return done(Number(plain[1]), Number(plain[2]), "plain");

  return { ok: false, reason: "no_coords" };
}

export const PARSE_MESSAGE: Record<Extract<ParseResult, { ok: false }>["reason"], string> = {
  empty: "ยังไม่ได้วางลิงก์",
  short_link: "เป็นลิงก์ย่อ — กดปุ่มดึงพิกัดเพื่อให้ระบบตามลิงก์ให้",
  no_coords: "ลิงก์นี้ไม่มีพิกัดอยู่ข้างใน — เปิดใน Google Maps แล้วก๊อปลิงก์จากแถบที่อยู่อีกครั้ง",
  out_of_range: "พิกัดเกินช่วงที่เป็นไปได้ — อาจสลับละติจูดกับลองจิจูด",
};

export const SOURCE_LABEL: Record<CoordSource, string> = {
  place: "หมุดของสถานที่",
  viewport: "จุดกึ่งกลางภาพ (อาจคลาดจากตัวทรัพย์)",
  query: "พิกัดในลิงก์",
  dms: "องศา-ลิปดา-ฟิลิปดา",
  plain: "พิกัดที่พิมพ์เอง",
};

/** อยู่ในกรอบประเทศไทยคร่าวๆ — ใช้เตือน ไม่ใช่ปฏิเสธ เพราะอาจมีทรัพย์ต่างประเทศ */
export function looksOutsideThailand(lat: number, lng: number): boolean {
  return lat < 5.5 || lat > 20.5 || lng < 97 || lng > 106;
}
