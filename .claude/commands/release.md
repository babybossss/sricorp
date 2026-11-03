---
description: ตรวจให้ครบก่อนปล่อยรุ่น แล้วเขียน CHANGELOG
---

เตรียม release: $ARGUMENTS

1. เรียก `ki-adi-mundi` รัน typecheck / lint / test / build รายงานผล
2. ถ้ามี diff ที่แตะ `lib/ledger`, `supabase/migrations`, `src/lib/rules` หรือ RLS → เรียก `mace-windu` ตรวจ
3. ตรวจ UI 3 ขนาดจอ (1440 / 1024 / 390) ด้วย `luminara`
4. ถ้าทุกอย่างผ่าน ให้ `kit-fisto` เขียน CHANGELOG และสรุปรายวัน
5. สรุปให้ลูกพี่อ่าน: ใช้งานได้เพิ่มอะไร / แก้อะไร / ยังค้างอะไร
6. **ห้าม deploy production เอง** รอลูกพี่กดอนุมัติ
