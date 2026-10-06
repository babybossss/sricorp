import { describe, it, expect } from "vitest";
import { parseGoogleMapsUrl, isShortLink, looksOutsideThailand } from "../google-url";

const ok = (r: ReturnType<typeof parseGoogleMapsUrl>) => {
  if (!r.ok) throw new Error(`คาดว่าอ่านได้ แต่ได้ ${r.reason}`);
  return r;
};

describe("ดึงพิกัดจากลิงก์ Google Maps", () => {
  it("หยิบหมุดของสถานที่ (!3d!4d) ก่อนจุดกึ่งกลางภาพ (@) เสมอ", () => {
    // ลิงก์จริงมีทั้งสองค่า และห่างกันได้หลายร้อยเมตร
    const url =
      "https://www.google.com/maps/place/SRI/@13.8000000,100.6000000,17z/data=!4m6!3m5!1s0x0:0x0!8m2!3d13.7847000!4d100.6267000";
    const r = ok(parseGoogleMapsUrl(url));
    expect(r.source).toBe("place");
    expect(r.lat).toBeCloseTo(13.7847, 6);
    expect(r.lng).toBeCloseTo(100.6267, 6);
  });

  it("ใช้ @ เมื่อไม่มีหมุด", () => {
    const r = ok(parseGoogleMapsUrl("https://www.google.com/maps/@13.7563,100.5018,17z"));
    expect(r.source).toBe("viewport");
    expect(r.lat).toBeCloseTo(13.7563, 6);
  });

  it("อ่าน ?q= และ ?query= ได้", () => {
    expect(ok(parseGoogleMapsUrl("https://maps.google.com/?q=13.7563,100.5018")).lng).toBeCloseTo(100.5018, 6);
    expect(ok(parseGoogleMapsUrl("https://www.google.com/maps/search/?api=1&query=18.853,98.9927")).lat).toBeCloseTo(18.853, 6);
  });

  it("อ่านองศา-ลิปดา-ฟิลิปดาแบบที่อยู่ในไฟล์เดิมได้", () => {
    const r = ok(parseGoogleMapsUrl(`13° 47' 4.9636" N 100° 37' 36.2597" E`));
    expect(r.source).toBe("dms");
    expect(r.lat).toBeCloseTo(13.78471, 4);
    expect(r.lng).toBeCloseTo(100.62674, 4);
  });

  it("ซีกโลกใต้และตะวันตกต้องติดลบ", () => {
    const r = ok(parseGoogleMapsUrl(`33° 51' 24" S 151° 12' 36" W`));
    expect(r.lat).toBeLessThan(0);
    expect(r.lng).toBeLessThan(0);
  });

  it("ลิงก์ย่อบอกว่าต้องตามลิงก์ก่อน ไม่ใช่บอกว่าไม่มีพิกัด", () => {
    expect(isShortLink("https://maps.app.goo.gl/Fhf2m5K2jCUkj3aL")).toBe(true);
    const r = parseGoogleMapsUrl("https://maps.app.goo.gl/Fhf2m5K2jCUkj3aL");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe("short_link");
  });

  it("ชื่อสถานที่เฉยๆ ต้องปฏิเสธ ไม่ใช่เดาพิกัด", () => {
    for (const s of ["Fuse Mobius", "iCondo Sukhapiban 2", "โรงงาน ปุ๋ยตระกูลโต"]) {
      const r = parseGoogleMapsUrl(s);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.reason).toBe("no_coords");
    }
  });

  it("สลับละติจูดกับลองจิจูดต้องถูกจับได้", () => {
    const r = parseGoogleMapsUrl("100.5018,13.7563");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe("out_of_range");
  });

  it("ว่างเปล่าไม่ใช่ความผิดพลาด แค่ยังไม่กรอก", () => {
    const r = parseGoogleMapsUrl("   ");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe("empty");
  });

  it("ไม่หยิบตัวเลขจากข้อความยาวๆ มาเป็นพิกัด", () => {
    // "24 ตร.ว. 101,250" ไม่ใช่พิกัด
    expect(parseGoogleMapsUrl("บ้านลาดพร้าว 101 เนื้อที่ 24 ตร.ว. ราคา 101,250").ok).toBe(false);
  });

  it("เตือนเมื่อพิกัดอยู่นอกกรอบประเทศไทย แต่ไม่ปฏิเสธ", () => {
    expect(looksOutsideThailand(13.75, 100.5)).toBe(false);
    expect(looksOutsideThailand(35.68, 139.69)).toBe(true);
  });
});
