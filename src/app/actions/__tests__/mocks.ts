import { vi } from "vitest";
import { ctx } from "./ctx";

/** นำเข้าไฟล์นี้เป็นบรรทัดแรกของเทสต์ — vi.mock ถูกยกขึ้นบนสุดอัตโนมัติ */
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ctx.db.client }));
vi.mock("@/lib/auth/session", () => ({ getAccess: async () => ctx.access }));
vi.mock("@/lib/db/reference", () => ({ loadReference: async () => ctx.reference }));
