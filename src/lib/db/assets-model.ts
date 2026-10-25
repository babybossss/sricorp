/**
 * ทะเบียนทรัพย์ — ชนิดข้อมูลและฟังก์ชันล้วน (ไม่แตะ DB · ใช้ได้ทั้ง server และ client)
 *
 * ไฟล์นี้ **ไม่มีกฎบัญชี**:
 *   - ต้นทุนของทรัพย์แต่ละชิ้นมาจาก `sri_os.fn_asset_cost_basis()` ของ DB (นิยามต้นทุนอยู่ที่นั่นที่เดียว)
 *     ไฟล์นี้รับตัวเลขนั้นมาตรงๆ ไม่คำนวณสำเนาที่สอง
 *   - ส่วนที่คำนวณเองคือ "การรวมบรรทัดสมุดต่อทรัพย์" (ค่าปรับปรุง · ค่าซ่อม · รายได้) โดยจัดประเภทบัญชีจาก
 *     `coa()` และตารางกฎ (`findSub`) เท่านั้น
 *
 * **กฎต้นทุนรายชิ้น (ลูกพี่สั่ง 25/10)**: "แยกทรัพย์สินแม้จะอยู่คอนโดเดียวกัน แต่คนละห้องก็แยก
 * จะไม่นำต้นทุนมาคำนวณหรือเฉลี่ยเด็ดขาด"
 *   - ทุกฟังก์ชันที่จัดกลุ่ม (`groupAssets`) คืนกลุ่มที่มี **แค่ชื่อกลุ่ม + รายชื่อทรัพย์** — ไม่มีช่องตัวเลขเลย
 *     ต้นทุนของแต่ละชิ้นยังอยู่ที่ชิ้นนั้น ไม่ถูกรวมหรือหารต่อกลุ่ม
 *   - ไม่มีฟังก์ชัน "ต้นทุนต่อหน่วยเฉลี่ย" ในไฟล์นี้ ไม่ว่าอสังหาฯ หรือหลักทรัพย์ — การถัวเฉลี่ยของหุ้น/ทอง/คริปโต
 *     เป็นงานของทะเบียนล็อต (`asset_lots` · `average-cost.ts`) ไม่ใช่หน้าทะเบียนนี้
 *   - ผลรวมที่คืนมีเฉพาะ "ผลบวกของยอดรายชิ้น" (`sumReports`) เพื่อกระทบกับงบ · ไม่มีการหารด้วยจำนวนชิ้น
 */

import { ASSET_CLASSES } from "@/lib/rules/asset-classes";
import { coa, type CoaType } from "@/lib/rules/coa";
import { TX_TYPES, findSub } from "@/lib/rules/tx-rules";

/* ------------------------------------------------------------------ *
 * ข้อมูลทะเบียน
 * ------------------------------------------------------------------ */

/** แถวของ `sri_os.fn_assets_visible()` — ช่องที่ผู้ดูไม่มีสิทธิ์เห็นจะเป็น null (ไม่ใช่ error) */
export type AssetVisibleRow = {
  id: string;
  code: string;
  name: string;
  class_id: string;
  category_id: string;
  owner_id: string;
  holding_nature: string | null;
  beneficiary_id: string | null;
  status: string;
  acquired_date: string | null;
  disposed_date: string | null;
  location: string | null;
  ticker: string | null;
  units: number | string | null;
  currency: string;
  manager_user_id: string | null;
  tags: string[] | null;
  created_at: string;
  ownership_pct: number | string | null;
  funding_source: string | null;
  property_type: string | null;
  size_note: string | null;
};

export type AssetRow = {
  id: string;
  code: string;
  name: string;
  classId: string;
  categoryId: string;
  ownerId: string;
  holdingNature: string | null;
  status: string;
  acquiredDate: string | null;
  disposedDate: string | null;
  location: string | null;
  ticker: string | null;
  currency: string;
  tags: string[];
  ownershipPct: number | null;
  fundingSource: string | null;
  propertyType: string | null;
  sizeNote: string | null;
  createdAt: string;
};

export function toAssetRow(r: AssetVisibleRow): AssetRow {
  return {
    id: r.id,
    code: r.code,
    name: r.name,
    classId: r.class_id,
    categoryId: r.category_id,
    ownerId: r.owner_id,
    holdingNature: r.holding_nature,
    status: r.status,
    acquiredDate: r.acquired_date,
    disposedDate: r.disposed_date,
    location: r.location,
    ticker: r.ticker,
    currency: r.currency,
    tags: r.tags ?? [],
    ownershipPct: r.ownership_pct === null || r.ownership_pct === undefined ? null : Number(r.ownership_pct),
    fundingSource: r.funding_source,
    propertyType: r.property_type,
    sizeNote: r.size_note,
    createdAt: r.created_at,
  };
}

export type ClassRow = { id: string; code: string; nameTh: string; sortOrder: number };
export type CategoryRow = { id: string; classId: string; code: string; nameTh: string; isActive: boolean; sortOrder: number };
export type Taxonomy = { classes: ClassRow[]; categories: CategoryRow[] };

/** ทรัพย์พร้อมชื่อหมวด (join แล้ว) — หาหมวดไม่เจอแสดงเป็น "ไม่ทราบหมวด" ไม่เดา */
export type AssetView = AssetRow & {
  classCode: string;
  className: string;
  categoryCode: string;
  categoryName: string;
};

export const UNKNOWN_CLASS = "ไม่ทราบหมวด";

export function toAssetView(row: AssetRow, tax: Taxonomy): AssetView {
  const cls = tax.classes.find((c) => c.id === row.classId);
  const cat = tax.categories.find((c) => c.id === row.categoryId);
  return {
    ...row,
    classCode: cls?.code ?? "",
    className: cls?.nameTh ?? UNKNOWN_CLASS,
    categoryCode: cat?.code ?? "",
    categoryName: cat?.nameTh ?? UNKNOWN_CLASS,
  };
}

export const STATUS_LABEL: Record<string, string> = {
  active: "ใช้งานอยู่",
  inactive: "หยุดไว้",
  sold: "ขายแล้ว",
  redeemed: "ไถ่ถอนแล้ว",
};
export const statusLabel = (s: string) => STATUS_LABEL[s] ?? s;
/** ขายแล้ว/ไถ่ถอนแล้ว = ปิดรายการ ไม่อยู่ในพอร์ตที่ถืออยู่ */
export const isClosedStatus = (s: string) => s === "sold" || s === "redeemed";

export const HOLDING_NATURE_LABEL: Record<string, string> = {
  beneficial: "ถือเอง",
  nominee: "ถือแทน (ชื่อหลังโฉนดไม่ใช่ผู้ถือตามบัญชี)",
};

/* ------------------------------------------------------------------ *
 * ไอคอนประจำทรัพย์ — แสดงผลอย่างเดียว ไม่มีผลกับตัวเลข
 * ------------------------------------------------------------------ */

export type AssetIconKind = "condo" | "house" | "townhome" | "land" | "commercial" | "warehouse" | "other";

const ICON_KEYWORDS: [string, AssetIconKind][] = [
  ["คอนโด", "condo"],
  ["ทาวน์", "townhome"],
  ["บ้าน", "house"],
  ["ที่ดิน", "land"],
  ["อาคารพาณิชย์", "commercial"],
  ["ตึกแถว", "commercial"],
  ["โกดัง", "warehouse"],
  ["คลังสินค้า", "warehouse"],
];

/** เดาจากข้อความชนิดทรัพย์ที่คนกรอก — จับคู่ไม่ได้ = ไอคอนกลาง (ใช้แสดงผลเท่านั้น ไม่เข้าการคำนวณใดๆ) */
export function iconKindFor(a: Pick<AssetRow, "propertyType" | "name">): AssetIconKind {
  const text = `${a.propertyType ?? ""} ${a.name}`;
  for (const [kw, kind] of ICON_KEYWORDS) if (text.includes(kw)) return kind;
  return "other";
}

/* ------------------------------------------------------------------ *
 * ตัวกรอง (กฎเหล็กข้อ 3: ทุกหน้ากรองตามผู้ถือได้ และมีมุมมองรวม)
 * ------------------------------------------------------------------ */

export const FAMILY_OWNER = "family";

export type AssetFilter = {
  /** `family` = มุมมองรวมทุกผู้ถือ · นอกนั้นคือ owner id */
  owner: string;
  status: "all" | "active" | "inactive" | "closed";
  /** รหัสหมวดใหญ่ หรือ `all` */
  classCode: string;
  tag: string;
  q: string;
};

export const DEFAULT_FILTER: AssetFilter = { owner: FAMILY_OWNER, status: "all", classCode: "all", tag: "", q: "" };

const norm = (s: string) => s.normalize("NFC").trim().toLowerCase();

export function filterAssets<T extends AssetView>(assets: readonly T[], f: AssetFilter): T[] {
  const q = norm(f.q);
  const tag = norm(f.tag);
  return assets.filter((a) => {
    if (f.owner !== FAMILY_OWNER && a.ownerId !== f.owner) return false;
    if (f.status === "active" && a.status !== "active") return false;
    if (f.status === "inactive" && a.status !== "inactive") return false;
    if (f.status === "closed" && !isClosedStatus(a.status)) return false;
    if (f.classCode !== "all" && a.classCode !== f.classCode) return false;
    if (tag && !a.tags.some((t) => norm(t) === tag)) return false;
    if (q) {
      const hay = norm([a.name, a.code, a.location ?? "", a.propertyType ?? "", a.ticker ?? "", ...a.tags].join(" "));
      if (!hay.includes(q)) return false;
    }
    return true;
  });
}

/** ป้ายทั้งหมดที่ใช้อยู่ในทะเบียน (ไม่ซ้ำ เรียง ก–ฮ) — ไว้ทำตัวเลือกกรอง */
export function allTags(assets: readonly Pick<AssetRow, "tags">[]): string[] {
  const seen = new Map<string, string>();
  for (const a of assets) for (const t of a.tags) if (!seen.has(norm(t))) seen.set(norm(t), t.trim());
  return [...seen.values()].sort((x, y) => x.localeCompare(y, "th"));
}

/** อ่านพารามิเตอร์ owner จาก URL — ไม่รู้จัก = มุมมองรวม (ไม่เดาว่าเป็นผู้ถือคนอื่น) */
export function ownerParam(raw: string | undefined, knownOwnerIds: readonly string[]): string {
  return raw && knownOwnerIds.includes(raw) ? raw : FAMILY_OWNER;
}

/* ------------------------------------------------------------------ *
 * การจัดกลุ่มเพื่อ "ดู" — กลุ่มไม่มีตัวเลขใดๆ (ดูหัวไฟล์)
 * ------------------------------------------------------------------ */

export type GroupBy = "none" | "class" | "category" | "owner" | "location";

export const GROUP_BY_LABEL: Record<GroupBy, string> = {
  none: "ไม่จัดกลุ่ม",
  class: "หมวดใหญ่",
  category: "หมวดย่อย",
  owner: "ผู้ถือ",
  location: "ที่ตั้งเดียวกัน (เช่น ตึกเดียวกัน)",
};

/** กลุ่มมี **แค่ชื่อกับรายชื่อทรัพย์** — ห้ามเพิ่มช่องตัวเลข (ต้นทุน/ต้นทุนเฉลี่ย) ต่อกลุ่ม · เทสต์ล็อกรูปร่างนี้ไว้ */
export type AssetGroup<T> = { key: string; title: string; assets: T[] };

const NO_LOCATION = "ยังไม่ระบุที่ตั้ง";

export function groupAssets<T extends AssetView>(
  assets: readonly T[],
  by: GroupBy,
  ownerName: (ownerId: string) => string = (id) => id
): AssetGroup<T>[] {
  if (by === "none") return [{ key: "all", title: "ทรัพย์ทั้งหมด", assets: [...assets] }];
  const groups = new Map<string, AssetGroup<T>>();
  for (const a of assets) {
    let key: string;
    let title: string;
    if (by === "class") {
      key = a.classId;
      title = a.className;
    } else if (by === "category") {
      key = a.categoryId;
      title = `${a.className} › ${a.categoryName}`;
    } else if (by === "owner") {
      key = a.ownerId;
      title = ownerName(a.ownerId);
    } else {
      const loc = (a.location ?? "").replace(/\s+/g, " ").trim();
      key = loc ? norm(loc) : "__none";
      title = loc || NO_LOCATION;
    }
    const g = groups.get(key) ?? { key, title, assets: [] };
    g.assets.push(a);
    groups.set(key, g);
  }
  return [...groups.values()].sort((x, y) => x.title.localeCompare(y.title, "th"));
}

/* ------------------------------------------------------------------ *
 * รายงานรายทรัพย์ (D-112) — คำนวณจากสมุดทุกครั้ง ไม่เก็บยอด (D-113)
 * ------------------------------------------------------------------ */

/** บรรทัดจาก `v_ledger_posted` ที่ผูกกับทรัพย์ (ที่หัวรายการหรือที่บรรทัด) */
export type AssetLedgerLine = {
  lineId: string;
  txnId: string;
  ownerId: string;
  subCode: string;
  docDate: string;
  source: string;
  coaCode: string;
  debit: number;
  credit: number;
  lineAssetId: string | null;
  txnAssetId: string | null;
};

/** แถวดิบของ `v_ledger_posted` ที่หน้าทรัพย์อ่าน — ระบุคอลัมน์ตรงๆ ไม่ใช้ `*` */
export type AssetLedgerViewRow = {
  line_id: string;
  transaction_id: string;
  owner_id: string;
  txn_type_code: string;
  doc_date: string;
  source: string;
  coa_id: string;
  debit: number | string;
  credit: number | string;
  line_asset_id: string | null;
  txn_asset_id: string | null;
};

export const UNKNOWN_ACCOUNT = "????";

export function toAssetLedgerLines(rows: AssetLedgerViewRow[], coaCodeById: Record<string, string>): AssetLedgerLine[] {
  return rows.map((r) => ({
    lineId: r.line_id,
    txnId: r.transaction_id,
    ownerId: r.owner_id,
    subCode: r.txn_type_code,
    docDate: r.doc_date,
    source: r.source,
    coaCode: coaCodeById[r.coa_id] ?? UNKNOWN_ACCOUNT,
    debit: Number(r.debit),
    credit: Number(r.credit),
    lineAssetId: r.line_asset_id,
    txnAssetId: r.txn_asset_id,
  }));
}

/**
 * หมวดย่อยที่เป็น "ค่าปรับปรุงที่บันทึกเป็นทุน" และ "ค่าซ่อม" — รหัสบัญชีอ่านจากตารางกฎ (`findSub(...).dr`)
 * ไม่พิมพ์รหัสบัญชีซ้ำที่นี่ · ตารางกฎยังไม่มีฟิลด์บอก "บทบาทต่อรายงานรายทรัพย์" จึงต้องอ้างหมวดย่อยสองตัวนี้
 * (ข้อจำกัดที่รายงานให้ลูกพี่ — เทสต์ล็อกว่าสองหมวดนี้ยังชี้ไปบัญชีสินทรัพย์/ค่าใช้จ่ายตามที่คาด)
 */
export const ASSET_REPORT_SUBS = { renovation: "inv.capex", repair: "exp.repair" } as const;

export type ReportAccounts = {
  renovation: string;
  repair: string;
  /** บัญชีกำไรจากการขายทุกบัญชีที่ตารางกฎประกาศ */
  gains: ReadonlySet<string>;
  /** บัญชีขาดทุนจากการขายทุกบัญชีที่ตารางกฎประกาศ */
  losses: ReadonlySet<string>;
};

export function reportAccounts(): ReportAccounts {
  const reno = findSub(ASSET_REPORT_SUBS.renovation)?.sub.dr;
  const rep = findSub(ASSET_REPORT_SUBS.repair)?.sub.dr;
  if (!reno || !rep) throw new Error("ตารางกฎไม่มีหมวดย่อยค่ารีโนเวท/ค่าซ่อม — รายงานรายทรัพย์ประกอบไม่ได้");
  if (coa(reno).type !== "asset") throw new Error(`บัญชีค่ารีโนเวท ${reno} ไม่ใช่สินทรัพย์ — ตารางกฎเปลี่ยน ต้องทบทวนรายงานรายทรัพย์`);
  if (coa(rep).type !== "expense") throw new Error(`บัญชีค่าซ่อม ${rep} ไม่ใช่ค่าใช้จ่าย — ตารางกฎเปลี่ยน ต้องทบทวนรายงานรายทรัพย์`);
  const gains = new Set<string>();
  const losses = new Set<string>();
  for (const t of TX_TYPES)
    for (const s of t.subs) {
      if (s.gainCoa) gains.add(s.gainCoa);
      if (s.lossCoa) losses.add(s.lossCoa);
    }
  return { renovation: reno, repair: rep, gains, losses };
}

export type AssetReport = {
  assetId: string;
  /** ต้นทุนรวมตาม `fn_asset_cost_basis()` (ซื้อ + ปรับปรุง) — มาจาก DB */
  costTotal: number;
  /** ค่าปรับปรุงที่บันทึกเป็นทุนสะสม (บัญชีค่ารีโนเวทของตารางกฎ) */
  renovation: number;
  /** ต้นทุนซื้อ = ต้นทุนรวม − ค่าปรับปรุง */
  purchase: number;
  /** ค่าซ่อมสะสม (ค่าใช้จ่าย · ไม่เพิ่มต้นทุน) */
  repair: number;
  /** ค่าใช้จ่ายอื่นสะสมของทรัพย์ (ไม่รวมค่าซ่อม และไม่รวมขาดทุนจากการขาย) */
  otherExpense: number;
  /** รายได้สะสม (ไม่รวมกำไรจากการขาย) */
  income: number;
  /** กำไร(ขาดทุน)จากการขายทรัพย์ชิ้นนี้ — แยกจากรายได้จากการถือ */
  saleResult: number;
  /** จำนวนบรรทัดสมุดที่ผูกกับทรัพย์ชิ้นนี้ */
  lineCount: number;
};

export type ReportBuild = {
  reports: Record<string, AssetReport>;
  /** บรรทัดที่รหัสบัญชีไม่อยู่ในผัง — ไม่ถูกนับเงียบๆ หน้าจอต้องเตือน */
  unclassifiedLines: number;
};

const sat = (n: number) => Math.round(n * 100);
const baht = (s: number) => Math.round(s) / 100;

const typeOf = (code: string): CoaType | null => {
  try {
    return coa(code).type;
  } catch {
    return null;
  }
};

/** ทรัพย์ที่บรรทัดนี้นับให้ — บัญชีสินทรัพย์ผูกที่บรรทัด · รายได้/ค่าใช้จ่ายผูกที่หัวรายการ (บรรทัดไม่มี asset_id) */
export function lineAssetKey(l: AssetLedgerLine, type: CoaType): string | null {
  if (type === "asset") return l.lineAssetId;
  if (type === "income" || type === "expense") return l.lineAssetId ?? l.txnAssetId;
  return null;
}

/**
 * รวมบรรทัดสมุดเป็นรายงานต่อทรัพย์ · `costs` = ต้นทุนรวมจาก DB ต่อทรัพย์
 * ทรัพย์ที่ไม่มีใน `costs` ไม่ได้รับรายงาน (ไม่เดาเป็น 0)
 */
export function buildAssetReports(costs: Readonly<Record<string, number>>, lines: readonly AssetLedgerLine[]): ReportBuild {
  const acc = reportAccounts();
  type Sum = { reno: number; repair: number; other: number; income: number; gain: number; loss: number; n: number };
  const sums = new Map<string, Sum>();
  let unclassified = 0;
  for (const l of lines) {
    const type = typeOf(l.coaCode);
    if (type === null) {
      unclassified++;
      continue;
    }
    const key = lineAssetKey(l, type);
    if (!key || !(key in costs)) continue;
    const s = sums.get(key) ?? { reno: 0, repair: 0, other: 0, income: 0, gain: 0, loss: 0, n: 0 };
    s.n++;
    const net = sat(l.debit) - sat(l.credit);
    if (type === "asset") {
      if (l.coaCode === acc.renovation) s.reno += net;
    } else if (type === "expense") {
      if (acc.losses.has(l.coaCode)) s.loss += net;
      else if (l.coaCode === acc.repair) s.repair += net;
      else s.other += net;
    } else if (type === "income") {
      if (acc.gains.has(l.coaCode)) s.gain -= net;
      else s.income -= net;
    }
    sums.set(key, s);
  }
  const reports: Record<string, AssetReport> = {};
  for (const [assetId, total] of Object.entries(costs)) {
    const s = sums.get(assetId) ?? { reno: 0, repair: 0, other: 0, income: 0, gain: 0, loss: 0, n: 0 };
    const costS = sat(total);
    reports[assetId] = {
      assetId,
      costTotal: baht(costS),
      renovation: baht(s.reno),
      purchase: baht(costS - s.reno),
      repair: baht(s.repair),
      otherExpense: baht(s.other),
      income: baht(s.income),
      saleResult: baht(s.gain - s.loss),
      lineCount: s.n,
    };
  }
  return { reports, unclassifiedLines: unclassified };
}

export type ReportTotals = { count: number; purchase: number; renovation: number; costTotal: number; repair: number; income: number };

/** ผลบวกของยอดรายชิ้น (ไม่ใช่ค่าเฉลี่ย · ไม่หารด้วยจำนวนชิ้น) — ไว้กระทบกับงบ */
export function sumReports(assets: readonly Pick<AssetRow, "id">[], reports: Readonly<Record<string, AssetReport>>): ReportTotals {
  let purchase = 0, renovation = 0, costTotal = 0, repair = 0, income = 0, count = 0;
  for (const a of assets) {
    const r = reports[a.id];
    if (!r) continue;
    count++;
    purchase += sat(r.purchase);
    renovation += sat(r.renovation);
    costTotal += sat(r.costTotal);
    repair += sat(r.repair);
    income += sat(r.income);
  }
  return { count, purchase: baht(purchase), renovation: baht(renovation), costTotal: baht(costTotal), repair: baht(repair), income: baht(income) };
}

/** บรรทัดสมุดที่นับให้ทรัพย์หนึ่งชิ้น — ไว้โชว์ในหน้ารายละเอียด (ชุดเดียวกับที่รายงานนับ) */
export function linesOfAsset(assetId: string, lines: readonly AssetLedgerLine[]): AssetLedgerLine[] {
  return lines.filter((l) => {
    const t = typeOf(l.coaCode);
    return t !== null && lineAssetKey(l, t) === assetId;
  });
}

/* ------------------------------------------------------------------ *
 * มูลค่าปัจจุบัน — ตัวเลขประเมิน **ไม่ใช่ตัวเลขทางบัญชี ไม่เข้างบดุล** (D-112)
 * ------------------------------------------------------------------ */

export type LatestValue = {
  assetId: string;
  /** null = ยังไม่เคยตีราคา (ไม่ใช่ 0) หรือผู้ดูไม่มีสิทธิ์เห็น */
  value: number | null;
  asOf: string | null;
  method: string | null;
  isStale: boolean;
};

export const VALUE_NOT_ACCOUNTING =
  "มูลค่าปัจจุบันเป็นราคาประเมินเพื่อดูประกอบเท่านั้น ไม่ใช่ตัวเลขทางบัญชี และไม่เข้างบแสดงฐานะการเงิน (งบดุลใช้ต้นทุนตามสมุด)";

export const METHOD_LABEL: Record<string, string> = {
  market_api: "ราคาตลาด (ดึงอัตโนมัติ)",
  appraisal: "ผู้ประเมินอิสระ",
  treasury: "ราคาประเมินทางราชการ",
  manual: "ประเมินเอง",
  cost: "ใช้ต้นทุน",
};
export const methodLabel = (m: string | null) => (m ? (METHOD_LABEL[m] ?? m) : "—");

export const VALUATION_METHODS = ["manual", "appraisal", "treasury"] as const;
export type ValuationMethod = (typeof VALUATION_METHODS)[number];

export type ValuationRow = {
  id: string;
  assetId: string;
  asOf: string;
  method: string;
  value: number | null;
  note: string | null;
  revision: number | null;
  createdAt: string;
};

/* ------------------------------------------------------------------ *
 * ร่าง (asset_drafts)
 * ------------------------------------------------------------------ */

export type DraftKind = "create" | "update";
export type DraftStatus = "pending" | "approved" | "rejected" | "cancelled";
export type DraftPatchValue = string | number | string[] | null;
/** key ที่ไม่มีใน patch = ไม่แตะ · key ที่เป็น `null` = ลบค่าออก (สองอย่างนี้ห้ามปนกัน) */
export type DraftPatch = Record<string, DraftPatchValue>;
export type DraftActor = { id: string; name: string };

export type DraftView = {
  id: string;
  kind: DraftKind;
  targetAssetId: string | null;
  ownerId: string;
  name: string | null;
  classId: string | null;
  categoryId: string | null;
  patch: DraftPatch;
  note: string | null;
  status: DraftStatus;
  rejectReason: string | null;
  appliedAssetId: string | null;
  createdBy: DraftActor;
  createdAt: string;
  reviewedBy: DraftActor | null;
  reviewedAt: string | null;
};

export type DraftDbRow = {
  id: string;
  kind: DraftKind;
  target_asset_id: string | null;
  owner_id: string;
  name: string | null;
  class_id: string | null;
  category_id: string | null;
  patch: DraftPatch | null;
  note: string | null;
  status: DraftStatus;
  reject_reason: string | null;
  applied_asset_id: string | null;
  created_by: string;
  reviewed_by: string | null;
  reviewed_at: string | null;
  created_at: string;
};

export function toDraftView(r: DraftDbRow, nameOf: (userId: string) => string): DraftView {
  return {
    id: r.id,
    kind: r.kind,
    targetAssetId: r.target_asset_id,
    ownerId: r.owner_id,
    name: r.name,
    classId: r.class_id,
    categoryId: r.category_id,
    patch: r.patch && typeof r.patch === "object" && !Array.isArray(r.patch) ? r.patch : {},
    note: r.note,
    status: r.status,
    rejectReason: r.reject_reason,
    appliedAssetId: r.applied_asset_id,
    createdBy: { id: r.created_by, name: nameOf(r.created_by) },
    createdAt: r.created_at,
    reviewedBy: r.reviewed_by ? { id: r.reviewed_by, name: nameOf(r.reviewed_by) } : null,
    reviewedAt: r.reviewed_at,
  };
}

/** ชื่อหมวดจากตารางกฎในโค้ด — ใช้เฉพาะตอนตรวจว่า DB กับโค้ดเห็นตรงกัน (เทสต์) */
export const RULE_CLASS_CODES: readonly string[] = ASSET_CLASSES.map((c) => c.code);
