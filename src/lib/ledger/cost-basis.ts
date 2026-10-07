import { PostingError } from "./types";

/**
 * ตัวคำนวณต้นทุนแบบ FIFO สำหรับทรัพย์ที่ซื้อ-ขายเป็นล็อต
 * (หุ้น 1700 · ทองคำ/สินทรัพย์ทางเลือก 1720 · คริปโต)
 *
 * ตัดสินแล้วว่าใช้ **FIFO ไม่ใช่ถัวเฉลี่ย** — ลูกพี่ยืนยัน 26/09 · D-038
 * (`docs/LEDGER_RULES.md` §6 ข้อ 1) ผลที่ตามมาคือต้องเก็บ **ทุกล็อตที่ซื้อ**
 * ไม่ใช่ต้นทุนเฉลี่ย เพราะถ้าเหลือแต่ค่าเฉลี่ย จะคิด FIFO ย้อนหลังไม่ได้เลย
 *
 * ไฟล์นี้ **ไม่สร้างบรรทัดบัญชี** — คืนแค่ต้นทุนที่ถูกตัด กำไร/ขาดทุน และล็อตที่เหลือ
 * การแปลงเป็นคู่บัญชี (`gainCoa` / `lossCoa`) เป็นหน้าที่ของตารางกฎ + `buildPosting()`
 * ตามกฎข้อ 3 ของ CLAUDE.md — ที่นี่ห้ามมีคู่บัญชี
 *
 * ## การตัดสินใจที่ตรึงไว้ที่นี่
 *
 * **1. ลำดับ FIFO (deterministic)** เรียงด้วย `acquiredAt` (เทียบเป็น "เวลา" ด้วย
 * `Date.parse` ไม่ใช่เทียบ string เพราะรูปแบบวันที่ในระบบมีทั้งแบบมีและไม่มีเวลา)
 * ถ้าเวลาเท่ากัน tie-break ด้วย `id` เรียงขึ้น — ผลลัพธ์จึงเหมือนกันทุกครั้ง
 * แม้ลำดับที่ DB คืนมาจะสลับ และ `id` ซ้ำในขอบเขตเดียวกันถือว่า **ข้อมูลพัง → throw**
 * เพราะ tie-break จะกำกวมและ `consumed[].lotId` จะชี้ไปสองล็อต
 *
 * **2. เศษสตางค์ — วิธียอดสะสม (running total / telescoping)**
 * ไม่ปัดต้นทุนของแต่ละล็อตแยกกันแล้วเอามาบวก เพราะทำแบบนั้นผลรวมจะเพี้ยนจากยอดจริง
 * (ตัวอย่างจริง: สามล็อต ล็อตละ 0.005 บาท ปัดแยกได้ 0.01×3 = 0.03 แต่ยอดจริง 0.015 = 0.02)
 * ที่ทำคือสะสม "ต้นทุนจริงเป็นสตางค์" ไปเรื่อยๆ ปัดเฉพาะ**ยอดสะสม**
 * แล้วเอา**ส่วนต่างของยอดสะสมที่ปัดแล้ว**เป็นต้นทุนของล็อตนั้น
 *   cost_i = round(cum_i) − round(cum_{i−1})
 * ผลรวม `consumed[].cost` จึงเท่ากับ `round(cum_last)` = `totalCost` **โดยนิยาม**
 * (พจน์กลางหักกันหมด) ไม่มีทางคลาดแม้สตางค์เดียว และต้นทุนของแต่ละล็อต
 * ก็ยังห่างจากค่าจริงไม่เกินหนึ่งสตางค์ · การบวกทั้งหมดทำบน**จำนวนเต็มสตางค์**
 * ไม่ใช่ทศนิยม float จึงไม่มีเศษลอยแบบ 0.1 + 0.2
 *
 * **3. จำนวนหน่วย** เก็บเป็นจำนวนเต็มที่ความละเอียด 8 ตำแหน่ง (รองรับคริปโต)
 * การลบทำบนจำนวนเต็ม `0.5 − 0.07654322` จึงได้ `0.42345678` พอดี
 * ไม่ใช่ `0.4234567799999`  จำนวนที่ละเอียดกว่า 8 ตำแหน่ง **throw** ไม่ปัดเงียบๆ
 */

/** ความละเอียดของจำนวนหน่วย — 8 ตำแหน่ง (คริปโตคือตัวที่ละเอียดสุด) */
const QTY_DECIMALS = 8;
const QTY_SCALE = 10 ** QTY_DECIMALS;

/** เงินบาทละเอียดถึงสตางค์ */
const SATANG_SCALE = 100;

/** เศษที่ยอมรับได้จาก float noise เวลาสเกลเป็นจำนวนเต็ม (หน่วยย่อย) */
const SCALE_EPSILON = 1e-3;

const MS_PER_DAY = 86_400_000;

/** หนึ่งล็อตที่ซื้อมา — ต้นทุนต่อหน่วยคงที่ตลอดอายุล็อต */
export type Lot = {
  id: string;
  /** ISO date หรือ ISO datetime — เทียบเป็นเวลา ไม่ใช่เทียบ string */
  acquiredAt: string;
  quantity: number;
  /** ต้นทุนต่อหน่วย (บาท) รวมค่าธรรมเนียมซื้อที่ capitalize แล้ว */
  unitCost: number;
  ownerId: string;
  assetId: string;
};

export type SellInput = {
  assetId: string;
  ownerId: string;
  quantity: number;
  /** เงินที่ได้รับสุทธิ (บาท) */
  proceeds: number;
  soldAt: string;
};

export type ConsumedLot = {
  lotId: string;
  quantity: number;
  /** ต้นทุนที่ตัดจากล็อตนี้ (บาท ทศนิยม 2 ตำแหน่ง) */
  cost: number;
};

/**
 * บอกชัดว่ากำไรหรือขาดทุน เพื่อให้ชั้นถัดไปเลือก `gainCoa` / `lossCoa` ได้
 * โดยไม่ต้องเทียบเครื่องหมายเอง (เทียบเองคือจุดที่กฎเดียวกันจะถูกเขียนสองที่)
 */
export type SellOutcome = "gain" | "loss" | "breakeven";

export type SellResult = {
  consumed: ConsumedLot[];
  /** ผลรวมต้นทุนที่ตัด (บาท) = Σ consumed[].cost เป๊ะ */
  totalCost: number;
  /** proceeds − totalCost · ติดลบ = ขาดทุน */
  gain: number;
  outcome: SellOutcome;
  /**
   * ล็อตที่เหลือ **ในขอบเขต owner + asset ที่ขาย** เรียงตามลำดับ FIFO
   * ล็อตที่ถูกตัดหมดจะไม่อยู่ในนี้
   */
  remaining: Lot[];
  /**
   * สมุดล็อตทั้งก้อนหลังตัด — ของผู้ถืออื่น/ทรัพย์อื่นยังอยู่ครบ
   *
   * มีไว้เพราะถ้าผู้เรียกเอา `remaining` ไปเขียนทับสมุดทั้งใบ
   * ล็อตของผู้ถืออื่นจะหายเงียบๆ (= ต้นทุนของคนอื่นหาย)
   * **ตอนบันทึกลงสมุดให้ใช้ `remainingBook`** ส่วน `remaining` มีไว้ดู/ตรวจเฉพาะขอบเขต
   */
  remainingBook: Lot[];
};

/* ------------------------------------------------------------------ *
 * ตัวช่วยตรวจข้อมูล — ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่เดา
 * (บทเรียน mace-windu ข้อ 1: เดาแล้วตัวเลขผิดเงียบๆ)
 * ------------------------------------------------------------------ */

const fail = (message: string): never => {
  throw new PostingError(message);
};

function requireString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    fail(`${label} ต้องมีค่า — ข้อมูลไม่ครบ คิดต้นทุน FIFO ไม่ได้`);
  }
  return value as string;
}

function requireNumber(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    fail(`${label} ต้องเป็นตัวเลข — ข้อมูลไม่ครบ คิดต้นทุน FIFO ไม่ได้`);
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
  // จำนวนที่ไม่เป็นศูนย์แต่เล็กกว่าครึ่งหน่วย (เช่น 1e-11) จะถูก Math.round ปัดเป็น 0
  // และ SCALE_EPSILON ก็ยอมให้ผ่าน เพราะส่วนต่างเท่ากับค่าเดิมซึ่งเล็กมาก
  // ถ้าปล่อยไว้ การขายเศษธุลีจะได้ต้นทุน 0 แล้วกำไรเท่ากับยอดขายทั้งก้อน
  // และล็อตเศษธุลีจะหายจากสมุดพร้อมต้นทุนของมัน — ปฏิเสธ ไม่ปัด
  if (rounded === 0 && quantity !== 0) {
    fail(
      `${label} เล็กกว่าหน่วยที่เล็กที่สุดที่ระบบเก็บได้ (${quantity}) — ` +
        `ปัดเป็น 0 ไม่ได้ เพราะต้นทุนจะกลายเป็น 0 แล้วกำไรจะสูงกว่าจริง`,
    );
  }
  return rounded;
}

/** จำนวนเต็มหน่วย → จำนวนจริง (ผ่านการหารครั้งเดียว จึงไม่มีเศษสะสม) */
const fromUnits = (units: number): number => units / QTY_SCALE;

/** บาท → จำนวนเต็มสตางค์ */
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

/** วันตามปฏิทิน UTC — ใช้เทียบ "ซื้อหลังวันที่ขาย" โดยไม่แพ้ความละเอียดของเวลาที่ต่างกัน */
const utcDay = (ms: number): number => Math.floor(ms / MS_PER_DAY);

function formatQty(units: number): string {
  return String(fromUnits(units));
}

/* ------------------------------------------------------------------ *
 * ตรวจโครงของล็อตทุกใบ
 *
 * `id` / `ownerId` / `assetId` ตรวจ **ทุกใบในสมุด** เพราะถ้าใบไหนไม่มีสามค่านี้
 * เราพิสูจน์ไม่ได้ว่ามันไม่ใช่ล็อตในขอบเขต — กรองไม่ได้แปลว่าอาจตัดของคนอื่น
 * ส่วนจำนวน/ต้นทุน/วันที่ ตรวจเฉพาะล็อตที่อยู่ในขอบเขตที่ตัดจริง
 * ข้อมูลเสียของผู้ถืออื่นจึงไม่ทำให้รายการที่ถูกต้องบันทึกไม่ได้
 * ------------------------------------------------------------------ */

type ScopedLot = {
  source: Lot;
  units: number;
  acquiredMs: number;
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
  if (!Array.isArray(lots)) fail("ไม่ได้ส่งรายการล็อตมา — คิดต้นทุน FIFO ไม่ได้");
  assertLotIdentity(lots as Lot[]);
  return lots as Lot[];
}

/** ล็อตในขอบเขต owner + asset เรียงตามลำดับ FIFO ที่ตรึงไว้แล้ว */
function scopeLots(lots: Lot[], ownerId: string, assetId: string): ScopedLot[] {
  const inScope = lots.filter((l) => l.ownerId === ownerId && l.assetId === assetId);

  const seen = new Set<string>();
  for (const l of inScope) {
    if (seen.has(l.id)) {
      fail(`ล็อต id ซ้ำในขอบเขตเดียวกัน: "${l.id}" — ลำดับ FIFO จะไม่แน่นอน`);
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
    return {
      source: l,
      units: toUnits(quantity, `ล็อต ${l.id}: quantity`),
      acquiredMs: parseTime(l.acquiredAt, `ล็อต ${l.id}: acquiredAt`),
    };
  });

  // FIFO: เก่าก่อน · เวลาเท่ากัน tie-break ด้วย id เรียงขึ้น (เทียบ code point ตรงๆ
  // ไม่ใช้ localeCompare เพราะผลของมันขึ้นกับ locale ของเครื่อง = ไม่ deterministic)
  return scoped.sort((a, b) => {
    if (a.acquiredMs !== b.acquiredMs) return a.acquiredMs - b.acquiredMs;
    if (a.source.id < b.source.id) return -1;
    if (a.source.id > b.source.id) return 1;
    return 0;
  });
}

/* ------------------------------------------------------------------ *
 * API
 * ------------------------------------------------------------------ */

/** จำนวนคงเหลือในขอบเขต owner + asset (ล็อตของผู้ถืออื่น/ทรัพย์อื่นไม่ถูกนับ) */
export function availableQuantity(lots: Lot[], ownerId: string, assetId: string): number {
  const safeLots = requireLots(lots);
  const owner = requireString(ownerId, "ownerId");
  const asset = requireString(assetId, "assetId");
  const scoped = scopeLots(safeLots, owner, asset);
  return fromUnits(scoped.reduce((sum, l) => sum + l.units, 0));
}

/**
 * ผลรวมต้นทุนที่ตัด — บวกบนจำนวนเต็มสตางค์
 *
 * มีไว้ให้ผู้เรียก (และเทสต์) ตรวจ invariant `Σ consumed[].cost === totalCost`
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

/**
 * ตัดต้นทุนแบบ FIFO
 *
 * ล็อตไม่พอ · ข้อมูลไม่ครบ · จำนวนหรือยอดเงินไม่ถูกต้อง → `PostingError`
 * **ไม่มีเส้นทางไหนที่คืนต้นทุน 0 แทนการปฏิเสธ** เพราะต้นทุนต่ำกว่าจริง
 * แปลว่ากำไรสูงกว่าจริง และผิดแบบนั้นจะไม่มีใครเห็น
 */
export function consumeFifo(lots: Lot[], input: SellInput): SellResult {
  const safeLots = requireLots(lots);
  if (input === null || typeof input !== "object") {
    fail("ไม่ได้ส่งข้อมูลการขายมา — คิดต้นทุน FIFO ไม่ได้");
  }

  const assetId = requireString(input.assetId, "assetId");
  const ownerId = requireString(input.ownerId, "ownerId");
  const quantity = requireNumber(input.quantity, "quantity");
  const proceeds = requireNumber(input.proceeds, "proceeds");
  const soldMs = parseTime(input.soldAt, "soldAt");

  if (quantity <= 0) fail(`จำนวนที่ขายต้องมากกว่า 0 (ได้ ${quantity})`);
  if (proceeds < 0) fail(`ยอดเงินที่ได้รับติดลบไม่ได้ (ได้ ${proceeds}) — ถ้ามีค่าใช้จ่ายให้หักก่อนส่งเข้ามา`);

  const wantUnits = toUnits(quantity, "จำนวนที่ขาย");
  const scoped = scopeLots(safeLots, ownerId, assetId);

  const availableUnits = scoped.reduce((sum, l) => sum + l.units, 0);
  if (availableUnits < wantUnits) {
    fail(
      `ล็อตคงเหลือไม่พอ: ต้องการ ${formatQty(wantUnits)} แต่มี ${formatQty(availableUnits)} ` +
        `(ผู้ถือ ${ownerId} · ทรัพย์ ${assetId}) — ต้องบันทึกล็อตที่ซื้อให้ครบก่อน ` +
        `ระบบจะไม่ตัดล็อตของผู้ถืออื่นและไม่สมมติต้นทุนให้`,
    );
  }

  // ซื้อหลังวันที่ขายไม่ได้ — เทียบเป็นวันตามปฏิทิน เพราะในสมุดมีทั้ง
  // acquiredAt ที่มีเวลาและไม่มีเวลา ถ้าเทียบถึงวินาทีจะปฏิเสธการซื้อ-ขายวันเดียวกันผิดๆ
  const soldDay = utcDay(soldMs);
  let consumedUnits = 0;
  const plan: { lot: ScopedLot; units: number }[] = [];
  for (const lot of scoped) {
    if (consumedUnits >= wantUnits) break;
    if (utcDay(lot.acquiredMs) > soldDay) {
      fail(
        `ล็อต ${lot.source.id} ซื้อวันที่ ${lot.source.acquiredAt} ซึ่งหลังวันที่ขาย ${input.soldAt} ` +
          `— ตัดต้นทุนจากล็อตที่ยังไม่ได้ซื้อไม่ได้`,
      );
    }
    const take = Math.min(lot.units, wantUnits - consumedUnits);
    plan.push({ lot, units: take });
    consumedUnits += take;
  }

  // เศษสตางค์: ปัดเฉพาะ "ยอดสะสม" แล้วเอาส่วนต่างเป็นต้นทุนของแต่ละล็อต
  // ผลรวมจึงเท่ากับยอดสะสมสุดท้ายโดยนิยาม (ดูหัวไฟล์ ข้อ 2)
  let exactCumSatang = 0;
  let roundedCumSatang = 0;
  const consumed: ConsumedLot[] = plan.map(({ lot, units }) => {
    // units/QTY_SCALE × unitCost × SATANG_SCALE  →  units × unitCost / 1e6
    exactCumSatang += (units * lot.source.unitCost) / (QTY_SCALE / SATANG_SCALE);
    if (!Number.isFinite(exactCumSatang) || Math.abs(exactCumSatang) > Number.MAX_SAFE_INTEGER) {
      fail(`ยอดต้นทุนรวมใหญ่เกินกว่าจะคิดได้แม่นยำ (ล็อต ${lot.source.id})`);
    }
    const nextRounded = Math.round(exactCumSatang);
    const sliceSatang = nextRounded - roundedCumSatang;
    roundedCumSatang = nextRounded;
    return { lotId: lot.source.id, quantity: fromUnits(units), cost: fromSatang(sliceSatang) };
  });

  const totalCostSatang = roundedCumSatang;
  const gainSatang = toSatang(proceeds, "ยอดเงินที่ได้รับ") - totalCostSatang;

  // ล็อตที่เหลือ: ลดจำนวนบนจำนวนเต็มหน่วย · `unitCost` และ `id` เดิมทุกตัว
  // (ล็อตใหม่ที่ต้นทุนเปลี่ยน = ถัวเฉลี่ยกลายๆ ซึ่งไม่ใช่ FIFO)
  const takenByLotId = new Map<string, number>();
  for (const { lot, units } of plan) takenByLotId.set(lot.source.id, units);

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

  return {
    consumed,
    totalCost: fromSatang(totalCostSatang),
    gain: fromSatang(gainSatang),
    outcome: gainSatang > 0 ? "gain" : gainSatang < 0 ? "loss" : "breakeven",
    remaining,
    remainingBook,
  };
}
