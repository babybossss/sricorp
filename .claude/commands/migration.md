---
description: สร้าง migration ใหม่ของ Supabase พร้อม invariant test และตรวจโดย mace-windu
---

สร้าง migration: $ARGUMENTS

1. อ่าน `docs/DATA_MODEL.md` และ `docs/LEDGER_RULES.md`
2. สร้างไฟล์ `supabase/migrations/<YYYYMMDDHHMMSS>_<slug>.sql`
   - หัวไฟล์เขียน comment: ทำอะไร / ย้อนกลับยังไง
   - เขียนให้ idempotent (`if not exists` / `create or replace`)
3. ถ้าเป็นตารางการเงิน ต้องมีครบ
   - `owner_id` + FK
   - RLS enabled + policy
   - trigger `audit_log`
   - ห้าม DELETE (trigger กัน)
4. เขียน test ของ invariant ที่เกี่ยวข้อง
5. **ห้าม apply ขึ้น Supabase จริงโดยไม่ได้รับอนุญาตจากลูกพี่** — ค่าเริ่มต้นคือเตรียมไฟล์ไว้เฉยๆ
6. เรียก `mace-windu` ตรวจ
