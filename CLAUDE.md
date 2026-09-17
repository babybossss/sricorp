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
ประเภทรายการ → หมวดย่อยที่อนุญาต → คู่บัญชี (dr/cr) → ผลกระทบต่องบ
```

- ผังบัญชีจริง 44 รหัสอยู่ที่ `src/lib/rules/coa.ts`
- ผลกระทบต่องบ **คำนวณจากคู่บัญชี** (`effectsOf`) ไม่พิมพ์มือ
- บัญชีของเคสพิเศษอยู่ในตารางกฎเช่นกัน: `gainCoa` · `lossCoa` · `interestCoa`
- ตาราง `sri_os.txn_types` ใน DB เป็นสำเนา — sync ด้วย `npm run sync:rules`

ห้ามมีคู่บัญชีกระจายอยู่ในหน้าจอหรือใน engine ถ้าต้องเพิ่มประเภทรายการ ใช้ `/new-txn-type`

## lib/ledger — ที่เดียวที่สร้างรายการเงิน

`src/lib/ledger/posting.ts` แปลงสิ่งที่ผู้ใช้กรอกเป็นบรรทัดบัญชีสองด้าน
หน้าจอ **ห้ามเขียน logic บัญชีเอง** ต้องเรียก `buildPosting()`

```ts
buildPosting(input) → { transactions: PostingTransaction[], summary: string[] }
```

- **หนึ่ง transaction = หนึ่งผู้ถือ** ตรงกับ schema (`transactions.owner_id`)
- โอนข้ามผู้ถือได้ **สอง transaction คู่กัน** ฝ่ายละหนึ่ง แต่ละอันสมดุลในตัวเอง
- ข้อมูลไม่ครบ → `PostingError` **ห้ามเดา** เพราะเดาผิดแปลว่าตัวเลขผิดเงียบๆ

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
| สุธี / สุดจิตต์ / ธนากร / ธนวินท์ / เบ็ญจพร | `personal_flexible` | override ได้ถ้าใส่เหตุผล แต่ **Money Invariants ห้ามละเมิด** |

ฝั่งบุคคลมี **5 คน** (ลูกพี่ยืนยัน 18/09) ส่วน ชลานุช · นิภาพร · สมาน · นุช ที่อยู่ใน Excel เป็น `contacts` ไม่ใช่ owner

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

**Supabase ขึ้นแล้ว** — project `sri-os` (ap-southeast-1, ref `oyigmbmxxlfhkrevsmxo`)
22 ตาราง · RLS ครบ · trigger บังคับ Money Invariants (ทดสอบแล้วว่ากันได้จริง) · seed ผังบัญชี + owners + txn_types

**หน้าจอยังใช้ mock** — `src/lib/mock/` และ `src/lib/store.ts`
`lib/ledger` พร้อมแล้วแต่ยังไม่ได้ผูกกับหน้าจอและยังไม่ได้เขียนลง DB
งานถัดไปคือต่อสามอย่างนี้เข้าด้วยกัน

## บทเรียนจากการตรวจของ mace-windu (อย่าพลาดซ้ำ)

1. **ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่ตกไปเส้นทางปกติ** — เคยทำให้ดอกเบี้ยถูกนับเป็นเงินต้น
2. **อย่าเชื่อฟิลด์ที่ผู้ใช้เว้นได้** — ผู้ถือปลายทางต้องอ่านจากบัญชีเอง
3. **เทสต์ที่ส่งข้อมูลครบเสมอ จะไม่มีวันแตะเส้นทางที่ข้อมูลขาด** — ต้องเขียนเคส "ไม่ส่ง" ด้วย
4. **1 transaction = 1 owner** รายการข้ามผู้ถือต้องแตกเป็นสองรายการ
