/**
 * สกุลเงินและอัตราแลกเปลี่ยน — **แหล่งความจริงเดียวฝั่งโค้ด** (D-111 ข้อ 2)
 *
 * ขอบเขตที่ลูกพี่ยืนยัน: **ฝั่งการลงทุนเท่านั้น** (หุ้นต่างประเทศ · คริปโต)
 * ไม่ใช่บัญชีธนาคารสกุลต่างประเทศ → **สมุดบัญชียังเป็นบาทล้วน**
 * (functional currency = บาท ซึ่งถูกต้องสำหรับนิติบุคคลไทย)
 *
 * ผลที่โค้ดต้องยึด: `transaction_lines` **ไม่มีคอลัมน์สกุลเงิน** และห้ามเพิ่ม
 * ของต่างประเทศเข้าสมุดในรูป "ทรัพย์ที่ตีมูลค่าเป็นบาท" เท่านั้น —
 * สกุลเดิมอยู่ที่ `assets.currency` และ `asset_valuations` (มูลค่าสกุลเดิม + อัตรา + ยอดบาท)
 *
 * ไฟล์นี้ **ไม่ใช่** หนึ่งในสามชุดที่ `npm run sync:rules` คัดลอกลง DB
 * สำเนาฝั่ง DB คือ check constraint ของ `assets.currency` กับตาราง `fx_rates`
 * ซึ่งอยู่ใน `supabase/migrations/20261024000001_wht_and_fx.sql` — ถ้าเพิ่มสกุลเงินที่นี่
 * **ต้องแก้ migration ด้วย** ไม่งั้น DB จะปฏิเสธทรัพย์สกุลใหม่ตอนผู้ใช้กดบันทึก
 * (เทสต์ฝั่ง SQL `zz_wht_and_fx_test.sql` ตรวจว่า DB รู้จักสี่สกุลนี้พอดี ไม่ขาดไม่เกิน)
 */

/** สกุลของสมุดบัญชี — ทุกบรรทัดใน ledger เป็นสกุลนี้เสมอ */
export const BASE_CURRENCY = "THB";

/**
 * สกุลที่ระบบรับ — **สี่สกุล ไม่มากกว่านี้**
 *
 * ทุกสกุลที่เพิ่มเข้ามาแปลว่าต้องมีคนป้อนอัตราสิ้นเดือนของมันทุกเดือน
 * ถ้าไม่มีอัตรา การตีราคาทรัพย์สกุลนั้นทำไม่ได้ (และต้องปฏิเสธ ไม่ใช่ใช้อัตราเดือนก่อน)
 */
export const CURRENCIES = ["THB", "USD", "JPY", "CNY"] as const;
export type Currency = (typeof CURRENCIES)[number];

/**
 * แหล่งที่มาของอัตรา — เฟสนี้ใส่มือ (`manual`) ตัวดึงจาก ธปท. เป็นงานแยก
 *
 * เก็บแหล่งไว้ตั้งแต่แถวแรกโดยตั้งใจ: วันที่ตัวดึงอัตโนมัติเข้ามา เราต้องแยกออกได้ว่า
 * อัตราไหนคนพิมพ์และอัตราไหนระบบดึง ไม่งั้นตรวจย้อนไม่ได้ว่าตัวเลขที่ใช้มาจากไหน
 * (เติมแหล่งย้อนหลังให้แถวเก่าไม่ได้ เพราะไม่มีใครจำได้แล้ว)
 */
export const FX_RATE_SOURCES = ["manual", "bot_api"] as const;
export type FxRateSource = (typeof FX_RATE_SOURCES)[number];

export const FX_RATE_SOURCE_LABEL: Record<FxRateSource, string> = {
  manual: "ป้อนมือ",
  bot_api: "ดึงจาก ธปท. อัตโนมัติ",
};

/** หนึ่งแถวของตารางอัตราแลกเปลี่ยน — ตรงกับ `sri_os.fx_rates` */
export type FxRate = {
  currency: Currency;
  /** วันของอัตรา (ปกติวันสิ้นเดือน) รูปแบบ YYYY-MM-DD */
  rateDate: string;
  /** บาทต่อหนึ่งหน่วยสกุลนั้น — ทิศเดียวในระบบ กันการคูณกลับทิศ */
  thbPerUnit: number;
  source: FxRateSource;
};

export function isCurrency(v: string | undefined | null): v is Currency {
  return typeof v === "string" && (CURRENCIES as readonly string[]).includes(v);
}

export function isFxRateSource(v: string | undefined | null): v is FxRateSource {
  return typeof v === "string" && (FX_RATE_SOURCES as readonly string[]).includes(v);
}

/**
 * ผลการตรวจอัตราแลกเปลี่ยน — รูปเดียวกับ `accrualCheck()` โดยตั้งใจ
 *
 * คืนเหตุผลเป็นข้อความ ไม่โยน เพราะชั้นที่เรียกต่างกันต้องการ error ต่างชนิด
 * (`lib/ledger` ต้องเป็น `PostingError` ที่ผู้ใช้อ่านได้ · หน้าจอต้องการข้อความเฉยๆ)
 * **กฎอยู่ที่นี่ที่เดียว** ผู้เรียกแค่แปลงชนิด error — กฎเดียวกันห้ามเขียนสองที่
 */
export type FxCheck = { ok: true; rate: FxRate } | { ok: false; why: string };

export type FxCheckInput = {
  currency?: string;
  thbPerUnit?: number;
  /** ไม่ส่ง = ไม่ตรวจวันที่ (ใช้ตอนตรวจแค่คู่ สกุล+อัตรา ของการตีราคา) */
  rateDate?: string;
  /** ไม่ส่ง = ไม่ตรวจแหล่งที่มา (ใช้ตอนตรวจแค่คู่ สกุล+อัตรา) */
  source?: string;
  /** บังคับให้ต้องมีวันที่และแหล่งที่มาด้วย (ใช้ตอนบันทึกแถวลงตารางอัตรา) */
  requireProvenance?: boolean;
};

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function isRealIsoDate(v: string): boolean {
  if (!ISO_DATE.test(v)) return false;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}

export function fxCheck(input: FxCheckInput): FxCheck {
  const { currency, thbPerUnit } = input;
  if (!isCurrency(currency)) {
    return {
      ok: false,
      why:
        `ต้องระบุสกุลเงินจากรายการที่อนุญาต (${CURRENCIES.join(" · ")}) — ได้ "${currency ?? ""}" · ` +
        "เดาสกุลเงินแทนผู้ใช้ไม่ได้ เพราะมูลค่าทรัพย์ในงบดุลจะผิดทั้งก้อนโดยไม่มีอะไรฟ้อง",
    };
  }

  if (typeof thbPerUnit !== "number" || !Number.isFinite(thbPerUnit) || thbPerUnit <= 0) {
    return {
      ok: false,
      why:
        "ต้องระบุอัตราแลกเปลี่ยน (บาทต่อหนึ่งหน่วย) เป็นตัวเลขมากกว่า 0 — " +
        `ได้ ${JSON.stringify(thbPerUnit ?? null)} · ไม่ส่งอัตราแล้วถือว่า 1 คือการเดา ` +
        "ซึ่งทำให้ทรัพย์ต่างประเทศถูกบันทึกเท่ามูลค่าในสกุลเดิมเป็นบาท",
    };
  }

  // บาทต่อบาทต้องเป็น 1 เท่านั้น — ถ้าไม่ล็อก ยอดบาทจะถูกแปลงสองรอบ
  if (currency === BASE_CURRENCY && thbPerUnit !== 1) {
    return {
      ok: false,
      why: `สกุลบาทต้องมีอัตรา 1 เท่านั้น (ได้ ${thbPerUnit}) — สมุดบัญชีเป็นบาทอยู่แล้ว ไม่มีอะไรต้องแปลง`,
    };
  }

  const needProvenance = input.requireProvenance ?? (input.rateDate !== undefined || input.source !== undefined);
  let rateDate = input.rateDate ?? "";
  let source = input.source;

  if (needProvenance) {
    rateDate = (input.rateDate ?? "").trim();
    if (!isRealIsoDate(rateDate)) {
      return {
        ok: false,
        why: `ต้องระบุวันที่ของอัตราเป็น YYYY-MM-DD ที่มีอยู่จริง (ได้ "${input.rateDate ?? ""}") — อัตราที่ไม่มีวันกำกับใช้ตรวจย้อนไม่ได้ว่าใช้อัตราของเดือนไหน`,
      };
    }
    if (!isFxRateSource(source)) {
      return {
        ok: false,
        why:
          `ต้องระบุแหล่งที่มาของอัตราจากรายการที่อนุญาต (${FX_RATE_SOURCES.join(" · ")}) — ` +
          `ได้ "${input.source ?? ""}" · แหล่งที่มาคือสิ่งที่แยกอัตราที่คนพิมพ์ออกจากอัตราที่ระบบดึง`,
      };
    }
  } else {
    source = "manual";
  }

  return {
    ok: true,
    rate: { currency, rateDate, thbPerUnit, source: source as FxRateSource },
  };
}

const round2 = (n: number) => Math.round(n * 100) / 100;

/**
 * แปลงมูลค่าในสกุลเดิมเป็นบาท — **ที่เดียวที่คูณอัตรา**
 *
 * ทิศทางเดียว (บาท = จำนวน × บาทต่อหน่วย) เพราะการหารกลับทิศเป็นข้อผิดที่
 * ตัวเลขยังดู "พอเป็นไปได้" อยู่ (เยนที่อัตรา 0.23 หารแล้วได้ตัวเลขใหญ่ขึ้น)
 */
export function toThb(amountOriginal: number, thbPerUnit: number): number {
  if (!Number.isFinite(amountOriginal)) throw new Error("มูลค่าในสกุลเดิมต้องเป็นตัวเลขที่ระบุได้");
  if (!Number.isFinite(thbPerUnit)) throw new Error("อัตราแลกเปลี่ยนต้องเป็นตัวเลขที่ระบุได้");
  return round2(amountOriginal * thbPerUnit);
}
