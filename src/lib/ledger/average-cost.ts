/**
 * ต้นทุนถัวเฉลี่ยของทั้งกอง + ส่วนเกินทุนที่ต้องล้างตามสัดส่วน (**D-112 ข้อ 1**)
 *
 * ลูกพี่ตัดสิน 24/10 (D-112) ซึ่ง **เปลี่ยนวิธีคิดทั้งก้อน** จาก D-038 (FIFO):
 *   - หุ้นตัวเดียวกันที่ซื้อหลายครั้ง **เก็บเป็นล็อตเพื่อตรวจสอบ**
 *   - แต่ **คิดต้นทุนแบบถัวเฉลี่ย ไม่ใช่ FIFO**
 *   - ขายแล้ว **กำไรคิดจากต้นทุนถัวเฉลี่ยของทั้งกอง** ไม่ใช่ราคาของล็อตที่ขาย
 *   - **ขายบางส่วนต้องล้างส่วนเกินทุนจากการตีราคาตามสัดส่วน** (ขาย 3 ใน 10 → 30%)
 *   - กำไรที่ยังไม่ขายโชว์ได้ แต่ **ห้ามเข้า P&L เด็ดขาด** (ย้ำจาก D-111)
 *
 * ไฟล์นี้ **ไม่สร้างบรรทัดบัญชี** — คืนแค่ตัวเลข (ต้นทุนที่ตัด · กำไร · ส่วนเกินทุน
 * ที่ต้องล้าง · กองที่เหลือ) การแปลงเป็นคู่บัญชีเป็นหน้าที่ของตารางกฎ + `buildPosting()`
 * ตามกฎข้อ 3 ของ CLAUDE.md — ที่นี่ห้ามมีคู่บัญชี
 *
 * ---------------------------------------------------------------------------
 * ## การตัดสินใจที่ตรึงไว้ที่นี่ (อ่านก่อนแก้)
 *
 * **1. ขายบางส่วน = ตัดทุกล็อตตามสัดส่วนเท่ากัน ไม่ใช่ตัดล็อตเก่าก่อน**
 * เพราะถ้าตัดล็อตเก่าก่อน (ลำดับแบบ FIFO) แต่คิดต้นทุนแบบถัวเฉลี่ย
 * **ต้นทุนของกองที่เหลือจะมีสองคำตอบ**: ยอดที่คิดจากกอง (ต้นทุนก่อน − ที่ตัด)
 * กับยอดที่คิดจากล็อตที่เหลือ (Σ จำนวน × ราคาล็อต) ซึ่งไม่เท่ากัน
 * = ตัวเลขเงินสองชุดที่วันหนึ่งจะมีคนอ่านคนละชุด (บทเรียน mace-windu ข้อ 5)
 * ตัดตามสัดส่วนทำให้สองวิธีให้คำตอบเดียวกันเสมอ และ **ต้นทุนต่อหน่วยไม่เปลี่ยน
 * เพราะการขาย** ซึ่งเป็นคุณสมบัติที่นิยามความหมายของ "ถัวเฉลี่ย"
 *
 * **2. ความจริงของ "ต้นทุนคงเหลือ" อยู่ที่ ledger ไม่ใช่ที่สมุดล็อต**
 * ฝั่ง DB คือ `sri_os.fn_asset_cost_basis()` (migration 20261025000002) ซึ่งมีด่าน
 * `trg_assert_asset_cost_sane` บังคับว่าใบขายต้องล้าง 3400 ตามสัดส่วนของ
 * **ต้นทุนที่ตัดออก ÷ ต้นทุนก่อนขาย** — ซึ่งเท่ากับสัดส่วนจำนวนหน่วยพอดี
 * **เมื่อคิดต้นทุนแบบถัวเฉลี่ยเท่านั้น** (ถ้าเป็น FIFO สองสัดส่วนนี้ไม่เท่ากัน
 * และด่านฝั่ง DB จะบังคับไม่ได้เลยเพราะฐานข้อมูลไม่มีจำนวนหน่วย)
 * สมุดล็อตที่นี่มีไว้ **ตรวจสอบและคิดจำนวนหน่วย** ให้ตรงกับที่ ledger ถืออยู่
 *
 * **3. เศษสตางค์ — ปัดยอดสะสม (running total) ไม่ใช่ปัดทีละล็อต**
 * วิธีเดียวกับ `cost-basis.ts` และ `cashflow.ts`: สะสมเป็น **จำนวนเต็มสตางค์**
 * แล้วเอาส่วนต่างของยอดสะสมที่ปัดแล้วเป็นค่าของแต่ละล็อต → ผลรวมเท่ากับยอดจริง
 * **โดยนิยาม** (พจน์กลางหักกันหมด) ไม่คลาดแม้สตางค์เดียว
 *
 * **4. ขายหมด = ต้นทุนที่ตัดออกเท่ากับต้นทุนทั้งกองพอดี**
 * คิดจาก `round(ต้นทุนทั้งกอง × หน่วยที่ขาย ÷ หน่วยทั้งหมด)` บนจำนวนเต็ม
 * → ขายหมดได้ยอดเดิมเป๊ะ ไม่เหลือเศษค้างในบัญชีทรัพย์ (ทรัพย์ผีในงบดุล)
 *
 * **5. ข้อมูลไม่ครบ → `PostingError` ไม่เดา** (บทเรียน mace-windu ข้อ 1)
 * ไม่มีเส้นทางไหนคืนต้นทุน 0 แทนการปฏิเสธ เพราะต้นทุนต่ำกว่าจริง
 * = กำไรสูงกว่าจริง และผิดแบบนั้นไม่มีใครเห็น
 * --------------------------------------------------------------------------- *
 * **แหล่งความจริงของล็อตอยู่ที่ฐานข้อมูลแล้ว** (`sri_os.asset_lots` +
 * `asset_lot_consumptions` · 20261025000008) — โมดูลนี้เป็นตัวคำนวณบริสุทธิ์
 * สำหรับพรีวิวในหน้าจอ **ไม่ใช่แหล่งความจริง**: ผู้เรียกต้องส่งล็อตที่อ่านมาจาก
 * ตารางนั้น และตอนบันทึกจริง DB จะคำนวณต้นทุนถัวเฉลี่ยใหม่จากทะเบียนเองแล้ว
 * **ปฏิเสธ** ถ้ายอดที่ส่งมาไม่เท่ากับที่คำนวณได้ (`fn_assert_lot_consumption_sane_for`)
 * → ส่งต้นทุนผิดเข้ามาจะไม่มีผล ไม่ใช่ถูกใช้ (D-115)
 */

import { costBasisModeOfCategory, type CostBasisMode } from "@/lib/rules/asset-classes";
import { PostingError } from "./types";

/** ความละเอียดของจำนวนหน่วย — 8 ตำแหน่ง (คริปโตคือตัวที่ละเอียดสุด) */
const QTY_DECIMALS = 8;
const QTY_SCALE = 10 ** QTY_DECIMALS;

/** เงินบาทละเอียดถึงสตางค์ */
const SATANG_SCALE = 100;

/** เศษที่ยอมรับได้จาก float noise เวลาสเกลเป็นจำนวนเต็ม (หน่วยย่อย) */
const SCALE_EPSILON = 1e-3;

const MS_PER_DAY = 86_400_000;

/** หนึ่งล็อตที่ซื้อมา — `unitCost` คือ **ราคาที่ซื้อจริงในอดีต** (ไว้ตรวจสอบ) */
export type Lot = {
  id: string;
  /** ISO date หรือ ISO datetime — เทียบเป็นเวลา ไม่ใช่เทียบ string */
  acquiredAt: string;
  quantity: number;
  /** ต้นทุนต่อหน่วยของล็อตนั้น (บาท) รวมค่าธรรมเนียมซื้อที่ capitalize แล้ว */
  unitCost: number;
  ownerId: string;
  assetId: string;
};

/** กองรวมของทรัพย์ชิ้นหนึ่งในมือผู้ถือหนึ่งราย */
export type CostPool = {
  quantity: number;
  /** ต้นทุนรวมของกอง (บาท ทศนิยม 2 ตำแหน่ง) */
  totalCost: number;
  /** ต้นทุนถัวเฉลี่ยต่อหน่วย (บาท) — **ไม่ปัด** เพราะใช้คูณต่อ */
  unitCost: number;
  lots: number;
};

export type SellInput = {
  assetId: string;
  ownerId: string;
  quantity: number;
  /** เงินที่ได้รับสุทธิ (บาท) */
  proceeds: number;
  soldAt: string;
  /**
   * ส่วนเกินทุนจากการตีราคาที่ **ค้างอยู่ใน 3400 ของทรัพย์ชิ้นนี้** ก่อนขาย
   * บวก = เคยตีขึ้น · ลบ = เคยตีลง · 0 = ยังไม่เคยตีราคา
   *
   * **ต้องอ่านจากสมุดที่ post แล้วจริง** (`fn_asset_revaluation_surplus`)
   * ไม่ใช่จาก state ของหน้าจอ · ละไว้ = ถือว่า 0 ซึ่งเป็นค่าที่ **ตรวจได้**
   * (ถ้าของจริงไม่ใช่ 0 ด่าน `trg_assert_asset_cost_sane` ฝั่ง DB จะปฏิเสธใบนั้น
   *  เพราะส่วนเกินทุนที่ต้องล้างไม่ตรงสัดส่วน — ไม่ใช่ปล่อยให้ตัวเลขผิดเงียบๆ)
   */
  priorSurplus?: number;
};

export type ConsumedLot = {
  lotId: string;
  /** จำนวนที่ตัดจากล็อตนี้ (ตามสัดส่วนของทั้งกอง) */
  quantity: number;
  /** ต้นทุน **ถัวเฉลี่ย** ที่ตัดจากล็อตนี้ (บาท ทศนิยม 2 ตำแหน่ง) */
  cost: number;
};

/** บอกชัดว่ากำไรหรือขาดทุน เพื่อให้ชั้นถัดไปเลือก `gainCoa` / `lossCoa` ได้ */
export type SellOutcome = "gain" | "loss" | "breakeven";

export type SellResult = {
  consumed: ConsumedLot[];
  /** ต้นทุนถัวเฉลี่ยต่อหน่วยที่ใช้คิด (บาท · ไม่ปัด) */
  averageUnitCost: number;
  /** ต้นทุนที่ตัดออกทั้งหมด (บาท) = Σ consumed[].cost เป๊ะ */
  costRemoved: number;
  /** proceeds − costRemoved · ติดลบ = ขาดทุน */
  gain: number;
  outcome: SellOutcome;
  /** ต้นทุนของกองที่เหลือ = ต้นทุนก่อนขาย − costRemoved เป๊ะ */
  remainingCost: number;
  /** จำนวนที่เหลือในกอง */
  remainingQuantity: number;
  /**
   * ส่วนเกินทุนจากการตีราคาที่ **ต้องล้างในใบขายใบเดียวกัน** (บาท)
   * = ส่วนเกินก่อนขาย × (ต้นทุนที่ตัดออก ÷ ต้นทุนก่อนขาย)
   * บวก = เคยตีขึ้น (เดบิต 3400) · ลบ = เคยตีลง (เครดิต 3400) · 0 = ไม่มีอะไรต้องล้าง
   *
   * ขายหมด → เท่ากับส่วนเกินทั้งก้อนพอดี (3400 ของทรัพย์นั้นเหลือศูนย์)
   */
  surplusToReverse: number;
  /** กองก่อนขาย — ไว้ให้ผู้เรียกแสดงที่มาของตัวเลข */
  poolBefore: CostPool;
  /**
   * ล็อตที่เหลือ **ในขอบเขต owner + asset ที่ขาย** (ตัดทุกล็อตตามสัดส่วนเท่ากัน
   * จึงยังเห็นราคาที่ซื้อจริงของทุกล็อตอยู่ครบ = ตรวจสอบย้อนได้ตาม D-112)
   */
  remaining: Lot[];
  /**
   * สมุดล็อตทั้งก้อนหลังตัด — ของผู้ถืออื่น/ทรัพย์อื่นยังอยู่ครบ
   *
   * **ตอนบันทึกลงสมุดให้ใช้ตัวนี้** ส่วน `remaining` มีไว้ดู/ตรวจเฉพาะขอบเขต
   * (ถ้าเอา `remaining` ไปเขียนทับสมุดทั้งใบ ล็อตของผู้ถืออื่นจะหายเงียบๆ
   *  = ต้นทุนของคนอื่นหาย)
   */
  remainingBook: Lot[];
};

/* ------------------------------------------------------------------ *
 * ตัวช่วยตรวจข้อมูล — ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่เดา
 * ------------------------------------------------------------------ */

const fail = (message: string): never => {
  throw new PostingError(message);
};

function requireString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    fail(`${label} ต้องมีค่า — ข้อมูลไม่ครบ คิดต้นทุนถัวเฉลี่ยไม่ได้`);
  }
  return value as string;
}

function requireNumber(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    fail(`${label} ต้องเป็นตัวเลข — ข้อมูลไม่ครบ คิดต้นทุนถัวเฉลี่ยไม่ได้`);
  }
  return value as number;
}

/** แปลงจำนวนหน่วยเป็นจำนวนเต็มที่ความละเอียด 8 ตำแหน่ง · ละเอียดเกินนั้น = throw */
function toUnits(quantity: number, label: string): number {
  const scaled = quantity * QTY_SCALE;
  if (!Number.isFinite(scaled) || Math.abs(scaled) > Number.MAX_SAFE_INTEGER) {
    fail(`${label} ใหญ่เกินกว่าจะคิดได้แม่นยำ (${quantity})`);
  }
  const rounded = Math.round(scaled);
  if (Math.abs(scaled - rounded) > SCALE_EPSILON) {
    fail(`${label} ละเอียดเกิน ${QTY_DECIMALS} ตำแหน่ง (${quantity}) — ปัดให้เองไม่ได้ จำนวนจะเพี้ยน`);
  }
  // จำนวนที่ไม่เป็นศูนย์แต่เล็กกว่าครึ่งหน่วยจะถูกปัดเป็น 0 แล้วต้นทุนกลายเป็น 0
  // และกำไรเท่ากับยอดขายทั้งก้อน — ปฏิเสธ ไม่ปัด
  if (rounded === 0 && quantity !== 0) {
    fail(
      `${label} เล็กกว่าหน่วยที่เล็กที่สุดที่ระบบเก็บได้ (${quantity}) — ` +
        `ปัดเป็น 0 ไม่ได้ เพราะต้นทุนจะกลายเป็น 0 แล้วกำไรจะสูงกว่าจริง`,
    );
  }
  return rounded;
}

/** จำนวนเต็มหน่วย → จำนวนจริง (หารครั้งเดียว จึงไม่มีเศษสะสม) */
const fromUnits = (units: number): number => units / QTY_SCALE;

function toSatang(baht: number, label: string): number {
  const scaled = baht * SATANG_SCALE;
  if (!Number.isFinite(scaled) || Math.abs(scaled) > Number.MAX_SAFE_INTEGER) {
    fail(`${label} ใหญ่เกินกว่าจะคิดได้แม่นยำ (${baht})`);
  }
  return Math.round(scaled);
}

const fromSatang = (satang: number): number => satang / SATANG_SCALE;

function parseTime(value: unknown, label: string): number {
  const text = requireString(value, label);
  const ms = Date.parse(text);
  if (Number.isNaN(ms)) fail(`${label} ไม่ใช่วันที่ที่อ่านได้: "${text}"`);
  return ms;
}

/** วันตามปฏิทิน UTC — เทียบ "ซื้อหลังวันที่ขาย" โดยไม่แพ้ความละเอียดของเวลาที่ต่างกัน */
const utcDay = (ms: number): number => Math.floor(ms / MS_PER_DAY);

const formatQty = (units: number): string => String(fromUnits(units));

type ScopedLot = {
  source: Lot;
  units: number;
  acquiredMs: number;
  /** ต้นทุนของล็อตนี้เป็นจำนวนเต็มสตางค์ (ยอดจริง ยังไม่ปัด) */
  exactSatang: number;
};

function assertLotIdentity(lots: Lot[]): void {
  lots.forEach((lot, i) => {
    if (lot === null || typeof lot !== "object") fail(`ล็อตลำดับที่ ${i + 1} ไม่ใช่ข้อมูลล็อต`);
    requireString(lot.id, `ล็อตลำดับที่ ${i + 1}: id`);
    requireString(lot.ownerId, `ล็อต ${String(lot.id)}: ownerId`);
    requireString(lot.assetId, `ล็อต ${String(lot.id)}: assetId`);
  });
}

function requireLots(lots: Lot[] | undefined | null): Lot[] {
  if (!Array.isArray(lots)) fail("ไม่ได้ส่งรายการล็อตมา — คิดต้นทุนถัวเฉลี่ยไม่ได้");
  assertLotIdentity(lots as Lot[]);
  return lots as Lot[];
}

/**
 * ล็อตในขอบเขต owner + asset
 *
 * เรียงตามวันที่ซื้อ (เก่าก่อน · tie-break ด้วย id) **เพื่อให้ผลลัพธ์เหมือนกันทุกครั้ง**
 * ไม่ใช่เพราะลำดับมีผลต่อต้นทุน — ถัวเฉลี่ยไม่สนลำดับ แต่ `consumed[]` ที่สลับที่
 * ทำให้ diff ของรายงานและเทสต์ไม่เสถียร
 */
function scopeLots(lots: Lot[], ownerId: string, assetId: string): ScopedLot[] {
  const inScope = lots.filter((l) => l.ownerId === ownerId && l.assetId === assetId);

  const seen = new Set<string>();
  for (const l of inScope) {
    if (seen.has(l.id)) {
      fail(`ล็อต id ซ้ำในขอบเขตเดียวกัน: "${l.id}" — สมุดล็อตพัง ตรวจย้อนไม่ได้`);
    }
    seen.add(l.id);
  }

  const scoped: ScopedLot[] = inScope.map((l) => {
    const quantity = requireNumber(l.quantity, `ล็อต ${l.id}: quantity`);
    if (quantity <= 0) {
      fail(`ล็อต ${l.id}: quantity ต้องมากกว่า 0 (ได้ ${quantity}) — ล็อตที่หมดแล้วต้องไม่อยู่ในสมุด`);
    }
    const unitCost = requireNumber(l.unitCost, `ล็อต ${l.id}: unitCost`);
    if (unitCost < 0) fail(`ล็อต ${l.id}: unitCost ติดลบไม่ได้ (ได้ ${unitCost})`);
    const units = toUnits(quantity, `ล็อต ${l.id}: quantity`);
    // units/QTY_SCALE × unitCost × SATANG_SCALE  →  units × unitCost / 1e6
    const exactSatang = (units * unitCost) / (QTY_SCALE / SATANG_SCALE);
    if (!Number.isFinite(exactSatang) || Math.abs(exactSatang) > Number.MAX_SAFE_INTEGER) {
      fail(`ล็อต ${l.id}: ต้นทุนใหญ่เกินกว่าจะคิดได้แม่นยำ`);
    }
    return {
      source: l,
      units,
      acquiredMs: parseTime(l.acquiredAt, `ล็อต ${l.id}: acquiredAt`),
      exactSatang,
    };
  });

  return scoped.sort((a, b) => {
    if (a.acquiredMs !== b.acquiredMs) return a.acquiredMs - b.acquiredMs;
    if (a.source.id < b.source.id) return -1;
    if (a.source.id > b.source.id) return 1;
    return 0;
  });
}

/* ------------------------------------------------------------------ *
 * ข้อมูลอ้างอิงของทรัพย์ — **วิธีคิดต้นทุนต้องมาจากที่นี่ ไม่ใช่จากผู้เรียก**
 * ------------------------------------------------------------------ */

/**
 * สิ่งที่ `lib/ledger` ต้องรู้เกี่ยวกับทรัพย์หนึ่งชิ้น — **แค่หมวด**
 *
 * ไม่มี `canAverage` / `isCondo` / `ticker` ให้ส่งเข้ามาโดยตั้งใจ (D-115):
 * ถ้ารับธง "เฉลี่ยได้" จากผู้เรียกตรงๆ ด่านทั้งชุดในไฟล์นี้จะเชื่อสิ่งที่
 * หน้าจอส่งมา แล้วคอนโดที่ถูกติดป้ายผิดก็จะถูกเฉลี่ยได้ทันที
 * หมวดเป็นค่าที่เลือกตอน**สร้างทรัพย์** และฝั่ง DB อ่านจากตารางอ้างอิง
 * `asset_categories.cost_basis_mode` ที่แก้ได้ด้วย migration เท่านั้น
 */
export type AssetRef = {
  assetId: string;
  /** รหัสหมวดย่อยจาก `asset_categories.code` (เช่น `RE_RENTAL`, `COM_GOLD`) */
  categoryCode: string;
};

/**
 * ตัวอ่านข้อมูลอ้างอิงของทรัพย์ — ฝั่งจริงอ่านจาก `sri_os.assets` + `asset_categories`
 * ฝั่งเทสต์ส่งฟังก์ชันจำลองเข้ามา · **ห้าม import ตาราง mock เข้ามาในไฟล์นี้**
 */
export type AssetBook = (assetId: string) => AssetRef | null | undefined;

/**
 * **วิธีคิดต้นทุนของทรัพย์ชิ้นนี้** — ข้อมูลไม่ครบ → `PostingError` ห้ามเดา
 *
 * - ไม่ส่งตัวอ่านมา → ปฏิเสธ (เดาว่า "เฉลี่ยได้" แปลว่าคอนโดถูกเฉลี่ยเงียบๆ)
 * - ตัวอ่านไม่รู้จักทรัพย์ → ปฏิเสธ (ตอนคิดเงินข้อมูลต้องครบ)
 * - รู้จักทรัพย์แต่หมวดไม่รู้จัก/ว่าง → `whole_item` ซึ่งเป็นค่าที่ **ปฏิเสธการเฉลี่ย**
 *   (ตรงกับ `asset_categories.cost_basis_mode default 'whole_item'` ฝั่ง DB)
 */
export function costBasisModeFor(assetId: string, assets: AssetBook): CostBasisMode {
  const id = requireString(assetId, "assetId");
  if (typeof assets !== "function") {
    fail(
      `ไม่ได้ส่งข้อมูลอ้างอิงของทรัพย์ ${id} มา — ตัดสินวิธีคิดต้นทุนไม่ได้ · ` +
        "ลูกพี่สั่ง 25/10 ว่าเฉลี่ยได้เฉพาะ หุ้นในตลาดหลักทรัพย์ · คริปโต · ทองคำ " +
        "ซึ่งอ่านจากหมวดของทรัพย์เท่านั้น (ห้ามเดา ห้ามอนุมานจาก ticker หรือรหัสบัญชี)",
    );
  }
  const ref = assets(id);
  if (ref === null || ref === undefined) {
    // throw ตรงๆ ไม่ผ่าน fail() เพราะ TS ไม่แคบชนิดจากฟังก์ชัน never ที่เก็บใน const
    throw new PostingError(
      `ไม่พบทรัพย์ ${id} ในข้อมูลอ้างอิง — คิดต้นทุนไม่ได้ · ต้องสร้างทรัพย์และเลือกหมวดให้ชัดก่อน ` +
        "(หมวดคือตัวตัดสินว่าเฉลี่ยต้นทุนได้หรือไม่)",
    );
  }
  if (typeof ref !== "object") fail(`ข้อมูลอ้างอิงของทรัพย์ ${id} ไม่ใช่ข้อมูลทรัพย์`);
  if (typeof ref.assetId === "string" && ref.assetId !== id) {
    fail(
      `ข้อมูลอ้างอิงตอบทรัพย์ ${ref.assetId} ขณะที่ถามทรัพย์ ${id} — ` +
        "ตัวอ่านทรัพย์ตอบผิดชิ้น ปล่อยผ่านคือคิดต้นทุนของทรัพย์คนละชิ้น",
    );
  }
  return costBasisModeOfCategory(ref.categoryCode);
}

const MODE_LABEL: Record<CostBasisMode, string> = {
  average: "ถัวเฉลี่ยถ่วงน้ำหนักทั้งกอง",
  specific_lot: "ระบุล็อตที่ขาย (ห้ามเฉลี่ย)",
  whole_item: "ทรัพย์ชิ้นเดียว แบ่งไม่ได้ (ห้ามเฉลี่ย)",
};

/** ชื่อฟังก์ชันที่ควรใช้ของแต่ละโหมด — ข้อความต้องชี้ทางออก ไม่ใช่แค่บอกว่าผิด */
const MODE_ENTRY: Record<CostBasisMode, string> = {
  average: "sellAtAverageCost()",
  specific_lot: "sellBySpecificLots()",
  whole_item: "sellWholeItem()",
};

function requireMode(assetId: string, assets: AssetBook, want: CostBasisMode): CostBasisMode {
  const mode = costBasisModeFor(assetId, assets);
  if (mode !== want) {
    fail(
      `ทรัพย์ ${assetId} คิดต้นทุนแบบ "${MODE_LABEL[mode]}" จึงใช้เส้นทาง ` +
        `"${MODE_LABEL[want]}" ไม่ได้ — ใช้ ${MODE_ENTRY[mode]} แทน · ` +
        "ลูกพี่สั่ง 25/10: เฉลี่ยได้เฉพาะ หุ้นในตลาดหลักทรัพย์ · คริปโต · ทองคำ " +
        "ที่เหลือห้ามเฉลี่ยทั้งหมด (อสังหาฯ ทุกชนิด · **หุ้นบริษัทนอกตลาด** · " +
        "สินทรัพย์ทางเลือกอื่นที่ไม่ใช่ทอง)",
    );
  }
  return mode;
}

/* ------------------------------------------------------------------ *
 * API
 * ------------------------------------------------------------------ */

/** จำนวนคงเหลือในขอบเขต owner + asset (ล็อตของผู้ถืออื่น/ทรัพย์อื่นไม่ถูกนับ) */
export function availableQuantity(lots: Lot[], ownerId: string, assetId: string): number {
  const scoped = scopeLots(requireLots(lots), requireString(ownerId, "ownerId"), requireString(assetId, "assetId"));
  return fromUnits(scoped.reduce((sum, l) => sum + l.units, 0));
}

/**
 * กองรวม + **ต้นทุนถัวเฉลี่ยต่อหน่วย** ของทรัพย์ชิ้นหนึ่งในมือผู้ถือหนึ่งราย
 *
 * ไม่มีล็อตในขอบเขต = `PostingError` ไม่ใช่คืนกองว่างที่ต้นทุน 0
 * (กอง 0 ที่ถูกนำไปคิดกำไรแปลว่ากำไร = ยอดขายทั้งก้อน)
 */
export function costPoolOf(
  lots: Lot[],
  ownerId: string,
  assetId: string,
  assets: AssetBook,
): CostPool {
  const owner = requireString(ownerId, "ownerId");
  const asset = requireString(assetId, "assetId");
  // **กองรวมมีความหมายเฉพาะทรัพย์ที่เฉลี่ยได้** — คอนโดสองห้องไม่ใช่ "กอง"
  requireMode(asset, assets, "average");
  const scoped = scopeLots(requireLots(lots), owner, asset);
  if (scoped.length === 0) {
    fail(
      `ไม่มีล็อตของทรัพย์ ${asset} ในมือผู้ถือ ${owner} เลย — คิดต้นทุนถัวเฉลี่ยไม่ได้ ` +
        "ต้องบันทึกใบซื้อให้ครบก่อน (ระบบจะไม่สมมติต้นทุนให้)",
    );
  }

  const units = scoped.reduce((sum, l) => sum + l.units, 0);
  const totalSatang = Math.round(scoped.reduce((sum, l) => sum + l.exactSatang, 0));
  const totalCost = fromSatang(totalSatang);

  return {
    quantity: fromUnits(units),
    totalCost,
    // ต้นทุนต่อหน่วย **ไม่ปัด** — ปัดที่นี่แล้วคูณกลับจะคลาดจากยอดกองจริง
    unitCost: totalCost / fromUnits(units),
    lots: scoped.length,
  };
}

/**
 * ส่วนเกินทุนจากการตีราคาที่ต้องล้างเมื่อขายออกบางส่วน (**D-112**)
 *
 *     ส่วนเกินที่ต้องล้าง = ส่วนเกินก่อนขาย × (ต้นทุนที่ตัดออก ÷ ต้นทุนก่อนขาย)
 *
 * แยกเป็นฟังก์ชัน export เพราะ **ด่านฝั่ง DB ใช้สมการเดียวกันตัวต่อตัว**
 * (`fn_assert_asset_cost_sane` ข้อ ข) และหน้าจอต้องแสดงยอดเดียวกันกับที่ด่านจะยอมรับ
 * ถ้าคิดกันเองสองที่ ผู้ใช้จะเห็นยอดหนึ่งแล้วกดบันทึกไม่ได้โดยไม่รู้ว่าทำไม
 */
export function surplusToReverseFor(input: {
  priorSurplus: number;
  costBefore: number;
  costRemoved: number;
}): number {
  const prior = requireNumber(input?.priorSurplus, "ส่วนเกินทุนที่ค้างอยู่");
  const before = requireNumber(input?.costBefore, "ต้นทุนก่อนขาย");
  const removed = requireNumber(input?.costRemoved, "ต้นทุนที่ตัดออก");
  if (prior === 0) return 0;
  if (!(before > 0)) {
    fail(
      `ทรัพย์มีส่วนเกินทุนจากการตีราคาค้างอยู่ ${prior} บาท แต่ต้นทุนก่อนขายเป็น ${before} — ` +
        "คิดสัดส่วนที่ขายออกไม่ได้ · ส่วนเกินทุนที่ไม่มีต้นทุนรองรับแปลว่าใบซื้อหายไปจากสมุด",
    );
  }
  if (removed < 0 || removed > before) {
    fail(`ต้นทุนที่ตัดออก (${removed}) ต้องอยู่ระหว่าง 0 ถึงต้นทุนก่อนขาย (${before})`);
  }
  // คิดบนจำนวนเต็มสตางค์ → ขายหมดได้ส่วนเกินทั้งก้อนพอดี ไม่เหลือเศษค้างใน 3400
  const priorSatang = toSatang(prior, "ส่วนเกินทุนที่ค้างอยู่");
  const beforeSatang = toSatang(before, "ต้นทุนก่อนขาย");
  const removedSatang = toSatang(removed, "ต้นทุนที่ตัดออก");
  if (removedSatang === beforeSatang) return fromSatang(priorSatang);
  return fromSatang(Math.round((priorSatang * removedSatang) / beforeSatang));
}

/**
 * ขายออกด้วย **ต้นทุนถัวเฉลี่ย** (D-112) — ตัดทุกล็อตตามสัดส่วนเท่ากัน
 *
 * ล็อตไม่พอ · ข้อมูลไม่ครบ · จำนวนหรือยอดเงินไม่ถูกต้อง → `PostingError`
 */
export function sellAtAverageCost(lots: Lot[], input: SellInput, assets: AssetBook): SellResult {
  const safeLots = requireLots(lots);
  if (input === null || typeof input !== "object") {
    fail("ไม่ได้ส่งข้อมูลการขายมา — คิดต้นทุนถัวเฉลี่ยไม่ได้");
  }

  const assetId = requireString(input.assetId, "assetId");
  /**
   * **ถัวเฉลี่ยได้เฉพาะ หุ้นในตลาดหลักทรัพย์ · คริปโต · ทองคำ** (ลูกพี่สั่ง 25/10)
   * อ่านจากหมวดของทรัพย์ในข้อมูลอ้างอิง ไม่ใช่จากธงที่ผู้เรียกส่งมา (D-115)
   */
  requireMode(assetId, assets, "average");
  const ownerId = requireString(input.ownerId, "ownerId");
  const quantity = requireNumber(input.quantity, "quantity");
  const proceeds = requireNumber(input.proceeds, "proceeds");
  const soldMs = parseTime(input.soldAt, "soldAt");
  const priorSurplus =
    input.priorSurplus === undefined ? 0 : requireNumber(input.priorSurplus, "ส่วนเกินทุนที่ค้างอยู่");

  if (quantity <= 0) fail(`จำนวนที่ขายต้องมากกว่า 0 (ได้ ${quantity})`);
  if (proceeds < 0) {
    fail(`ยอดเงินที่ได้รับติดลบไม่ได้ (ได้ ${proceeds}) — ถ้ามีค่าใช้จ่ายให้หักก่อนส่งเข้ามา`);
  }

  const wantUnits = toUnits(quantity, "จำนวนที่ขาย");
  const scoped = scopeLots(safeLots, ownerId, assetId);
  const totalUnits = scoped.reduce((sum, l) => sum + l.units, 0);

  if (totalUnits < wantUnits) {
    fail(
      `ล็อตคงเหลือไม่พอ: ต้องการ ${formatQty(wantUnits)} แต่มี ${formatQty(totalUnits)} ` +
        `(ผู้ถือ ${ownerId} · ทรัพย์ ${assetId}) — ต้องบันทึกล็อตที่ซื้อให้ครบก่อน ` +
        "ระบบจะไม่ตัดล็อตของผู้ถืออื่นและไม่สมมติต้นทุนให้",
    );
  }

  // ซื้อหลังวันที่ขายไม่ได้ — เทียบเป็นวันตามปฏิทิน เพราะในสมุดมีทั้ง acquiredAt
  // ที่มีเวลาและไม่มีเวลา · ถัวเฉลี่ยรวมทุกล็อต จึงต้องตรวจ **ทุกล็อตในกอง**
  // ไม่ใช่แค่ล็อตที่ถูกตัด (ล็อตอนาคตเจือต้นทุนเข้ามาในค่าเฉลี่ยทันที)
  const soldDay = utcDay(soldMs);
  for (const lot of scoped) {
    if (utcDay(lot.acquiredMs) > soldDay) {
      fail(
        `ล็อต ${lot.source.id} ซื้อวันที่ ${lot.source.acquiredAt} ซึ่งหลังวันที่ขาย ${input.soldAt} ` +
          "— เอาล็อตที่ยังไม่ได้ซื้อมาเฉลี่ยต้นทุนไม่ได้ (ต้นทุนเฉลี่ยจะเพี้ยนทั้งกอง)",
      );
    }
  }

  const totalSatang = Math.round(scoped.reduce((sum, l) => sum + l.exactSatang, 0));
  // ต้นทุนที่ตัดออก: สัดส่วนบนจำนวนเต็ม → ขายหมดได้ยอดเดิมเป๊ะ
  const removedSatang =
    wantUnits === totalUnits ? totalSatang : Math.round((totalSatang * wantUnits) / totalUnits);

  /**
   * แบ่ง "จำนวนที่ขาย" และ "ต้นทุนที่ตัด" ลงแต่ละล็อตตามสัดส่วน
   * ด้วยวิธียอดสะสม → Σ ของทั้งสองเท่ากับยอดรวมโดยนิยาม (ไม่คลาดแม้หน่วยเดียว)
   */
  let cumUnitsBefore = 0;
  let takenUnitsCum = 0;
  let takenSatangCum = 0;
  const takenByLotId = new Map<string, number>();
  const consumed: ConsumedLot[] = [];

  scoped.forEach((lot, i) => {
    cumUnitsBefore += lot.units;
    const isLast = i === scoped.length - 1;
    const takeUnitsCum = isLast
      ? wantUnits
      : Math.round((wantUnits * cumUnitsBefore) / totalUnits);
    const takeSatangCum = isLast
      ? removedSatang
      : Math.round((removedSatang * cumUnitsBefore) / totalUnits);
    const takeUnits = takeUnitsCum - takenUnitsCum;
    const takeSatang = takeSatangCum - takenSatangCum;
    takenUnitsCum = takeUnitsCum;
    takenSatangCum = takeSatangCum;
    if (takeUnits > 0 || takeSatang !== 0) {
      takenByLotId.set(lot.source.id, takeUnits);
      consumed.push({
        lotId: lot.source.id,
        quantity: fromUnits(takeUnits),
        cost: fromSatang(takeSatang),
      });
    }
  });

  const costRemoved = fromSatang(removedSatang);
  const remainingCost = fromSatang(totalSatang - removedSatang);
  const gainSatang = toSatang(proceeds, "ยอดเงินที่ได้รับ") - removedSatang;

  const remainingUnitsOf = (lot: Lot, units: number): number => units - (takenByLotId.get(lot.id) ?? 0);

  const remaining: Lot[] = scoped
    .map((s) => ({ source: s.source, units: remainingUnitsOf(s.source, s.units) }))
    .filter((s) => s.units > 0)
    .map((s) => ({ ...s.source, quantity: fromUnits(s.units) }));

  const inScope = (l: Lot) => l.ownerId === ownerId && l.assetId === assetId;
  const scopedUnitsById = new Map(scoped.map((s) => [s.source.id, s.units]));
  const remainingBook: Lot[] = [];
  for (const l of safeLots) {
    if (!inScope(l)) {
      remainingBook.push({ ...l });
      continue;
    }
    const left = remainingUnitsOf(l, scopedUnitsById.get(l.id) ?? 0);
    if (left > 0) remainingBook.push({ ...l, quantity: fromUnits(left) });
  }

  const totalCost = fromSatang(totalSatang);
  const poolBefore: CostPool = {
    quantity: fromUnits(totalUnits),
    totalCost,
    unitCost: totalCost / fromUnits(totalUnits),
    lots: scoped.length,
  };

  return {
    consumed,
    averageUnitCost: poolBefore.unitCost,
    costRemoved,
    gain: fromSatang(gainSatang),
    outcome: gainSatang > 0 ? "gain" : gainSatang < 0 ? "loss" : "breakeven",
    remainingCost,
    remainingQuantity: fromUnits(totalUnits - wantUnits),
    surplusToReverse: surplusToReverseFor({ priorSurplus, costBefore: totalCost, costRemoved }),
    poolBefore,
    remaining,
    remainingBook,
  };
}

/* ------------------------------------------------------------------ *
 * เส้นทางที่ **ห้ามเฉลี่ย** (ลูกพี่สั่ง 25/10)
 * ------------------------------------------------------------------ */

/** ล็อตที่ผู้ใช้ **ระบุ** ว่าจะขาย — ไม่ใช่ให้ระบบเลือกให้ (ไม่มี FIFO ไม่มีเฉลี่ย) */
export type LotPick = { lotId: string; quantity: number };

export type SpecificLotSellInput = {
  assetId: string;
  ownerId: string;
  /** ล็อตที่ขายและจำนวนของแต่ละล็อต — **ต้องระบุ** ว่างไม่ได้ */
  picks: LotPick[];
  proceeds: number;
  soldAt: string;
  priorSurplus?: number;
};

export type SpecificLotSellResult = {
  mode: "specific_lot";
  /** ต้นทุนที่ตัดจากแต่ละล็อต — **ราคาของล็อตนั้นเอง** ไม่ใช่ค่าเฉลี่ยของกอง */
  consumed: ConsumedLot[];
  costRemoved: number;
  gain: number;
  outcome: SellOutcome;
  surplusToReverse: number;
  remainingCost: number;
  remainingQuantity: number;
  remaining: Lot[];
  remainingBook: Lot[];
  /**
   * ต้นทุนถ้า**เผลอ**คิดแบบถัวเฉลี่ย — มีไว้ให้หน้าจอ/เทสต์เห็นว่าสองทางต่างกันเท่าไร
   * **ห้ามนำไปลงบัญชี** (ชื่อฟิลด์บอกตรงๆ ว่าเป็นของเทียบ ไม่ใช่ของใช้)
   */
  costIfAveragedWrongly: number;
};

/**
 * ขายโดย **ระบุล็อต** — ต้นทุนมาจากราคาของล็อตนั้นเอง (หุ้นนอกตลาด · ETF · กองทุน · พันธบัตร)
 *
 * ตรวจ **รายล็อต** ไม่ใช่รายทรัพย์ เพราะรายทรัพย์จะยอมให้สลับยอดระหว่าง
 * ล็อตแพงกับล็อตถูกแล้วผลรวมยังตรง (รูปเดียวกับด่านฝั่ง DB ข้อ ข-2)
 *
 * การหาร `ต้นทุนล็อต ÷ จำนวนล็อต` **ไม่ใช่การเฉลี่ย**: ทุกหน่วยในล็อตเดียว
 * ซื้อมาในราคาเดียวกันจริง ไม่ได้เอาราคาของล็อตอื่นมาเจือ
 */
export function sellBySpecificLots(
  lots: Lot[],
  input: SpecificLotSellInput,
  assets: AssetBook,
): SpecificLotSellResult {
  const safeLots = requireLots(lots);
  if (input === null || typeof input !== "object") {
    fail("ไม่ได้ส่งข้อมูลการขายมา — คิดต้นทุนรายล็อตไม่ได้");
  }
  const assetId = requireString(input.assetId, "assetId");
  const ownerId = requireString(input.ownerId, "ownerId");
  requireMode(assetId, assets, "specific_lot");

  const proceeds = requireNumber(input.proceeds, "proceeds");
  const soldMs = parseTime(input.soldAt, "soldAt");
  const priorSurplus =
    input.priorSurplus === undefined ? 0 : requireNumber(input.priorSurplus, "ส่วนเกินทุนที่ค้างอยู่");
  if (proceeds < 0) {
    fail(`ยอดเงินที่ได้รับติดลบไม่ได้ (ได้ ${proceeds}) — ถ้ามีค่าใช้จ่ายให้หักก่อนส่งเข้ามา`);
  }

  if (!Array.isArray(input.picks) || input.picks.length === 0) {
    fail(
      `ทรัพย์ ${assetId} ห้ามถัวเฉลี่ยต้นทุน จึง **ต้องระบุล็อตที่ขาย** — ไม่ได้ส่ง picks มา · ` +
        "ถ้าไม่ระบุ ระบบต้องเดาว่าตัดล็อตไหน ซึ่งการเดาทุกแบบ (เก่าก่อน · ถูกก่อน · เฉลี่ย) " +
        "ให้กำไรคนละตัวเลข และเป็นการตัดสินใจเรื่องเงินแทนผู้ใช้โดยไม่มีใครเห็น",
    );
  }

  const scoped = scopeLots(safeLots, ownerId, assetId);
  if (scoped.length === 0) {
    fail(
      `ไม่มีล็อตของทรัพย์ ${assetId} ในมือผู้ถือ ${ownerId} เลย — ตัดต้นทุนไม่ได้ ` +
        "ต้องบันทึกใบซื้อให้ครบก่อน (ระบบจะไม่สมมติต้นทุนให้)",
    );
  }
  const soldDay = utcDay(soldMs);
  const byId = new Map(scoped.map((l) => [l.source.id, l]));

  let removedSatang = 0;
  let removedUnits = 0;
  const takenByLotId = new Map<string, number>();
  const consumed: ConsumedLot[] = [];

  input.picks.forEach((pick, i) => {
    if (pick === null || typeof pick !== "object") fail(`picks[${i}] ไม่ใช่ข้อมูลล็อตที่ขาย`);
    const lotId = requireString(pick.lotId, `picks[${i}].lotId`);
    const lot = byId.get(lotId);
    if (!lot) {
      fail(
        `ล็อต "${lotId}" ไม่อยู่ในสมุดของทรัพย์ ${assetId} ผู้ถือ ${ownerId} — ` +
          "ระบุล็อตที่ไม่มีอยู่แปลว่าต้นทุนที่ตัดไม่มีที่มา",
      );
    }
    if (takenByLotId.has(lotId)) {
      fail(`ระบุล็อต "${lotId}" ซ้ำสองครั้งใน picks — รวมจำนวนให้เป็นรายการเดียวก่อนส่งเข้ามา`);
    }
    if (utcDay(lot!.acquiredMs) > soldDay) {
      fail(
        `ล็อต ${lotId} ซื้อวันที่ ${lot!.source.acquiredAt} ซึ่งหลังวันที่ขาย ${input.soldAt} — ` +
          "ขายของที่ยังไม่ได้ซื้อไม่ได้",
      );
    }

    const wantUnits = toUnits(requireNumber(pick.quantity, `picks[${i}].quantity`), `picks[${i}].quantity`);
    if (wantUnits <= 0) fail(`picks[${i}].quantity ต้องมากกว่า 0 (ได้ ${pick.quantity})`);
    if (wantUnits > lot!.units) {
      fail(
        `ขายจากล็อต ${lotId} ${formatQty(wantUnits)} หน่วย แต่ล็อตนั้นมี ${formatQty(lot!.units)} หน่วย — ` +
          "ขายเกินล็อตไม่ได้ · ถ้าจะขายมากกว่านั้น ให้ระบุล็อตเพิ่ม ไม่ใช่เพิ่มจำนวนในล็อตเดียว",
      );
    }

    // ตัดล็อตหมดพอดี → ตัดต้นทุนของล็อตนั้นทั้งก้อน (ไม่เหลือเศษสตางค์)
    const takeSatang =
      wantUnits === lot!.units
        ? Math.round(lot!.exactSatang)
        : Math.round((lot!.exactSatang * wantUnits) / lot!.units);

    takenByLotId.set(lotId, wantUnits);
    removedUnits += wantUnits;
    removedSatang += takeSatang;
    consumed.push({ lotId, quantity: fromUnits(wantUnits), cost: fromSatang(takeSatang) });
  });

  const totalUnits = scoped.reduce((sum, l) => sum + l.units, 0);
  const totalSatang = Math.round(scoped.reduce((sum, l) => sum + l.exactSatang, 0));
  const totalCost = fromSatang(totalSatang);
  const costRemoved = fromSatang(removedSatang);
  const gainSatang = toSatang(proceeds, "ยอดเงินที่ได้รับ") - removedSatang;

  // ค่าเฉลี่ยของทั้งกอง — **คิดไว้เพื่อเทียบเท่านั้น** ไม่เคยถูกใช้ลงบัญชี
  const costIfAveragedWrongly =
    removedUnits === totalUnits
      ? totalCost
      : fromSatang(Math.round((totalSatang * removedUnits) / totalUnits));

  const remainingOf = (lot: Lot, units: number) => units - (takenByLotId.get(lot.id) ?? 0);
  const remaining: Lot[] = scoped
    .map((sl) => ({ source: sl.source, units: remainingOf(sl.source, sl.units) }))
    .filter((x) => x.units > 0)
    .map((x) => ({ ...x.source, quantity: fromUnits(x.units) }));

  const scopedUnitsById = new Map(scoped.map((sl) => [sl.source.id, sl.units]));
  const remainingBook: Lot[] = [];
  for (const l of safeLots) {
    if (l.ownerId !== ownerId || l.assetId !== assetId) {
      remainingBook.push({ ...l });
      continue;
    }
    const left = remainingOf(l, scopedUnitsById.get(l.id) ?? 0);
    if (left > 0) remainingBook.push({ ...l, quantity: fromUnits(left) });
  }

  return {
    mode: "specific_lot",
    consumed,
    costRemoved,
    gain: fromSatang(gainSatang),
    outcome: gainSatang > 0 ? "gain" : gainSatang < 0 ? "loss" : "breakeven",
    surplusToReverse: surplusToReverseFor({ priorSurplus, costBefore: totalCost, costRemoved }),
    remainingCost: fromSatang(totalSatang - removedSatang),
    remainingQuantity: fromUnits(totalUnits - removedUnits),
    remaining,
    remainingBook,
    costIfAveragedWrongly,
  };
}

export type WholeItemSellInput = {
  assetId: string;
  ownerId: string;
  proceeds: number;
  soldAt: string;
  /**
   * ต้นทุนของ **ชิ้นนั้นทั้งก้อน** ตามสมุดที่ post แล้ว (`fn_asset_cost_basis`)
   * ไม่ใช่ราคาประเมิน และไม่ใช่ค่าเฉลี่ยของทรัพย์อื่นในตึกเดียวกัน
   */
  assetCost: number;
  /** ส่วนเกินทุน (3400) ที่ค้างอยู่ของชิ้นนั้น — ละไว้ = 0 */
  priorSurplus?: number;
};

export type WholeItemSellResult = {
  mode: "whole_item";
  costRemoved: number;
  gain: number;
  outcome: SellOutcome;
  /** **ทั้งก้อน** — ทรัพย์ชิ้นเดียวไม่มีสัดส่วนให้คิด */
  surplusToReverse: number;
  remainingCost: 0;
  remainingQuantity: 0;
};

/**
 * ขายทรัพย์ชิ้นเดียวทั้งชิ้น (คอนโดรายห้อง · ที่ดิน · สัญญา · ของสะสม)
 *
 * **กำไร = ราคาขาย − ต้นทุนของชิ้นนั้นเอง** ไม่ใช่ค่าเฉลี่ยของห้องทั้งหมด
 * และ **ล้าง 3400 ทั้งก้อน** เพราะไม่มี "สัดส่วน" ให้คิด
 *
 * ขายบางส่วนไม่ได้โดยโครงสร้าง: ชนิดนี้ **ไม่มีช่อง `quantity`/`picks`**
 * และปฏิเสธเสียงดังถ้ามีคนส่งมา (เช่นลอกโค้ดมาจากเส้นทางถัวเฉลี่ย)
 */
export function sellWholeItem(input: WholeItemSellInput, assets: AssetBook): WholeItemSellResult {
  if (input === null || typeof input !== "object") {
    fail("ไม่ได้ส่งข้อมูลการขายมา — คิดต้นทุนไม่ได้");
  }
  const assetId = requireString(input.assetId, "assetId");
  requireString(input.ownerId, "ownerId");
  requireMode(assetId, assets, "whole_item");
  parseTime(input.soldAt, "soldAt");

  const extra = ["quantity", "picks", "units"].filter(
    (k) => (input as Record<string, unknown>)[k] !== undefined,
  );
  if (extra.length > 0) {
    fail(
      `ทรัพย์ ${assetId} เป็นทรัพย์ชิ้นเดียว **แบ่งขายไม่ได้** แต่ส่ง ${extra.join(", ")} มาด้วย — ` +
        "ขาย 30% ของคอนโดหนึ่งห้องไม่มีอยู่จริง · ถ้าจะแบ่งขายต้องแยกชิ้นก่อนตาม D-112 " +
        "(ขายออกทั้งชิ้นแล้วซื้อเข้าเป็นหลายชิ้น ยอดสองฝั่งหักกันได้ศูนย์)",
    );
  }

  const proceeds = requireNumber(input.proceeds, "proceeds");
  if (proceeds < 0) {
    fail(`ยอดเงินที่ได้รับติดลบไม่ได้ (ได้ ${proceeds}) — ถ้ามีค่าใช้จ่ายให้หักก่อนส่งเข้ามา`);
  }
  const assetCost = requireNumber(input.assetCost, "ต้นทุนของทรัพย์ชิ้นนี้");
  if (!(assetCost > 0)) {
    fail(
      `ต้นทุนของทรัพย์ ${assetId} ต้องมากกว่า 0 (ได้ ${assetCost}) — ` +
        "ทรัพย์ที่ไม่มีต้นทุนในสมุดแปลว่ายังไม่ได้บันทึกการซื้อ ตัดออกก่อนไม่ได้ · " +
        "ต้นทุนต้องอ่านจากสมุดที่ post แล้ว (fn_asset_cost_basis) ไม่ใช่จาก state ของหน้าจอ",
    );
  }
  const priorSurplus =
    input.priorSurplus === undefined ? 0 : requireNumber(input.priorSurplus, "ส่วนเกินทุนที่ค้างอยู่");

  const gainSatang = toSatang(proceeds, "ยอดเงินที่ได้รับ") - toSatang(assetCost, "ต้นทุนของทรัพย์ชิ้นนี้");

  return {
    mode: "whole_item",
    costRemoved: assetCost,
    gain: fromSatang(gainSatang),
    outcome: gainSatang > 0 ? "gain" : gainSatang < 0 ? "loss" : "breakeven",
    // **ทั้งก้อน** ไม่ผ่าน surplusToReverseFor() ซึ่งเป็นสมการของสัดส่วน
    surplusToReverse: round2Satang(priorSurplus),
    remainingCost: 0,
    remainingQuantity: 0,
  };
}

/** ปัดเป็นสตางค์ด้วยทางเดียวกับที่ใช้ทั้งไฟล์ (ติดลบได้ — เคยตีราคาลงคือเรื่องปกติ) */
function round2Satang(baht: number): number {
  return fromSatang(toSatang(baht, "ส่วนเกินทุนที่ค้างอยู่"));
}

/**
 * **ปากทางเดียวของการขาย** — เลือกเส้นทางจาก *ข้อมูลอ้างอิง* ไม่ใช่จากที่ผู้เรียกบอก
 *
 * ผู้เรียกส่งข้อมูลของเส้นทางไหนมา ถ้าไม่ตรงกับโหมดของทรัพย์ **ปฏิเสธ**
 * (ไม่ใช่แปลงให้ — การแปลงให้คือการตัดสินใจเรื่องเงินแทนผู้ใช้)
 */
export function planDisposal(
  lots: Lot[],
  input: SellInput | SpecificLotSellInput | WholeItemSellInput,
  assets: AssetBook,
): SellResult | SpecificLotSellResult | WholeItemSellResult {
  if (input === null || typeof input !== "object") fail("ไม่ได้ส่งข้อมูลการขายมา");
  const mode = costBasisModeFor(requireString(input.assetId, "assetId"), assets);
  if (mode === "average") return sellAtAverageCost(lots, input as SellInput, assets);
  if (mode === "specific_lot") return sellBySpecificLots(lots, input as SpecificLotSellInput, assets);
  return sellWholeItem(input as WholeItemSellInput, assets);
}

/**
 * ผลรวมต้นทุนที่ตัด — บวกบนจำนวนเต็มสตางค์
 * มีไว้ให้ผู้เรียก (และเทสต์) ตรวจ invariant `Σ consumed[].cost === costRemoved`
 * ได้โดยไม่เจอเศษ float จากการ `reduce` ทศนิยมตรงๆ
 */
export function sumConsumedCost(consumed: ConsumedLot[]): number {
  if (!Array.isArray(consumed)) fail("ไม่ได้ส่งรายการต้นทุนที่ตัดมา");
  let satang = 0;
  consumed.forEach((c, i) => {
    satang += toSatang(requireNumber(c?.cost, `consumed[${i}].cost`), `consumed[${i}].cost`);
  });
  return fromSatang(satang);
}
