/** คลาส Tailwind ของ pill / badge ตาม Style Guide — ที่เดียวจบ ไม่กระจาย hex */

export const STATUS_PILL: Record<string, string> = {
  wait: "bg-warn-bg text-warn-fg border-warn",
  saved: "bg-brand-50 text-brand-600 border-brand-100",
  done: "bg-pos-bg text-pos-fg border-pos",
  late: "bg-surface text-neg border-neg",
  off: "bg-canvas text-ink-400 border-line",
};

export const TYPE_PILL: Record<string, string> = {
  inc: "bg-pos-bg text-pos-fg border-pos-bd",
  exp: "bg-neg-bg text-neg-fg border-neg-bd",
  inv: "bg-brand-50 text-brand-600 border-brand-100",
  fin: "bg-info-bg text-info-fg border-info-bd",
  trf: "bg-canvas text-ink-600 border-line",
};

export const PRIORITY_PILL: Record<string, string> = {
  P1: "bg-neg-bg text-neg-fg",
  P2: "bg-warn-bg text-warn-fg",
  P3: "bg-brand-50 text-brand-600",
};
