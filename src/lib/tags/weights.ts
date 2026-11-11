import type { Tag } from "@/components/tags/types";
import { BIG, MICRO, WEIGHT_SCALE, formatScaled, parseScaled } from "./decimal";

/**
 * ตรวจชุดน้ำหนักของ tag (ADR 0003 ข้อ 3.2 + 4.1) — **ตรรกะบริสุทธิ์ ไม่แตะ DB**
 *
 * กติกา (ตรงกับด่านที่ DB — ด่านนี้คือการบอกผู้ใช้ก่อน ไม่ใช่ตัวแทนของด่านนั้น):
 *   - Σ น้ำหนัก = 1.000000 **พอดี** · ไม่มี tolerance · ต่าง 0.000001 ก็ปฏิเสธ
 *   - 0 < น้ำหนัก <= 1 · น้ำหนัก 0 ไม่ได้ (ไม่เกี่ยวก็ไม่ต้องติด tag นั้น)
 *   - ทศนิยมเกิน 6 ตำแหน่ง → ปฏิเสธ (ไม่ปัดให้)
 *   - tag ที่ต้องถ่วงน้ำหนักแต่ **ไม่ส่งน้ำหนักมา** → ปฏิเสธ ไม่เดาเป็น 100% (บทเรียนข้อ 1-3)
 *   - น้ำหนักที่ไม่มี tag รองรับ → ปฏิเสธ (กันแถวกำพร้า)
 */

export type WeightIssueCode =
  | "no_tags"
  | "missing"
  | "not_number"
  | "too_precise"
  | "negative"
  | "zero"
  | "over_one"
  | "orphan"
  | "sum_short"
  | "sum_over";

export type WeightIssue = { code: WeightIssueCode; tagId?: string; message: string };

declare const checkedBrand: unique symbol;

/** ชุดน้ำหนักที่ผ่าน `checkWeights` แล้ว (Σ = 1 พอดี) — สร้างจากที่อื่นไม่ได้ ฟังก์ชันปันส่วนรับแต่ชนิดนี้ */
export type CheckedWeights = {
  readonly [checkedBrand]: true;
  readonly entries: readonly { readonly tagId: string; readonly micro: bigint }[];
};

export type WeightCheck =
  | { ok: true; weights: CheckedWeights }
  | {
      ok: false;
      issues: WeightIssue[];
      /** Σ ของแถวที่อ่านค่าได้ (หน่วยไมโคร) — null ถ้าไม่มีแถวใดอ่านได้ */
      sumMicro: bigint | null;
      /** MICRO - Σ · บวก = ขาด · ลบ = เกิน · null ถ้าบอกไม่ได้ (ยังมีแถวที่ผิด) */
      diffMicro: bigint | null;
    };

export type WeightTag = Pick<Tag, "id"> & { nameTh?: string };

/** หน่วยไมโคร → "60%" / "33.3333%" / "0.0001%" (ตัดศูนย์ท้าย · แม่นตรง ไม่ปัด) */
export function microToPercent(micro: bigint): string {
  const neg = micro < BIG.zero;
  const abs = neg ? -micro : micro;
  // 1 หน่วย = 0.0001% → เปอร์เซ็นต์ = abs / 10_000 ทศนิยม 4 ตำแหน่ง
  const text = formatScaled(abs, 4).replace(/\.?0+$/, "");
  return `${neg ? "-" : ""}${text === "" ? "0" : text}%`;
}

const nameOf = (t: WeightTag) => t.nameTh ?? t.id;

export function checkWeights(tags: readonly WeightTag[], weights: Record<string, unknown> | null | undefined): WeightCheck {
  const issues: WeightIssue[] = [];
  if (tags.length === 0) {
    return { ok: false, issues: [{ code: "no_tags", message: "ยังไม่ได้เลือก tag ที่ต้องแบ่งสัดส่วน" }], sumMicro: null, diffMicro: null };
  }
  const w = weights && typeof weights === "object" ? weights : {};

  const parsed: { tagId: string; micro: bigint }[] = [];
  let perTagBad = false;
  for (const t of tags) {
    const raw = w[t.id];
    if (raw === undefined || raw === null) {
      perTagBad = true;
      issues.push({ code: "missing", tagId: t.id, message: `tag "${nameOf(t)}" ยังไม่ได้ใส่สัดส่วน` });
      continue;
    }
    // ตัวเลขเท่านั้น — ข้อความ "0.6" ไม่รับ (ค่าที่ส่งต่อให้ DB ต้องเป็นสิ่งเดียวกับที่ตรวจ)
    const p = typeof raw === "number" ? parseScaled(raw, WEIGHT_SCALE) : ({ ok: false, reason: "not_number" } as const);
    if (!p.ok) {
      perTagBad = true;
      issues.push(
        p.reason === "too_precise"
          ? { code: "too_precise", tagId: t.id, message: `tag "${nameOf(t)}": สัดส่วนมีทศนิยมเกิน 6 ตำแหน่ง ระบบไม่ปัดให้` }
          : { code: "not_number", tagId: t.id, message: `tag "${nameOf(t)}": สัดส่วนต้องเป็นตัวเลข` }
      );
      continue;
    }
    if (p.units < BIG.zero) {
      perTagBad = true;
      issues.push({ code: "negative", tagId: t.id, message: `tag "${nameOf(t)}": สัดส่วนติดลบไม่ได้` });
    } else if (p.units === BIG.zero) {
      perTagBad = true;
      issues.push({
        code: "zero",
        tagId: t.id,
        message: `tag "${nameOf(t)}": สัดส่วน 0 ไม่ได้ — ถ้า tag นี้ไม่เกี่ยวกับรายการนี้ ให้เอา tag ออก`,
      });
    } else if (p.units > MICRO) {
      perTagBad = true;
      issues.push({ code: "over_one", tagId: t.id, message: `tag "${nameOf(t)}": สัดส่วนเกิน 100% ไม่ได้` });
    } else {
      parsed.push({ tagId: t.id, micro: p.units });
    }
  }

  // น้ำหนักที่ไม่มี tag รองรับ — ของใครก็ไม่รู้ ห้ามปล่อยผ่าน
  const known = new Set(tags.map((t) => t.id));
  for (const key of Object.keys(w)) {
    if (known.has(key) || w[key] === undefined) continue;
    issues.push({ code: "orphan", tagId: key, message: `มีสัดส่วนของ tag ที่ไม่ได้เลือกอยู่ในรายการนี้ (${key}) — ระบบไม่รับสัดส่วนที่ไม่มี tag รองรับ` });
  }

  const sum = parsed.length ? parsed.reduce((a, e) => a + e.micro, BIG.zero) : null;
  const diff = !perTagBad && sum !== null ? MICRO - sum : null;

  if (diff !== null && diff !== BIG.zero) {
    const list = tags.map((t) => `${nameOf(t)} ${microToPercent(parsed.find((e) => e.tagId === t.id)!.micro)}`).join(" · ");
    issues.push(
      diff > BIG.zero
        ? {
            code: "sum_short",
            message: `สัดส่วนรวม ${microToPercent(sum!)} ยังไม่ครบ 100% — ขาดอีก ${microToPercent(diff)} (${list}) · ต้องรวมได้ 100% พอดี`,
          }
        : {
            code: "sum_over",
            message: `สัดส่วนรวม ${microToPercent(sum!)} เกิน 100% — เกินอยู่ ${microToPercent(-diff)} (${list}) · ต้องรวมได้ 100% พอดี`,
          }
    );
  }

  if (issues.length > 0) return { ok: false, issues, sumMicro: sum, diffMicro: diff };
  return { ok: true, weights: { entries: parsed } as unknown as CheckedWeights };
}
