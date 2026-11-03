# สิทธิ์และกลไกร่างของโมดูลบริหารสินทรัพย์

ลูกพี่ตัดสิน 07/10 · ออกแบบปิด **D-083** (สิทธิ์โมดูลทรัพย์) ที่ค้างไว้
สถานะ: **เอกสารออกแบบ ยังไม่เขียนโค้ด** · อ่านคู่กับ `docs/DESIGN_ROLES.md` ·
`docs/DESIGN_ASSET_ERP_LINK.md` · `docs/LEDGER_RULES.md` §1

## ปัญหาวันนี้

5 ตาราง (`assets` · `bank_accounts` · `contracts` · `asset_valuations` · `schedules`)
มีแต่ policy `SELECT` · **ไม่มี policy เขียนเลย** → ไม่มีใครเพิ่มทรัพย์/บัญชีธนาคาร/สัญญาได้
แม้แต่ Management (พิสูจน์บน DB: insert → `violates row-level security policy`)
RLS ที่ไม่มี policy สำหรับคำสั่งใด = ปฏิเสธคำสั่งนั้น ไม่ใช่อนุญาต
`20261006190000` ตั้งใจไม่รื้อฝั่งเขียนของตารางพวกนี้ (ข้อ 11c) เพราะรอเอกสารนี้

---

## 1 · สรุปข้อตัดสินใจ

### 1.1 ตาราง × ตำแหน่ง × ทำอะไรได้

| ตาราง | Staff | Manager | Management | Super Admin |
|---|---|---|---|---|
| `asset_drafts` (**ใหม่**) | สร้างร่าง · แก้/ยกเลิกร่างของตัวเองที่ยัง `pending` · อ่านของตัวเอง | สร้างร่าง · **อนุมัติ/ปฏิเสธ** ร่างในขอบเขตตัวเอง | ทั้งหมด | ทั้งหมด |
| `assets` | **เขียนตรงไม่ได้เลย** · อ่านได้แค่สาขาอ้างอิง (ดู §5.3) | **UPDATE ได้เฉพาะทรัพย์ที่ตนบริหาร** · INSERT ตรงไม่ได้ (ต้องผ่านร่าง) | INSERT · UPDATE ทั้งหมด | เท่า Management |
| `asset_valuations` | ไม่แตะ · อ่านไม่ได้ | **อ่านได้เฉพาะทรัพย์ตน · เขียนไม่ได้** | INSERT (append-only) | เท่า Management |
| `contracts` | **ไม่แตะเลย** | INSERT/UPDATE เฉพาะสัญญาของทรัพย์ที่ตนบริหาร | ทั้งหมด | ทั้งหมด |
| `schedules` | **ไม่แตะเลย** | INSERT/UPDATE เฉพาะสัญญาในขอบเขต · สถานะที่สะท้อน ledger แก้มือไม่ได้ (§4.4) | เท่า Manager + ทั้งพอร์ต | เท่า Management |
| `bank_accounts` | **ไม่แตะเลย** | **ไม่แตะเลย** | INSERT/UPDATE (`settings.manage`) · ปิดบัญชี = `is_active=false` | เท่า Management |
| ทุกตารางข้างบน | DELETE: **ไม่มีใครได้** (ไม่มี policy `FOR DELETE` เลย) | | | |

### 1.2 สิทธิ์ใหม่ 3 ตัว (จาก 12 → 15)

| คีย์ | ความหมาย | SA | Mgmt | Manager | Staff |
|---|---|:--:|:--:|:--:|:--:|
| `asset.draft` | เสนอข้อมูลทะเบียนทรัพย์เป็นร่าง | ✓ | ✓ | ✓ | ✓ |
| `asset.manage` | เขียนทะเบียนทรัพย์/สัญญา + อนุมัติร่าง (**ขอบเขตจำกัดด้วย `fn_can_see_asset()`**) | ✓ | ✓ | ✓ | ✗ |
| `asset.value` | ตีราคา (`asset_valuations`) | ✓ | ✓ | ✗ | ✗ |

**ไม่เพิ่ม** คีย์สำหรับบัญชีธนาคาร (ใช้ `settings.manage` เดิม) และ
**ไม่เพิ่ม** คีย์มอบหมายผู้บริหารทรัพย์ (ใช้ `users.manage` เดิม — เหตุผล §3.2)

---

## 2 · กลไกร่าง — เลือกตารางร่างแยก

### 2.1 สองแนวทางที่เทียบ

| | A · คอลัมน์สถานะใน `assets` | B · ตารางร่างแยก `asset_drafts` |
|---|---|---|
| ร่างถูกนับในงบ/พอร์ตโดยไม่ได้ตั้งใจ | **ได้** ถ้าลืม `where record_status='active'` แค่ที่เดียว | **ไม่ได้ในทางโครงสร้าง** — แถวไม่อยู่ใน `assets` |
| FK ชี้มาที่ร่างได้ไหม | **ได้** · `transactions.asset_id` · `contracts.asset_id` · `asset_valuations.asset_id` ชี้ร่างได้ทันที | ไม่ได้ · FK ทั้งหมดชี้ `assets(id)` ซึ่งยังไม่มีแถว |
| `assets.code` unique | ร่างจองรหัสไว้ · ร่างที่ถูกปฏิเสธถือรหัสค้างตลอดไป | รหัสออกตอนอนุมัติ ไม่มีการจอง |
| คนทำงานต่อผิดได้ง่ายแค่ไหน | ลืม = **รั่วเงียบ** | ลืม = มองไม่เห็นข้อมูล (fail closed) |
| ความซ้ำซ้อนของคอลัมน์ | ไม่มี | **มี** — ต้องกันโครงสร้างสองที่ไม่เลื่อนจากกัน |

### 2.2 เลือก B · ตารางร่างแยก

เหตุผลที่ A แย่กว่าอย่างชัดเจน: A ทำให้ความถูกต้องของ "ร่างไม่ถูกนับ" ขึ้นอยู่กับ
**ความจำของคนเขียน query ทุกคนในอนาคต** ทุกที่ที่รวมมูลค่า — `v_asset_latest_value` ·
หน้า NAV · หน้ากระทบยอดทะเบียน vs บัญชีคุม · Data health · รายงานรายผู้ถือ
และโปรเจกต์นี้พลาดแบบ "ลืมกรองที่เดียว" มาแล้วหลายรอบซึ่งทุกรอบ**เงียบ**:
`lines_write` ที่เป็น `FOR ALL` ทำให้ Manager รวมยอดทั้งพอร์ตผ่าน `transaction_lines` ได้ ·
`asset_classes`/`asset_categories` ที่ไม่เคยเปิด RLS ·
`access_manage` ที่ค้างอยู่แล้ว OR ทับสิทธิ์ใหม่

B ย้ายการกันจาก "ต้องจำ" ไปเป็น "ทำไม่ได้": ร่างไม่ได้อยู่ในตาราง `assets`
ดังนั้นทุก query ที่มีอยู่แล้ว ทุกวิว ทุก join **ถูกต้องโดยไม่ต้องแก้อะไรเลย**
และ `asset_valuations` / `transactions` / `contracts` **ไม่สามารถ** อ้างถึงร่างได้
เพราะ FK ไม่มีแถวให้ชี้ — นี่คือสิ่งที่ A ให้ไม่ได้ไม่ว่าจะเขียน CHECK กี่ตัว

ข้อเสียของ B (โครงสร้างซ้ำสองที่) ยอมรับและกันด้วย:
- ร่างเก็บเฉพาะ **4 ช่องบังคับของ D-083** เป็นคอลัมน์จริง (ชื่อ · class · category · ผู้ถือ)
  ส่วนที่เหลือเก็บเป็น `patch jsonb` ช่องเดียว → เพิ่มคอลัมน์ใน `assets` ภายหลัง
  **ไม่ต้องแก้โครงสร้างตารางร่าง**
- คีย์ใน `patch` ต้องอยู่ใน whitelist (trigger) ที่อ้างชื่อคอลัมน์จริงของ `assets`
  → คีย์ที่ไม่มีคอลัมน์รองรับ **พังทันทีตอน insert ร่าง** ไม่ใช่เงียบตอนอนุมัติ
- มีเทสต์ที่อ่าน `information_schema.columns` ยืนยันว่า whitelist ⊆ คอลัมน์ของ `assets`

> นี่เป็นรูปแบบเดียวกับที่ฝั่ง ledger ใช้แล้ว (`draft_entries` แยกจาก `transactions`)
> โมดูลทรัพย์จึงไม่ได้คิดกลไกใหม่ แค่ใช้กลไกเดิมที่พิสูจน์แล้ว

### 2.3 Staff แก้ทรัพย์ที่อนุมัติแล้วยังไง — ร่างการแก้ ไม่ใช่ห้ามแก้

`asset_drafts.kind ∈ ('create','update')`

- `create` → `target_asset_id is null` · อนุมัติแล้ว **INSERT** แถวใหม่ใน `assets`
- `update` → `target_asset_id` ชี้ทรัพย์จริง · `patch` คือเฉพาะช่องที่เสนอแก้
  อนุมัติแล้ว **UPDATE** เฉพาะคีย์ใน `patch`

ทางเลือกที่ไม่เลือก: **ห้าม Staff แก้เลย** — แย่กว่าเพราะ D-083 ข้อ 3 ตั้งใจให้
ลงทะเบียนด้วย 4 ช่องก่อน แล้ว "ที่เหลือเติมทีหลังได้หมด" ถ้า Staff เติมทีหลังไม่ได้
ทะเบียนจะค้างที่ 4 ช่องตลอดกาล และคนที่มีเวลาเติมข้อมูล (Staff) คือคนที่ทำไม่ได้
= **เปิดฟีเจอร์ครึ่งเดียว** ซึ่งเคยเป็นบทเรียนข้อ 7 ของ mace-windu

### 2.4 โครงร่างตารางร่าง (ให้คนทำต่อ)

```
asset_draft_status enum ('pending','approved','rejected','cancelled')
   -- **ไม่ใช้ draft_status ของ ledger ซ้ำ** เพราะกฎเหล็กข้อ 4: ถอดโมดูลทรัพย์ทิ้ง
   -- ต้องไม่กระทบ core ledger · ใช้ type ร่วมกันคือผูกสองโมดูลเข้าหากันฟรีๆ

asset_drafts (
  id, kind, target_asset_id → assets(id),
  owner_id → owners(id) not null,          -- ชั้นขอบเขตแรก ใช้ fn_can_see_owner()
  name, class_id, category_id,             -- บังคับเมื่อ kind='create'
  patch jsonb not null default '{}',       -- ช่องที่เหลือ · whitelist ด้วย trigger
  note, status, reject_reason,
  applied_asset_id → assets(id),           -- ตั้งได้จาก fn_apply_asset_draft() เท่านั้น
  created_by not null default auth.uid(), reviewed_by, reviewed_at, created_at
)
CHECK (kind='create') = (target_asset_id is null)
CHECK kind='create' → name/class_id/category_id not null
```

การอนุมัติ = `fn_apply_asset_draft(p_draft uuid) returns uuid`
**`security invoker` ไม่ใช่ `security definer`** — ตั้งใจ เพราะ definer จะข้าม RLS
และกลายเป็นประตูหลังที่ให้ใครก็ได้เขียน `assets` ผ่านฟังก์ชัน
ทำเป็น invoker แปลว่า INSERT/UPDATE ที่ฟังก์ชันยิงยังต้องผ่าน policy ของ `assets`
→ **RLS ยังเป็นด่านเดียว** ไม่มีสองชุดกฎที่อาจไม่ตรงกัน

---

## 3 · "ทรัพย์ที่ตนบริหารจัดการ" ผูกกันด้วยอะไร

### 3.1 ของที่มีอยู่แล้ว — พอสำหรับ "แก้ได้เฉพาะที่ตนบริหาร"

```
assets.manager_user_id → app_users(id)        -- การผูกรายทรัพย์ มีอยู่แล้ว
user_owner_access(user_id, owner_id)          -- ขอบเขตตามผู้ถือ
fn_can_see_owner(owner)  = owner.view_all OR มีแถวใน user_owner_access
fn_can_see_asset(asset)  = portfolio.view_all OR (asset.view_assigned AND manager_user_id = auth.uid())
```

สองชั้นนี้ครบแล้ว **ไม่ต้องมีตารางมอบหมายรายทรัพย์เพิ่ม**: `manager_user_id`
คือการมอบหมายรายทรัพย์อยู่แล้ว · policy ฝั่งเขียนใช้สองฟังก์ชันเดิมได้ตรงๆ

```sql
-- UPDATE: USING = แถวเดิม · WITH CHECK = แถวใหม่ · ต้องผ่านทั้งคู่
-- ไม่งั้น Manager ย้ายทรัพย์ออกนอกขอบเขตตัวเองแล้วแก้ต่อได้ (หรือกลับกัน)
create policy assets_update on assets for update to authenticated
  using      (fn_can('asset.manage') and fn_can_see_owner(owner_id) and fn_can_see_asset(id))
  with check (fn_can('asset.manage') and fn_can_see_owner(owner_id) and fn_can_see_asset(id));
```

### 3.2 สองช่องที่ต้องกัน — ไม่งั้นขอบเขตนี้เลื่อนเองได้

1. **`manager_user_id` ต้องไม่ถูกเขียนโดยคนที่ขอบเขตผูกกับมัน**
   ถ้า Manager แก้ `manager_user_id` ของทรัพย์ตัวเองได้ เขาก็แจกสิทธิ์เห็นทรัพย์นั้น
   ให้ใครก็ได้ · ถ้า Staff ใส่ `manager_user_id = ตัวเอง` ลงใน `patch` ของร่าง
   แล้วมีคนกดอนุมัติแบบไม่อ่าน Staff จะได้สิทธิ์เห็นมูลค่าทรัพย์ชิ้นนั้น
   → การมอบหมายผู้บริหารทรัพย์ = **การแจกสิทธิ์มองเห็น** ธรรมชาติเดียวกับ
   `user_owner_access` ซึ่งเป็น `users.manage` อยู่แล้ว → ใช้คีย์เดิม ไม่เพิ่มคีย์ใหม่
   บังคับด้วย **trigger** ไม่ใช่ policy เพราะ RLS กรองคอลัมน์ไม่ได้ (D-089)
2. **`owner_id` ของทรัพย์ห้ามเปลี่ยนถ้ามีบรรทัดบัญชีผูกอยู่แล้ว**
   ย้ายผู้ถือ = ต้นทุนที่ลงไว้ในบัญชีคุมของผู้ถือเดิมจะไม่ตรงกับทะเบียนทันที
   (เส้นที่ 1 ของ `DESIGN_ASSET_ERP_LINK.md`) → trigger ปฏิเสธถ้ามี
   `transaction_lines` ที่ `asset_id` นี้ และ `settings.manage` เท่านั้นที่เปลี่ยนได้เมื่อยังไม่มี

### 3.3 ข้อจำกัดที่ยอมรับไว้ก่อน

`manager_user_id` เป็นคอลัมน์เดี่ยว = **ทรัพย์หนึ่งชิ้นมีผู้บริหารได้คนเดียว**
ลาพักร้อน/ดูแลร่วมทำไม่ได้ · ถ้าวันหนึ่งต้องทำ ให้เพิ่มตาราง `asset_managers`
แล้วแก้ `fn_can_see_asset()` ที่เดียว (policy ทุกตัวเรียกฟังก์ชันนี้ ไม่ได้อ่านคอลัมน์ตรงๆ)
→ **ค่าเปลี่ยนใจต่ำ** จึงไม่ทำตอนนี้ (คำถามข้อ Q1 §6)

---

## 4 · ทำไมแต่ละตารางได้สิทธิ์ไม่เท่ากัน

### 4.1 `assets` — ทะเบียน ไม่ใช่ตัวเลขเงิน → Staff ร่างได้
แก้ทะเบียนไม่ทำให้งบดุลขยับ (ยอดมาจาก `transaction_lines` เท่านั้น) ความเสียหายสูงสุด
คือข้อมูลประกอบผิด ซึ่งคนอนุมัติเห็นได้ก่อน → ปลอดภัยพอสำหรับร่างของ Staff

### 4.2 `asset_valuations` — เปลี่ยนตัวเลขที่ dashboard รวม → Staff ไม่แตะ
ราคาประเมินไม่เข้างบดุล (เส้นที่ 3) **แต่เข้า NAV และเป็นฐานการตัดสินใจ**
และมี `v_asset_latest_value` ที่ทุกหน้าดึงไปใช้ · ใส่ 0 หรือใส่ 100 ล้านเปลี่ยนภาพพอร์ตทันที
โดยไม่มี double-entry คอยจับ → แยกเป็นคีย์ `asset.value` ของ Management ขึ้นไป
**Manager ก็ไม่ได้** เพราะลูกพี่สั่งว่า Manager ไม่ดูภาพรวมการลงทุน การตีราคาคือ
การกำหนดภาพรวมนั้น · เป็น **append-only**: ไม่มี policy UPDATE/DELETE แก้ = ใส่แถวใหม่

### 4.3 `contracts` — ต้นน้ำของตัวเลขที่จะกลายเป็นรายการเงิน → Staff ไม่แตะ
`principal` · `rate` · `installments` ไหลไป `schedules` → cron สร้าง draft → รายการเงิน
พิมพ์ rate ผิดหนึ่งตัวแปลว่าได้ร่างที่ **ดูสมเหตุสมผล** ผิดทุกงวดไปอีกหลายปี
ร่างที่ดูถูกคือสิ่งที่คนอนุมัติจับไม่ได้ → ให้ `asset.manage` (Manager ขอบเขตตัวเอง) ขึ้นไป
(สัญญายังมี `status='draft'` ของตัวเองสำหรับงานเอกสาร คนละเรื่องกับสิทธิ์)

### 4.4 `schedules` — สะท้อนสถานะของ ledger → แก้สถานะมือไม่ได้
`status` ไป `drafted`/`approved`/`received` ได้เมื่อ `draft_entry_id`/รายการจริง
อยู่ในสถานะนั้นจริงเท่านั้น (trigger) · ถ้าแก้มือได้ ทะเบียนจะบอกว่า "รับเงินแล้ว"
ขณะที่ไม่มีใบยืนยันรับเงินและไม่มีบรรทัดบัญชี = ตัวเลขสองแหล่งขัดกันโดยไม่มีใครรู้
สถานะที่แก้มือได้คือ `upcoming` · `overdue` · `waived` (การยกเว้นงวดเป็นการตัดสินใจเชิงธุรกิจ)

### 4.5 `bank_accounts` — **ไม่ใช่ทรัพย์สิน** → `settings.manage` ไม่ใช่สิทธิ์โมดูลทรัพย์
บัญชีธนาคารคือสิ่งที่ ledger อ้างถึงทุกบรรทัดเงินสด ธรรมชาติเดียวกับผังบัญชีและ owners
จึงอยู่ใต้ `settings.manage` เดิม ไม่ควรไปปนกับ `asset.manage` ที่ Manager มี
- **ห้าม DELETE** ตลอดกาล (FK จาก `transaction_lines.bank_account_id` กันอยู่ชั้นหนึ่ง
  แต่บัญชีที่ยังไม่เคยมีรายการจะลบได้ถ้ามี policy → จึงไม่มี policy DELETE เลย)
- ปิดบัญชี = `is_active=false` เท่านั้น · ผูกกับ **D-092**: `BankInfo.isActive` +
  `buildPosting()` ปฏิเสธบัญชีที่ปิด **ยกเว้นรายการกลับรายการ**
  → ตารางนี้จึงเป็นที่มาของ "บัญชีไหนลงรายการได้" การให้ Manager ปิดบัญชีได้
  คือการให้ Manager หยุดการลงรายการของคนอื่นทั้งบ้าน
- เปลี่ยน `coa_id` ของบัญชีที่มีรายการแล้ว = ย้ายยอดเงินสดข้ามบัญชีในผังย้อนหลัง
  → trigger ห้าม (เหตุผลเดียวกับ §3.2 ข้อ 2)

---

## 5 · สิ่งที่ต้องกันไว้ล่วงหน้า

### 5.1 เพิ่ม/แก้/อนุมัติทรัพย์ ต้องไม่แตะ ledger — ยืนยัน
เส้นทางที่ออกแบบไว้เขียนแค่ `asset_drafts` และ `assets` · `fn_apply_asset_draft()`
ไม่ insert อะไรลง `transactions` · `transaction_lines` · `draft_entries` เลย
ตัวเลขในงบยังมาจากบรรทัดบัญชีที่เดียวเหมือนเดิม จึงไม่มีสองแหล่งให้ขัดกัน

**ผลข้างเคียงที่ต้องรู้และห้าม "แก้"**: ถ้าซื้อทรัพย์แล้วลงบัญชีไปแล้วแต่ร่างทะเบียน
ยังไม่อนุมัติ หน้ากระทบยอดทะเบียน vs บัญชีคุมจะแสดงผลต่าง — **นี่คือพฤติกรรมที่ถูก**
(ข้อ 1 ของเส้นที่ 1: "มีรายการลงบัญชีโดยไม่ผูกทรัพย์") ห้ามไปทำให้หน้านั้นนับร่างด้วย
เพื่อให้ผลต่างหาย เพราะจะได้ตัวเลขทะเบียนที่ไม่มีใครอนุมัติ

### 5.2 การอนุมัติทรัพย์ต้องไม่กลายเป็นช่องลง ledger (กฎเหล็กข้อ 6)
- ห้ามมี trigger บน `assets` / `asset_drafts` ที่เขียนลงตารางของ ledger
  **มีเทสต์อ่าน `pg_trigger` + `pg_proc` ยืนยัน** (รูปแบบเดียวกับเทสต์ที่ยืนยันว่า
  trigger กฎเงินไม่เรียก `fn_can()`)
- เส้นอัตโนมัติเดียวที่ยอมคือ `contracts → schedules → cron → draft_entries`
  ซึ่งคืน **ร่าง** และยังต้อง `ledger.approve` + `cash.confirm` ตามเดิม
- `asset.manage` · `asset.draft` · `asset.value` **ไม่ให้สิทธิ์ post อะไรเลย**
  คนที่มี `asset.manage` แต่ไม่มี `ledger.approve` ยัง insert `transactions` ไม่ได้

### 5.3 RLS กรองคอลัมน์ไม่ได้ (D-089) — จุดที่ต้องใช้วิว
`assets_by_owner` ปัจจุบันมีสาขาอ้างอิงให้คนที่ไม่มี `asset.view_assigned`
(= Staff) เห็นชื่อทรัพย์เพื่อคีย์ได้ → Staff เห็น **ทุกคอลัมน์** ของแถวนั้น
รวม `units` · `ticker` · `tags` · `manager_user_id`

แผน: วิว `v_asset_ref` (`security_invoker = true`) เปิดเฉพาะ
`id · code · name · class_id · category_id · owner_id · status`
แล้วย้ายสาขาอ้างอิงออกจาก policy ของ `assets` ไปอยู่ที่วิว
**ทำพร้อมตอนหน้าจอต่อ DB จริง** (D-089 บอกว่ารูปร่างวิวรู้ได้ตอนนั้น) และ
**ห้ามสร้างบัญชี Staff จนปิดข้อนี้** — ข้อนี้ยังมีผลอยู่

`asset_drafts` ไม่มีปัญหาเดียวกันเพราะ Staff เห็นเฉพาะร่างของตัวเอง

### 5.4 ห้าม `FOR ALL` — แยก insert/update/delete ทุกตัว
`FOR ALL` เอา `USING` ไปใช้กับ `SELECT` ด้วย ซึ่งเคยทำให้ Manager อ่าน
`transaction_lines` ได้ทั้งพอร์ตแล้ว `sum()` เอง (เทสต์ 9.2 จับได้)
ดีไซน์นี้จึงใช้ policy แยกคำสั่งทั้งหมด และ **ไม่มี policy DELETE บนทั้ง 5 ตาราง**
policy `SELECT` เดิม (`assets_by_owner` · `valuations_by_asset` · `schedules_by_contract` ·
`bank_accounts_by_owner` · `contracts_by_owner`) **ห้ามแตะ** — การเพิ่ม policy อ่านตัวใหม่
จะ OR ทับขอบเขตของ Manager · guard ใน `20261006190000` ข้อ 11c จะพังให้เห็นถ้ามีคนเพิ่ม
→ ต้องขยาย allow-list ของ guard นั้นให้ครอบ `contracts` · `schedules` · `bank_accounts` ด้วย

---

## 6 · ความเสี่ยงและคำถามที่ต้องให้ลูกพี่ตอบ

ความเสี่ยง
1. **Manager อนุมัติร่างของตัวเองได้** — ร่างทะเบียนไม่ใช่เงิน และการบังคับให้มีคนที่สอง
   ทุกครั้งจะทำให้ทะเบียนค้างคอขวดเหมือนที่ `DESIGN_ROLES.md` เตือนเรื่องยืนยันเงิน
   ยอมรับความเสี่ยงนี้ แต่ **ต้องบันทึก `reviewed_by` ทุกครั้ง** และหน้าคิวต้องแสดงชัดว่า
   ร่างนี้คนคีย์กับคนอนุมัติเป็นคนเดียวกัน
2. **`patch jsonb` คือจุดที่โครงสร้างอาจเลื่อนจากกัน** — กันด้วย whitelist trigger +
   เทสต์เทียบ `information_schema` แต่ถ้ามีคนเพิ่มคอลัมน์ใน `assets` แล้วไม่เพิ่มใน whitelist
   ช่องนั้นจะร่างไม่ได้ (**เงียบในแง่ฟีเจอร์ ไม่เงียบในแง่ตัวเลข** — ยอมรับได้)
3. **ร่างค้างคิวนานๆ** แปลว่าทะเบียนไม่ตรงความจริงและหน้ากระทบยอดจะมีผลต่างค้าง
   → ต้องมีตัวนับ "ร่างทรัพย์ค้างอนุมัติ" ใน Data health ไม่ใช่ซ่อนอยู่ในเมนู

คำถาม (ตอบได้ด้วยประโยคเดียว)
- **Q1** ทรัพย์หนึ่งชิ้นต้องมีผู้บริหารจัดการมากกว่าหนึ่งคนไหม (ลาพักร้อน/ดูแลร่วม)?
- **Q2** Manager ต้องตีราคาทรัพย์ที่ตนบริหารได้ไหม หรือให้ Management ตีให้ทั้งหมด?
- **Q3** Manager อนุมัติร่างทะเบียนของตัวเองได้ หรือต้องให้ Management อนุมัติเสมอ?
- **Q4** Staff ต้องสร้างสัญญา (`contracts`) เป็นร่างได้ไหม หรือห้ามแตะตามที่ออกแบบไว้?

ค่าตั้งต้นถ้าไม่ตอบ: Q1 = คนเดียว · Q2 = Management ตีให้ · Q3 = Manager อนุมัติเองได้ ·
Q4 = ห้ามแตะ · ทั้งสี่ข้อเปลี่ยนภายหลังด้วย migration แถวเดียวใน `role_permissions`
ยกเว้น Q1 ที่ต้องเพิ่มตาราง

---

## 7 · งานฝั่ง DB (รายการให้คนทำต่อ)

ทั้งหมดอยู่ใน migration ใหม่ **ห้ามแก้ไฟล์เก่าที่ apply แล้ว** (D-090)

1. `asset_draft_status` enum + ตาราง `asset_drafts` (§2.4) + index `(status, created_at)`
2. seed `permissions` 3 คีย์ + `role_permissions` ตาม §1.2
   (**ตาราง `roles`/`permissions`/`role_permissions` แก้ได้จาก migration เท่านั้น** —
   `20261007000003` ถอน write policy ไว้และมี guard ที่จะพังถ้ามีใครเพิ่มกลับมา)
   ชื่อคีย์ต้องผ่าน CHECK `permissions_no_money_bypass` — ทั้งสามตัวผ่าน
3. policy ฝั่งเขียน แยกคำสั่ง ไม่มี `FOR ALL` ไม่มี DELETE:
   `assets_insert` (`asset.manage` + `portfolio.view_all` + `fn_can_see_owner`) ·
   `assets_update` (§3.1) · `asset_drafts_read/insert/update_own/review` ·
   `valuations_insert` (`asset.value`) · `contracts_insert/update` ·
   `schedules_insert/update` · `bank_accounts_insert/update` (`settings.manage`)
4. RLS + policy อ่านของ `asset_drafts` (ตารางใหม่ที่ไม่มี policy = ปฏิเสธเงียบ ·
   guard "ทุกตารางต้องเปิด RLS และมี policy" ใน `20261007000006` จะพังถ้าลืม)
5. trigger
   - `trg_asset_assign_guard` — `manager_user_id` เปลี่ยนต้อง `users.manage` ·
     `owner_id` เปลี่ยนต้อง `settings.manage` และห้ามถ้ามี `transaction_lines` ผูกอยู่
   - `trg_asset_draft_patch_whitelist` — คีย์ใน `patch` ⊆ คอลัมน์ที่อนุญาต
     (**ไม่มี** `id` · `code` · `owner_id` · `manager_user_id` · `status` · `created_at`)
   - `trg_asset_draft_frozen` — ร่างที่ไม่ `pending` แก้ไม่ได้อีก · `applied_asset_id`
     ตั้งได้จาก `fn_apply_asset_draft()` เท่านั้น
   - `trg_schedule_status_mirror` — §4.4
   - `trg_bank_account_coa_immutable` — §4.5
   - audit trigger (`fn_audit`) บน `asset_drafts` · `assets` · `bank_accounts`
6. `fn_apply_asset_draft(uuid) returns uuid` · **security invoker** · ออก `assets.code`
   ตอนอนุมัติ (ไม่จองตอนร่าง) · ชน unique → error อ่านรู้เรื่อง ไม่ใช่ `23505` เปล่าๆ
7. ขยาย allow-list ของ guard 11c ให้ครอบ `contracts` · `schedules` · `bank_accounts`
8. แก้ unique `asset_valuations (asset_id, as_of, method)` — ตารางเป็น append-only
   แต่ constraint นี้ทำให้ **แก้ราคาประเมินของวันเดียวกันด้วยวิธีเดิมไม่ได้เลย**
   → เพิ่ม `revision int` เข้า unique แล้วให้ `v_asset_latest_value` เลือก revision สูงสุด
   (แยกเป็น migration คนละไฟล์ · ไม่เกี่ยวกับสิทธิ์ แต่ปิดไม่ได้ถ้าไม่แก้)

## 8 · งานฝั่งโค้ด

1. `src/lib/auth/permissions.ts` — เพิ่ม 3 คีย์ (เรียงตัวอักษร: `asset.draft` ·
   `asset.manage` · `asset.value`) → 15 ตัว · `npm run check:permissions -- --migrations`
   **พังทันทีถ้าไม่ตรงกับ migration** จึงต้องลงพร้อมกันหรือลง migration ก่อน
2. `src/lib/assets/draft-rules.ts` (ใหม่) — whitelist ช่องที่ร่างได้ **ฝั่ง TS**
   เป็นแหล่งความจริงเดียวของฟอร์ม + เทสต์ที่เทียบกับรายชื่อใน migration
   (กฎ "กฎเดียวกันห้ามเขียนสองที่" — ฟอร์มห้ามมีรายชื่อช่องของตัวเอง)
3. route guard — หน้า/action ของโมดูลทรัพย์ถาม `fn_can` ผ่าน helper เดิม
   **ปุ่มต้องถามสิทธิ์จริง ไม่ใช่ซ่อนเมนู** · การซ่อนเมนูเป็นเรื่อง UX ไม่ใช่การกั้น
4. หน้าจอ: ฟอร์มลงทะเบียนทรัพย์ 4 ช่อง · คิว "ร่างทรัพย์รออนุมัติ" (แสดงคนคีย์/คนอนุมัติ) ·
   แผง diff ของ `kind='update'` (ค่าเดิม → ค่าใหม่) · ตัวนับร่างค้างใน Data health
5. `src/lib/mock/` + `store.ts` — เพิ่มสถานะร่างในของจำลองให้ตรงกับ DB ก่อนต่อจริง

## 9 · เทสต์ที่ต้องมี

`supabase/tests/asset_permissions_test.sql` (รูปแบบเดียวกับ `roles_permissions_test.sql`
— transaction เดียว + rollback ปิดท้าย · login ด้วย `pg_temp.login()`)

**สิทธิ์**
1. Management insert `assets` → **สำเร็จ** (นี่คือบั๊กที่เอกสารนี้แก้ · ต้องมีเทสต์ยืนยัน)
2. Staff insert `assets` ตรง → ถูกปฏิเสธ · insert `asset_drafts` → สำเร็จ
3. Manager update ทรัพย์ที่ `manager_user_id = ตัวเอง` → สำเร็จ
4. Manager update ทรัพย์ของคนอื่น → ถูกปฏิเสธ · **และทรัพย์ที่ `manager_user_id is null` ก็ปฏิเสธ**
   ("ไม่มีใครดูแล" ไม่ใช่ "ของทุกคน")
5. Manager ตั้ง `manager_user_id` ของทรัพย์ตัวเองเป็นคนอื่น → trigger ปฏิเสธ
6. Staff ใส่ `manager_user_id` ใน `patch` → whitelist trigger ปฏิเสธตอน insert ร่าง
7. Manager / Staff insert `asset_valuations` → ปฏิเสธ · Management → สำเร็จ
8. Staff / Manager insert `bank_accounts` → ปฏิเสธ · Management → สำเร็จ
9. Staff insert `contracts` / `schedules` → ปฏิเสธ
10. DELETE ทั้ง 5 ตาราง ทุกตำแหน่ง รวม super_admin → ปฏิเสธทั้งหมด
11. ผู้ใช้ `is_active = false` และผู้ใช้ที่ไม่มีแถวใน `app_users` → ทำอะไรไม่ได้เลย

**ร่างไม่ถูกนับในมูลค่าพอร์ต (หัวใจของ §2)**
12. สร้างร่าง `create` 1 ตัว → `select count(*) from assets` **ไม่เปลี่ยน**
13. ร่างค้าง → `fn_asset_cost_basis` · `v_asset_latest_value` · ผลรวมมูลค่าพอร์ต
    ทุกตัว **ไม่เปลี่ยนค่า** (วัดก่อน/หลังในเทสต์เดียวกัน)
14. `insert into asset_valuations (asset_id) values (<draft_id>)` → **FK ปฏิเสธ**
    = พิสูจน์ว่าร่างถูกอ้างถึงไม่ได้ในทางโครงสร้าง ไม่ใช่เพราะมีใครจำกรอง
15. อนุมัติร่าง → `assets` +1 แถว **และ** `transactions`/`transaction_lines`/`draft_entries`
    +0 แถว (กฎเหล็กข้อ 6)
16. อ่าน `pg_trigger`/`pg_proc`: ไม่มี trigger บน `assets`/`asset_drafts` ที่แตะตาราง ledger

**ข้อมูลไม่ครบ / ทางที่ข้อมูลขาด** (บทเรียนข้อ 3 ของ mace-windu)
17. ร่าง `kind='create'` ที่ไม่ส่ง `class_id` → ปฏิเสธ (ไม่ใช่เติมค่าเริ่มต้นให้)
18. ร่าง `kind='update'` ที่ `target_asset_id is null` → ปฏิเสธ
19. ร่าง `kind='create'` ที่ `patch = '{}'` → **สำเร็จ** (D-083 ข้อ 3: 4 ช่องพอ)
20. อนุมัติร่างที่ `code` ชนของเดิม → error ที่อ่านรู้เรื่อง ไม่ใช่ข้อความ Postgres เปล่า
21. อนุมัติร่างที่ `status != 'pending'` ซ้ำสองครั้ง → ครั้งที่สองปฏิเสธ (ไม่สร้างทรัพย์ซ้ำ)
22. เปลี่ยน `owner_id` ของทรัพย์ที่มี `transaction_lines` ผูกอยู่ → ปฏิเสธ

**ฝั่ง TS** · `src/lib/auth/__tests__/permissions.test.ts` (ของเดิม ครบ 15 ตัว) ·
`src/lib/assets/__tests__/draft-rules.test.ts` (whitelist ตรงกับ migration ·
มีเคส "ส่งคีย์ที่ไม่อยู่ใน whitelist" และ "ส่ง patch ว่าง")

---

## 10 · แตกงาน — ไม่แตะไฟล์เดียวกัน

| # | ชิ้นงาน | agent | ไฟล์ที่แตะ |
|---|---|---|---|
| W1 | migration สิทธิ์ + `asset_drafts` + policy + trigger (§7 ข้อ 1–7) | `plo-koon` | `supabase/migrations/20261008000000_asset_permissions.sql` |
| W2 | migration `asset_valuations.revision` + วิวราคาล่าสุด (§7 ข้อ 8) | `plo-koon` | `supabase/migrations/20261008000001_valuation_revision.sql` |
| W3 | union type สิทธิ์ 15 ตัว | `obi-wan` | `src/lib/auth/permissions.ts` |
| W4 | whitelist ช่องที่ร่างได้ + เทสต์ | `obi-wan` | `src/lib/assets/draft-rules.ts` · `src/lib/assets/__tests__/draft-rules.test.ts` |
| W5 | เทสต์ RLS/trigger ทั้ง 22 เคส | `ki-adi-mundi` | `supabase/tests/asset_permissions_test.sql` |
| W6 | หน้าลงทะเบียนทรัพย์ 4 ช่อง + คิวร่าง + แผง diff | `luminara` | `src/app/(app)/assets/**` (ไฟล์ใหม่) |
| W7 | บันทึก D-093 (ตารางร่างแยก) · D-094 (สิทธิ์ 3 ตัว) | `kit-fisto` | `docs/DECISIONS.md` |

**ลำดับที่บังคับ**: W1 ก่อน W3 (`check:permissions` อ่าน migration แล้วพังถ้าไม่ตรง) ·
W1 ก่อน W5 · W1 ก่อน W4 (whitelist ต้องตรงกับ trigger) · W2 · W6 · W7 ขนานได้อิสระ
**W1 · W2 · W5 ต้องผ่าน `mace-windu` ก่อน merge** (แตะ `supabase/migrations` และ RLS)

ADR ของข้อตัดสินใจที่ย้อนกลับยาก: `docs/adr/0001-asset-draft-table.md`
