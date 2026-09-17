# SRI OS — คู่มือสำหรับ Claude Code

ระบบ ERP / Company OS ของ Family Office ไทย (SRI Corporation)
ทุกอย่างเป็น **กองกลางของ SRI Family** ทรัพย์บางตัวแค่อยู่ในชื่อบุคคล

รายละเอียดเต็มอยู่ใน `docs/` — ไฟล์นี้สั้นโดยตั้งใจ

## กฎเหล็ก 6 ข้อ (ห้ามละเมิดทุกกรณี)

1. **ห้าม DELETE รายการที่ post แล้ว** — แก้ด้วย reverse + ลงใหม่ บังคับที่ DB trigger
2. **Double-entry บังคับที่ DB** — Σ debit = Σ credit ต่อ transaction
3. **ทุกแถวมี `owner_id`** และรายงานทุกหน้ากรอง Entity ได้
4. **โมดูลแยกโฟลเดอร์** เพิ่ม/ถอดได้โดยไม่แตะ core ledger
5. **ทุกอย่างที่ตั้งค่าได้อยู่ในตาราง config** ห้าม hard-code
6. **Automation ไม่เคย post เอง** สร้างได้แค่ draft

## ตารางกฎประเภทรายการ

`src/lib/rules/tx-rules.ts` คือแหล่งความจริงเดียวของ

```
ประเภทรายการ → หมวดย่อยที่อนุญาต → ผลกระทบต่องบ (P&L / งบดุล / CF)
```

ห้ามมีคู่บัญชีกระจายอยู่ในหน้าจอ ถ้าต้องเพิ่มประเภทรายการ ใช้ `/new-txn-type`

ข้อผิดที่เจอบ่อยและต้องกันไว้เสมอ
- เงินกู้เข้าบัญชี **ไม่ใช่รายได้** → Financing
- เงินต้นที่คืน **ไม่ใช่ค่าใช้จ่าย** → ลดหนี้สิน
- เงินปันผลจ่าย **ไม่ใช่ค่าใช้จ่าย** → ลดส่วนของเจ้าของ
- ปล่อยกู้/ขายฝาก **เป็น Investing** ไม่ใช่ Financing
- โอนระหว่างบัญชีตัวเอง **ไม่เข้า P&L**

## Entity Policy

| owner | policy | ผลที่โค้ดต้องบังคับ |
|---|---|---|
| SRI Corporation / Holding / Capital | `corporate_strict` | ต้องมี contact + ไฟล์หลักฐาน + หมวดจากผังที่อนุมัติ · ห้าม override |
| ธนากร / ธนวินท์ / เบ็ญจพร | `personal_flexible` | override ได้ถ้าใส่เหตุผล แต่ **Money Invariants ห้ามละเมิด** |

Money Invariants เต็มอยู่ใน `docs/LEDGER_RULES.md`

## UI ที่ห้ามลดมาตรฐาน (ผู้ใช้มีผู้สูงอายุ)

- ตัวอักษรเล็กสุด 16px ตัวปกติ 18px · มีโหมดตัวใหญ่ +2px
- ปุ่มสูง ≥ 52px (มือถือ 56px) และ**มีข้อความกำกับเสมอ** ห้ามปุ่มไอคอนเดี่ยว
- วงแหวนโฟกัส 3px · ตัวเลข tabular · ติดลบใช้วงเล็บ
- สีจากโทเคนใน `tailwind.config.ts` เท่านั้น

## คำสั่งที่ใช้บ่อย

```bash
npm run dev        # http://localhost:3000
npm run build
npm run typecheck
npm run lint
```

## วิธีทำงาน (สภาเจได)

| งาน | เรียก agent |
|---|---|
| ออกแบบ feature ใหม่ / แตกงาน | `yoda` |
| migration, lib/ledger, ตารางกฎ | `plo-koon` |
| หน้าจอ, server actions, ฟอร์ม | `obi-wan` |
| component, responsive, accessibility | `luminara` |
| Edge Function, cron, CI/CD, env | `shaak-ti` |
| รัน test แล้วรายงาน | `ki-adi-mundi` |
| CHANGELOG, สรุปรายวัน | `kit-fisto` |
| **ตรวจ diff ที่แตะเงิน (บังคับ)** | `mace-windu` |

กติกา
1. งานใหญ่เริ่มด้วย Plan Mode
2. แตกงานเป็นชิ้นที่ไม่แตะไฟล์เดียวกัน แล้วรันขนานใน worktree
3. Test-first สำหรับทุกอย่างที่แตะเงิน
4. Subagent ตอบกลับ **สรุป ≤ 200 คำ** + ไฟล์ที่แก้ ห้ามส่งเนื้อไฟล์เต็มกลับ
5. ห้ามโหลด Excel/CSV ใหญ่เข้า context — เขียนสคริปต์อ่านแล้วสรุป
6. ค้นโค้ดใช้ `Explore` agent
7. **ทุก diff ที่แตะ `lib/ledger`, `supabase/migrations`, `src/lib/rules`, RLS ต้องผ่าน `mace-windu` ก่อน merge**

## สถานะตอนนี้

UI + mock data ยังไม่ต่อ Supabase — ข้อมูลอยู่ใน `src/lib/mock/` และ state อยู่ใน `src/lib/store.ts`
จุดที่ต้องเปลี่ยนตอนต่อฐานข้อมูลจริงคือสองที่นี้ ส่วน `src/lib/rules/tx-rules.ts` อยู่ในโค้ดต่อไป
