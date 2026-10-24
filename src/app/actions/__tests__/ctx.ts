import { vi } from "vitest";
import type { ReferenceState } from "@/lib/db/reference-types";
import { createFakeDb, okReference, type FakeDb } from "./fake-db";

/**
 * สถานะที่ mock ของ server action ใช้ร่วมกัน — ตั้งใหม่ทุกเทสต์ด้วย `resetCtx()`
 * (ค่าที่ค้างข้ามเทสต์คือทางที่เทสต์สองตัวรบกวนกันเงียบๆ)
 */
export type AccessMock = {
  user: { id: string; email: string | null } | null;
  permissions: Set<string>;
  profile: null;
  error: string | null;
};

export const ctx = {
  db: createFakeDb() as FakeDb,
  reference: okReference() as ReferenceState,
  access: { user: { id: "u1", email: "u@x" }, permissions: new Set(["ledger.approve", "txn.create"]), profile: null, error: null } as AccessMock,
};

export function resetCtx() {
  ctx.db = createFakeDb();
  ctx.reference = okReference();
  ctx.access = { user: { id: "u1", email: "u@x" }, permissions: new Set(["ledger.approve", "txn.create"]), profile: null, error: null };
}

export const revalidatePath = vi.fn();
