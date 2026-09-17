---
description: เพิ่มประเภทรายการหรือหมวดย่อยใหม่เข้าตารางกฎ พร้อม test และตรวจโดย mace-windu
---

เพิ่มประเภทรายการ/หมวดย่อยใหม่: $ARGUMENTS

ทำตามลำดับนี้ ห้ามข้าม

1. อ่าน `src/lib/rules/tx-rules.ts` และ `docs/LEDGER_RULES.md`
2. ถามตัวเองให้ชัดก่อนเขียน แล้วเขียนคำตอบลงใน comment ของหมวดย่อยนั้น
   - เงินเข้าหรือออก
   - กระทบ P&L ไหม ถ้ากระทบ บรรทัดไหน
   - กระทบงบดุลด้านไหน เพิ่มหรือลด
   - อยู่ในกระแสเงินสดหมวดไหน (operating / investing / financing)
   - ต้องบังคับกรอกอะไรเพิ่ม (contact / asset / loanTerms / capitalGain / principalInterestSplit)
3. เพิ่มเข้า `TX_TYPES` ใต้ประเภทที่ถูกต้อง พร้อม `plain` ที่อธิบายเป็นภาษาคน และ `caution` ถ้าเป็นหมวดที่ลงผิดง่าย
4. เขียน test ใน `src/lib/rules/__tests__/` ยืนยันว่า
   - หมวดใหม่เลือกได้จากประเภทที่ถูก และ**เลือกไม่ได้**จากประเภทอื่น
   - `impactLines()` ให้ผลตรงกับที่ตั้งใจ
5. รัน `npm run typecheck` และ test
6. **เรียก `mace-windu` ตรวจ diff** ถ้า BLOCK ให้แก้แล้วตรวจซ้ำ ห้าม merge ทั้งที่ยัง BLOCK
