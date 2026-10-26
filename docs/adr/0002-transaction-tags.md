# ADR 0002 · ติด tag / project ให้รายการ และกรองย้อนหลัง

วันที่ 26/10/2026 · สถานะ **เสนอ (รอ mace-windu + ลูกพี่)**
คำสั่งต้นเรื่อง (ลูกพี่ 26/10): "ในทุก transaction อย่าลืมสร้าง function ที่สามารถ tag
project หรือ label, คู่ transaction ว่ารับ/จ่ายใคร ไว้ด้วย สามารถ Filter มาดูทุก
Transaction เวลาตรวจย้อนหลัง"
เกี่ยวข้อง: กฎเหล็กข้อ 1 · 3 · 5 · Money Invariants (`docs/LEDGER_RULES.md` หัวข้อ 1) ·
D-098 (`v_ledger_posted`) · D-089 (column exposure) · ADR 0001 (แพทเทิร์นตารางแยก)

---

## 1. บริบท — ช่องว่างจริงคืออะไร

"คู่ transaction ว่ารับ/จ่ายใคร" **มีอยู่แล้ว** และ ADR นี้ไม่แตะ:

| สิ่งที่ลูกพี่ขอ | ของที่มีแล้ว |
|---|---|
| รับ/จ่ายใคร | `transactions.contact_id` (+ `txn_types.requires_contact` บังคับในหมวดที่ต้องมี) |
| คู่ผู้ถือในกองกลาง | `counter_owner_id` + `intercompany_nature` |
| ผูกทรัพย์ / สัญญา / เลขเอกสาร | `asset_id` · `contract_id` · `doc_no` · `memo` · `source_ref` |
| **project / tag / label** | **ไม่มีเลย** ← ช่องว่างเดียวของเรื่องนี้ |

`docs/PLAN.md` หัวข้อ 4.1 เคยเขียน `transactions.project_id` ไว้ในคอลัมน์ของ
`transactions` **ADR นี้ทับบรรทัดนั้น** — ไม่เพิ่มคอลัมน์ `project_id` เหตุผลอยู่หัวข้อ 3

---

## 2. การตัดสิน (สรุปสิบบรรทัด)

1. tag เป็น **แค็ตตาล็อกที่ตั้งไว้ก่อนแล้วเลือก** ไม่มีการพิมพ์อิสระจากฟอร์มรายการ
2. สามตารางใหม่: `tag_kinds` (config) · `tags` (แค็ตตาล็อก) · `transaction_tags` (ลิงก์)
   — **ไม่มีคอลัมน์ใหม่ใน `transactions` / `transaction_lines` เลย**
3. **หนึ่งใบติดได้หลาย tag รวม tag ชนิด `project` ด้วย** (ลูกพี่ยืนยัน 26/10)
4. ผลตามมาที่ยอมรับอย่างเปิดเผย: รายงานต่อ tag เป็น **"ยอดที่แตะ tag นี้" (touch)
   ไม่ใช่ "ส่วนแบ่งของ tag นี้" (allocation)** → **ห้ามบวกข้าม tag ทุกที่** กันสี่ชั้น (หัวข้อ 4)
5. ลิงก์เป็น **append-only + ปิดด้วยร่องรอย** (`untagged_at/by/untag_reason`) ไม่มี DELETE
6. แค็ตตาล็อกเป็น **ของกองกลาง** (ไม่มี `owner_id` เหมือน `chart_of_accounts`) แต่
   **แถวลิงก์ทุกแถวมี `owner_id`** ที่คัดลอกจากใบและ trigger บังคับให้ตรง (กฎเหล็กข้อ 3)
7. ประตู `fn_post_entry(jsonb)` รับช่องใหม่ **`tag_ids` (array ของ uuid) อย่างเดียว**
   ไม่มีจำนวน ไม่มีสัดส่วน · ติด tag ให้ **ทุกใบในคำขอนั้น** (ทั้งสองขาของรายการข้ามผู้ถือ)
8. `buildPosting()` / `posting.ts` / `tx-rules.ts` / `coa.ts` **ไม่แก้แม้บรรทัดเดียว**
9. อ่านผ่าน `v_ledger_posted` เท่านั้น → ใบที่ยกเลิกไม่ถูกนับโดยโครงสร้าง
10. `tag.assign` / `tag.catalog` เป็น permission key ใหม่ใน `role_permissions` (ไม่ hard-code role)

---

## 3. Schema

### 3.1 `sri_os.tag_kinds` — config ของ "ชนิด tag" (กฎเหล็กข้อ 5)

| คอลัมน์ | ชนิด | หมายเหตุ |
|---|---|---|
| `key` | text PK | seed: `project` · `label` |
| `name_th` · `name_en` | text not null | ป้ายในหน้าจอ อ่านจากที่นี่ **ห้ามพิมพ์ในหน้าจอ** |
| `allows_multi` | boolean not null | **seed = true ทั้งสองชนิด** (คำสั่ง 26/10) |
| `aggregate_note_th` | text not null | ประโยคที่ทุกตารางต่อ tag **ต้อง**แสดง (หัวข้อ 4 ชั้น 3) |
| `sort_order` · `is_active` | | |

เป็น **ตาราง ไม่ใช่ enum** เพราะ (ก) กฎเหล็กข้อ 5 (ข) ถ้าวันหนึ่งลูกพี่เปลี่ยนใจให้
`project` ติดได้อันเดียว มันคือการแก้ค่าคอนฟิก + migration backfill ไม่ใช่การรื้อ schema
(กลไกพร้อมแล้ว — ดูหัวข้อ 4 ทางเลือก B)

### 3.2 `sri_os.tags` — แค็ตตาล็อก

| คอลัมน์ | ชนิด | หมายเหตุ |
|---|---|---|
| `id` | uuid PK | |
| `kind` | text not null → `tag_kinds(key)` | `project` / `label` |
| `code` | text not null **unique** (lower, `^[a-z0-9][a-z0-9._-]{1,48}$`) | รหัสคงที่ ใช้ใน URL/filter |
| `name_th` | text not null, btrim <> '' | ชื่อที่คนอ่าน |
| `name_en` · `description` | text | |
| `color_token` | text → `settings` ของโทเคนสี | **เก็บชื่อโทเคน ไม่เก็บ hex** (กติกา UI) |
| `is_active` | boolean not null default true | ปิดได้ · **ห้ามลบ** |
| `archived_at` · `archived_by` | timestamptz · uuid → `app_users` | เงื่อนไขสองทางกับ `is_active` |
| `created_at` · `created_by` · `updated_at` | | `created_by` ทับด้วย `auth.uid()` เมื่ออยู่ใต้ RLS |

**ไม่มี** `owner_id` · **ไม่มี** `parent_id` (ไม่ทำ tag ซ้อนชั้นในรอบนี้) ·
**ไม่มี** `merged_into_id` (ไม่ทำ merge ในรอบนี้ — ยอมรับความเสี่ยงไว้ที่หัวข้อ 8)

### 3.3 `sri_os.transaction_tags` — ลิงก์ (หัวใจ)

| คอลัมน์ | ชนิด | หมายเหตุ |
|---|---|---|
| `id` | uuid PK | surrogate เพราะต้องรองรับ "ถอดแล้วติดใหม่" โดยเก็บของเก่าไว้ |
| `transaction_id` | uuid not null → `transactions(id)` **on delete restrict** | ไม่ cascade: ลบใบแล้วให้ร่องรอยหายไปด้วยไม่ได้ |
| `tag_id` | uuid not null → `tags(id)` **on delete restrict** | tag ที่ถูกใช้แล้วลบไม่ออก |
| `owner_id` | uuid not null → `owners(id)` | **สำเนาจากใบ** · trigger บังคับ `= transactions.owner_id` · แก้ไม่ได้ |
| `tag_kind` | text not null → `tag_kinds(key)` | สำเนาจาก `tags.kind` · trigger บังคับให้ตรง |
| `single_per_txn` | boolean not null | สำเนาของ `not tag_kinds.allows_multi` · trigger บังคับ · วันนี้ = false ทุกแถว |
| `tagged_at` · `tagged_by` | timestamptz not null · uuid not null → `app_users` | trigger ตั้งจาก `auth.uid()` ปลอมไม่ได้ (แพทเทิร์น `fn_txn_system_columns`) |
| `tag_note` | text | เหตุผลตอนติด (ไม่บังคับ) |
| `untagged_at` · `untagged_by` · `untag_reason` | timestamptz · uuid → `app_users` · text | **เงื่อนไขสองทาง** เหมือน D-098 |

**ห้ามมีคอลัมน์ที่เป็นจำนวนเงินหรือสัดส่วนเด็ดขาด** — guard ท้ายไฟล์ไล่
`information_schema.columns` แล้ว **พัง** ถ้ามีคอลัมน์ชนิด `numeric/money/double/real`
ในตารางนี้ (หัวข้อ 5 ข้อ 4)

**Index / constraint**

```
unique index tag_link_active_uq   on transaction_tags (transaction_id, tag_id)
                                  where untagged_at is null;        -- ติด tag เดิมซ้ำบนใบเดียวไม่ได้
unique index tag_link_single_uq   on transaction_tags (transaction_id, tag_kind)
                                  where untagged_at is null and single_per_txn;  -- คานของทางเลือก B
index tag_link_by_tag             on transaction_tags (tag_id, owner_id) where untagged_at is null;
index tag_link_by_owner           on transaction_tags (owner_id, tag_id) where untagged_at is null;
index tag_link_by_txn             on transaction_tags (transaction_id)   where untagged_at is null;
check  tag_link_close_both_ways:  (untagged_at is not null) = (untagged_by is not null)
                              and (untagged_at is not null) = (untag_reason is not null
                                                               and btrim(untag_reason) <> '')
check  untagged_at >= tagged_at
```

`tag_link_single_uq` ตอบคำถาม "บังคับด้วยอะไร": **partial unique index ที่ predicate
อ่านจากคอนฟิก** ไม่ใช่จากชื่อชนิดที่พิมพ์ไว้ในโค้ด · วันนี้ `single_per_txn = false`
ทุกแถว → index มีอยู่แต่ไม่กันอะไร (ตรงตามคำสั่ง "ติดได้หลายอัน") · ถ้าวันหนึ่งพลิก
คอนฟิก migration ต้อง backfill คอลัมน์นี้ใหม่ทั้งตารางและ index จะ **พังทันที**
ถ้ามีใบที่ติด project เกินหนึ่งอันอยู่ — นั่นคือพฤติกรรมที่ถูก (ต้องตัดสินใจว่าจะเอาอันไหน
ไม่ใช่ให้ระบบเลือกเงียบๆ)

### 3.4 `sri_os.draft_entry_tags` — ร่างก็ต้องถือ tag ไว้

`(draft_entry_id → draft_entries(id) on delete cascade, tag_id → tags(id) restrict,
primary key (draft_entry_id, tag_id))`
cascade ที่ร่างได้ เพราะร่างลบได้อยู่แล้ว (ไม่ใช่สมุด) · ตอนอนุมัติ ร่างส่ง tag เข้า
`fn_post_entry(tag_ids)` → **tag ที่ติดไว้ตอนร่างต้องไม่หายตอนอนุมัติ** (เทสต์บังคับ)

---

## 4. การนับซ้ำ — เรื่องที่อันตรายที่สุดของ ADR นี้

### 4.1 ปัญหา (เขียนให้ตรงที่สุด)

ใบขายทรัพย์ 10,000,000 ที่ติดทั้ง `project:iris-235` และ `project:renovate-2026`
จะถูกนับ **เต็มจำนวนในทั้งสอง project** → ถ้าหน้าไหนเอายอดของทุก project มาบวกกัน
จะได้ 20,000,000 ขณะที่เงินจริงมี 10,000,000 · **งบดุลยังดุลสนิท** และ
`fn_health_check` ก็ยังผ่าน เพราะไม่มีตัวเลขในสมุดผิดเลย — ผิดเฉพาะ "วิธีรวม"
นี่คือรูปแบบเดียวกับที่ลูกพี่สั่งห้ามไว้ว่า "อย่าให้มีการคำนวณผิด กำไรที่ไม่จริงออกมา"

### 4.2 ทางที่เลือก: **A — ยอมรับว่าซ้อน แล้วบังคับให้ตัวเลขประกาศตัวเอง**

ไม่ทำ allocation, ไม่บังคับ project อันเดียว · แทนด้วยสี่ชั้น:

**ชั้น 1 · ชื่อของสิ่งที่คืนมาต้องพูดความจริง**
view ชื่อ `v_tag_touch_totals` (ไม่ใช่ `v_tag_totals`) คอลัมน์ชื่อ
`touched_debit` · `touched_credit` · `touched_txn_count`
และคอลัมน์ที่บอกความซ้อนมาด้วยในแถวเดียวกัน:
`overlap_txn_count` (จำนวนใบในแถวนี้ที่ติด tag ชนิดเดียวกันมากกว่าหนึ่งอัน) ·
`overlap_debit` · **ไม่มีคอลัมน์ชื่อ `total` หรือ `amount` เปล่าๆ ให้หยิบไปใช้ผิด**

**ชั้น 2 · มี "ยอดรวมที่ถูก" ให้ใช้ เพื่อให้ไม่มีใครต้องบวกข้าม tag**
`v_tag_coverage` คืนยอดที่นับใบละครั้งของชุดที่กรองอยู่ แยกสามก้อน:
`tagged_distinct` (ติด tag อย่างน้อยหนึ่งอัน) · `untagged` (ไม่ติดเลย) ·
`ledger_total` (= `tagged_distinct + untagged` ตรงกับยอดใน `v_ledger_posted` เสมอ)
เหตุผล: **ถ้าไม่มีทางที่ถูก คนจะใช้ทางที่ผิด** หน้าไหนอยาก "รวม" ให้ใช้ view นี้

**ชั้น 3 · ประโยคกำกับมาจาก DB ไม่ใช่จากหน้าจอ**
ทุกตาราง/การ์ด/export ที่แสดงยอดต่อ tag **ต้อง** แสดง `tag_kinds.aggregate_note_th`
seed ว่า: *"ยอดที่แตะ tag นี้ · ใบที่ติดหลาย tag ถูกนับในทุก tag ที่ติด — เอายอดของแต่ละ
tag มาบวกกันไม่ได้ · ยอดรวมที่ถูกดูที่ 'ยอดรวมของชุดที่กรอง'"*
component ที่แสดงยอดต่อ tag **โยน error ถ้าไม่ได้รับ note** (ไม่ใช่แสดงเปล่าๆ)
→ ลืมใส่ = หน้าแดงตอน dev ไม่ใช่เลขเปลือยตอนผู้ใช้อ่าน

**ชั้น 4 · ด่านที่ชั้น DB: รายงานใหม่ที่อ่าน tag ต้องผ่านการตัดสินใจที่เห็นใน git**
`fn_assert_tag_read_path()` (แพทเทิร์นเดียวกับ `fn_assert_ledger_read_path` ของ D-098)
พังเมื่อ:
- มี view/matview/ฟังก์ชัน set-returning ตัวใหม่ที่อ่าน `transaction_tags`
  **ตรงๆ** นอก allow-list (`v_ledger_tagged` · `v_tag_touch_totals` · `v_tag_coverage`)
  → รายงานใหม่ที่จะนับซ้ำต้องถูกเพิ่มเข้า allow-list พร้อมเหตุผลใน migration
  ซึ่งแปลว่า `mace-windu` ต้องเห็น (กติกาข้อ 7 ของ CLAUDE.md)
- `transaction_tags` มีคอลัมน์ชนิดตัวเลขเงิน (ปิดทางเลือก C เชิงโครงสร้าง)
- มี view ไหนที่อ่าน `v_tag_touch_totals` แล้วมี `sum(` ในนิยาม (= กำลังบวกข้าม tag)
- `aggregate_note_th` ของ `tag_kinds` แถวใดว่าง (ชั้น 3 จะกลายเป็นข้อความเปล่า)
- ด่านกันตัวเองตาย: ถ้าไล่ catalog ไม่เจอ view ของตัวเองครบสามตัว → พัง
  (เครื่องมือที่ครอบไม่ครบอันตรายกว่าไม่มีเครื่องมือ · D-096)

### 4.3 ทางเลือกที่ **ไม่** เลือก และเหตุผล

**B · `project` ติดได้อันเดียว · `label` ไม่จำกัด** — ข้อดีจริงและข้อเดียวที่สำคัญ:
ยอดต่อ project **บวกกันได้** ทำให้เปิดรายงาน "กำไรต่อ project" และ "% ของ NAV
ต่อ project" ได้โดยไม่ต้องมี allocation · ข้อเสีย: ค้านคำสั่ง 26/10 และของจริงมีใบที่
แตะสอง project อยู่จริง (ค่าช่างคันเดียวไปสองไซต์) ซึ่งถ้าบังคับอันเดียวคนจะเลือก
มั่วๆ แล้วข้อมูลผิดตั้งแต่ต้นทาง — ผิดที่ต้นทางแก้ยากกว่าผิดที่วิธีรวม
**เสนอเป็นทางเลือกให้ลูกพี่ตัดสิน** ไม่ตัดสินแทน · ถ้าเอา B: พลิก
`tag_kinds.allows_multi = false` ของแถว `project` + migration backfill `single_per_txn`
+ `tag_link_single_uq` เริ่มกันเอง — **ไม่ต้องรื้อ schema** (คานถูกวางไว้แล้วที่ 3.3)

**C · ใส่สัดส่วนต่อ tag (60/40)** — ปฏิเสธในรอบนี้ และปฏิเสธ **เชิงโครงสร้าง**
(guard ห้ามคอลัมน์ตัวเลขเงินใน `transaction_tags`) เหตุผล: ต้องบังคับ Σ = 100% ต่อใบ
ต่อชนิด, ต้องตัดสินว่าสัดส่วนคิดจากยอดใบหรือต่อบรรทัด (ใบเงินต้น+ดอกเบี้ยคิดต่างกัน),
ต้องมีร่องรอยตอนแก้สัดส่วนย้อนหลัง, และทำให้ tag กลายเป็น **ตัวเลขที่เข้าสู่รายงานเงิน**
= tag เริ่มมีน้ำหนักต่อตัวเลข ซึ่งขัดหลักข้อ 4 ของ ADR นี้ทั้งข้อ
ถ้าวันหนึ่งจำเป็นจริง ให้ทำเป็น **ตารางแยก** (`tag_allocations`) + ADR ใหม่ ไม่ใช่เติมคอลัมน์

### 4.4 ตัวเลขที่ผู้ใช้จะเห็นแล้วเข้าใจผิดได้ (ลิสต์ที่ต้องมีในเทสต์ทุกข้อ)

| ตัวเลข | เข้าใจผิดเป็น | กันยังไง |
|---|---|---|
| ยอดต่อ project แต่ละแถว | "นี่คือยอดของ project นี้โดยเฉพาะ" | ชื่อคอลัมน์ `touched_*` + note ชั้น 3 + `overlap_txn_count` ในแถวเดียวกัน |
| ผลบวกของทุกแถว project | "ยอดรวมทั้งกอง" | ไม่มีแถว total ใน view · มี `v_tag_coverage` ให้ใช้แทน · guard ชั้น 4 |
| **กำไร/margin ต่อ project** | "project นี้กำไรเท่านี้" | **ไม่เปิดหน้านี้ในรอบนี้** — ใบรายได้ติดสอง project ใบต้นทุนติดหนึ่ง = margin เพี้ยนแบบที่ดูไม่ออก · เปิดได้เมื่อมีทางเลือก B หรือ C |
| **% ของ NAV ต่อ project** | สัดส่วนพอร์ต | ไม่เปิด (ตัวหารเพี้ยนเพราะตัวเศษซ้อน) |
| export CSV ไป pivot ใน Excel | sum ใน Excel = ยอดจริง | ทุกไฟล์ export มีคอลัมน์ `transaction_id` + `tags_on_this_txn` (จำนวน tag ชนิดเดียวกันบนใบนั้น) + บรรทัดแรกเป็นประโยค note ชั้น 3 |
| ยอดต่อ tag ของคนละ role | "เลขของระบบ" | หัวตารางบังคับแสดง "คิดจาก Entity ที่คุณมีสิทธิ์เห็น: ..." (หัวข้อ 5 ข้อ 2) |
| `touched_debit` ของใบหลายบรรทัด | "เงินที่เคลื่อน" | view แยกตาม `coa_id` + `cf_category` ไม่มีคอลัมน์ "ยอดใบ" รวม (ใบเงินต้น+ดอกเบี้ยอ่านรวมแล้วผิด) |

---

## 5. ตอบโจทย์ข้อต่อข้อ

### 1 · schema → หัวข้อ 3

ชนิดแยกด้วย `tags.kind` → `tag_kinds(key)` (ไม่ใช่ enum · ไม่ใช่ boolean `is_project`)
"project ได้อันเดียว" **ไม่บังคับในรอบนี้** ตามคำสั่ง แต่คานที่บังคับได้คือ
partial unique index `tag_link_single_uq` ที่ predicate อ่านจากคอนฟิก (3.3)

### 2 · กฎเหล็กข้อ 3 — tag ของกองกลาง แต่รายการของผู้ถือ

**แค็ตตาล็อกเป็นของกองกลาง** เพราะ project ของบ้านนี้ข้ามผู้ถือจริง (ทรัพย์เล็กอยู่ชื่อ
บุคคล ทรัพย์ใหญ่อยู่บริษัท ใบของ project เดียวกันจึงอยู่คนละผู้ถือ) ถ้าผูก tag กับ owner
จะต้องสร้าง tag ชื่อเดียวกัน 8 ชุด = **ปัญหาพิมพ์ผิดกลับมาทางหลังบ้าน** ซึ่งคือเหตุผล
ที่ลูกพี่สั่งให้เลือกจากรายการตั้งแต่แรก
กฎเหล็กข้อ 3 ยังไม่ถูกละเมิด เพราะมันใช้กับ **แถวที่มีความเป็นเจ้าของ/มีเงิน** —
`chart_of_accounts` · `txn_types` · `contacts` ก็ไม่มี `owner_id` เช่นกัน

RLS สามชั้น:

| ตาราง | อ่าน | เขียน |
|---|---|---|
| `tag_kinds` · `tags` | `authenticated` ทุกคน (ชื่อ tag ไม่ใช่ตัวเลขเงิน) | `fn_can('tag.catalog')` |
| `transaction_tags` | `fn_can_see_owner(owner_id)` — policy เดียวกันรูปเดียวกับ `transactions_by_owner` | insert: `fn_can('tag.assign') and fn_can_see_owner(owner_id)` · update: เฉพาะการปิด (ถอด) · **delete: ไม่มี policy เลย** |
| `draft_entry_tags` | ตาม `draft_entries` ที่มีอยู่ | ตาม `draft_entries` |

ทางรั่วที่ต้องกันเป็นพิเศษ (เพราะ tag เป็นกองกลาง แต่ใบไม่ใช่):

1. **รั่วผ่านตัวเลขรวม** — ทั้งสาม view ต้อง `security_invoker = true` และอ่านข้อมูลเงิน
   **ผ่าน `v_ledger_posted` เท่านั้น** (ซึ่ง invoker อยู่แล้ว) · ผลที่ตามมาโดยเจตนา:
   **ยอดต่อ tag ของคนละสิทธิ์ไม่เท่ากัน** → หัวตารางต้องเขียนว่าคิดจาก Entity ไหน
   ไม่งั้นสองคนเปิดหน้าเดียวกันเห็นเลขต่างกันแล้วเถียงว่าระบบผิด
2. **ห้าม definer ทางลัด** — ห้ามทำ `fn_tag_totals()` แบบ `security definer` เพื่อ "ให้
   ยอดครบ" เด็ดขาด (= เปิดสมุดของผู้ถืออื่นผ่านยอดรวม) guard ตรวจ `prosecdef` ของ
   ฟังก์ชันที่อ่าน `transaction_tags` แล้วพัง
3. **นับใบของคนอื่น** — `touched_txn_count` คิดจาก `v_ledger_posted` ที่ถูก RLS กรองแล้ว
   ห้าม `count(*)` จาก `transaction_tags` ตรง (วันหนึ่ง policy สองตารางเพี้ยนไม่เท่ากัน = รั่ว)
4. **ยอมรับไว้ตรงๆ**: ชื่อ project ทุกคนเห็น · ถ้าวันหนึ่งมี project ที่ชื่อเป็นความลับ
   ต้องทำ ADR ใหม่ (ห้ามแอบเติม `owner_id` ลง `tags` ครึ่งทาง · บทเรียนข้อ 7)

### 3 · กฎเหล็กข้อ 1 — แก้ tag ของใบที่ post แล้ว

**แก้ได้ แต่แก้แบบไม่มีร่องรอยไม่ได้** เหตุผลที่ไม่ใช้กฎเดียวกับตัวเลข (reverse+ลงใหม่):
tag ไม่กระทบตัวเลขเลย และ project จริงถูกตั้งชื่อ/แบ่งใหม่ได้ ถ้าบังคับ reverse ใบจริง
เพื่อแก้ tag เราจะได้ใบกลับรายการปลอมเต็มสมุด ซึ่งแย่กว่า

- ติด tag → แถวใหม่ (`tagged_at/by` ตั้งโดย trigger ปลอมไม่ได้)
- ถอด tag → **UPDATE เติม `untagged_at/by/untag_reason`** · เหตุผล **บังคับ** (btrim <> '')
  เหมือน `void_reason` ของ D-098 — ถ้าใช้ tag ตรวจย้อนหลังแล้วถอดได้เงียบๆ ก็เชื่อไม่ได้
- **DELETE ไม่ได้ทุกทาง**: ไม่มี delete policy + `fn_tag_link_no_delete()` trigger
  (กันทางเจ้าของฐานข้อมูลด้วย เหมือนกฎเงินอื่น)
- ค่าที่ลงแล้วแก้ย้อนหลังไม่ได้: `transaction_id` · `tag_id` · `owner_id` · `tagged_*`
  และเมื่อปิดแล้ว `untagged_*` ก็แช่แข็ง (แพทเทิร์น `fn_void_audit_columns`)
- `audit_log` ครอบตารางนี้ตามแพทเทิร์นเดิม → ประวัติ "ติด/ถอด/ใคร/ทำไม" แสดงในหน้า
  รายละเอียดใบคู่กับประวัติอื่น
- **งวดปิดแล้ว**: default = ยังติด/ถอด tag ได้ (ไม่ใช่ตัวเลข ไม่กระทบงบที่ล็อก) แต่
  **ต้องมีเหตุผลทั้งขาติดและขาถอด** · สวิตช์อยู่ `settings` key `tags.lock_with_period`
  (default `false`) ตามกฎเหล็กข้อ 5 — ไม่ hard-code
- **ปิด tag ทิ้ง**: `is_active = false` ซ่อนจาก **ตัวเลือกตอนติดเท่านั้น** ·
  ลิงก์เก่าไม่ถูกแตะ · FK `restrict` + trigger ทำให้ลบแถว tag ที่ถูกใช้แล้วไม่ออก ·
  **ตัวกรองในรายงานต้องแสดง tag ที่ปิดแล้วในกลุ่ม "ปิดใช้งาน" ไม่ใช่หายไป** —
  ถ้าหายไป การกรองย้อนหลังจะไม่ครบโดยไม่มีใครรู้ ซึ่งคือความพังที่โจทย์กลัวตั้งแต่ต้น
  (มีเทสต์: ปิด tag แล้วกรองย้อนหลังยังเจอใบเดิมครบจำนวนเท่าเดิม)

### 4 · Money Invariants — tag แตะตัวเลขไม่ได้เชิงโครงสร้าง

1. tag อยู่ **ตารางแยก** ไม่ใช่คอลัมน์บน `transactions`/`transaction_lines`
   → ทุก view · รายงาน · `fn_health_check` ที่มีอยู่ **ถูกต้องอยู่แล้วโดยไม่ต้องแก้**
   (เหตุผลข้อ 1 เดียวกับ ADR 0001)
2. `buildPosting()` · `buildPostingDraft()` · `previewPosting()` **ไม่รับและไม่คืน tag**
   → ไม่มีทางที่ tag จะเปลี่ยนคู่บัญชี เพราะฟังก์ชันที่สร้างบรรทัดไม่เคยเห็น tag
3. `txn_types` / `coa` / `intercompany.ts` **ไม่มีช่องไหนอ้าง tag** → guard ตรวจว่า
   ตารางกฎทั้งสามชุดไม่มีคอลัมน์ที่ชื่อมี `tag` (ถ้ามีวันหนึ่ง = กฎบัญชีขึ้นกับ tag แล้ว)
4. `transaction_tags` **ห้ามมีคอลัมน์จำนวนเงิน/สัดส่วน** (guard ไล่ `information_schema`)
5. trigger บน `transaction_tags` **ห้ามเขียน `transactions` / `transaction_lines`**
   → guard ไล่ `prosrc` ของทุก trigger function ของตารางนี้ แล้วพังถ้าเจอชื่อสองตารางนั้น
6. `fn_post_entry` รับ `tag_ids` เป็น **array ของ uuid เท่านั้น** · ตรวจว่า tag มีจริงและ
   `is_active` · **ไม่รู้จัก/ปิดแล้ว = ปฏิเสธทั้งใบ** (หลักเดิมของประตู: ไม่ทิ้งช่องเงียบๆ) ·
   เขียน `transaction_tags` **หลัง** บรรทัดบัญชีถูกเขียนและตรวจครบแล้ว และไม่มีเส้นทางใด
   ที่ค่าใน `tag_ids` ย้อนไปมีผลต่อชุดบัญชีที่อนุญาต (`v_allowed` คิดจาก `txn_types` ก่อนหน้า)
7. เทสต์ vitest: `buildPosting()` ของ input เดียวกันให้บรรทัดเท่ากันทุกตัวอักษร ไม่ว่าจะ
   ส่ง tag หรือไม่ส่ง (รวมเคส **ไม่ส่ง** · บทเรียนข้อ 3 ของ mace-windu)

### 5 · การกรอง

อ่านผ่าน `v_ledger_tagged` = `v_ledger_posted` ⋈ `transaction_tags`
(`untagged_at is null`) → **ใบที่ยกเลิกไม่ถูกนับโดยโครงสร้าง** เพราะ `v_ledger_posted`
กรอง `status = 'posted'` แบบ allow-list อยู่แล้ว · ลิงก์ของใบที่ void **ไม่ถูกลบ**
(เป็นร่องรอย) แต่โผล่ในงบไม่ได้
ทั้งสาม view อ่าน `v_ledger_posted` ไม่ได้อ่านตารางฐาน → **ผ่าน guard ของ D-098
(`fn_assert_ledger_read_path`) อยู่แล้ว ไม่ต้องเพิ่ม allow-list ของ D-098**

กรองได้ครบชุด (ถ้าขาดข้อใดข้อหนึ่ง = เปิดครึ่งเดียว ห้ามส่ง):
tag หลายอัน + **โหมด `any` / `all` ที่ต้องแสดงบนหน้าจอ** (สองโหมดให้เลขต่างกัน) ·
ชนิด tag · **"ยังไม่ติด tag เลย"** (ของที่ตกสำรวจคือของที่หาไม่เจอ) ·
owner (หลายอัน + Consolidated) · ช่วงวันที่ + **ต้องเลือกว่า `doc_date` หรือ `cash_date`
และแสดงว่าเลือกอันไหน** · contact · หมวดรายการ · ทรัพย์ · สถานะเงินสด (ค้าง/จ่ายแล้ว)

โหมด `all` คิดด้วย `group by transaction_id having count(distinct tag_id) = :n`
(ไม่ใช่ `and` ซ้อนกัน) · index ที่ต้องมีอยู่ใน 3.3 · และบน `transactions` ต้องมี
`(owner_id, doc_date desc)` · `(contact_id, doc_date)` · `(cash_date)` —
**ผู้ทำ migration ต้องตรวจก่อนว่ามีอยู่แล้วหรือยัง ไม่ใช่สร้างซ้ำ**

### 6 · กฎเหล็กข้อ 5

`tag_kinds` · `tags` อยู่ในตาราง ตั้งค่าได้ที่หน้า Settings · หน้าจออ่านแค็ตตาล็อกมาแสดง
**tag ไม่ใช่กฎบัญชี → ห้ามเอาเข้า `src/lib/rules/` และ `sync:rules` / `check:sync`
ไม่เกี่ยวกับ tag เลย** (ถ้าเอาเข้าไป ทุกครั้งที่ลูกพี่เพิ่ม project จะต้องเขียน migration)
เทสต์: grep `src/` แล้วต้องไม่เจอ `code` ของ tag ใด ๆ ที่มีในตาราง ·
seed มีแค่ `tag_kinds` 2 แถว · **ไม่ seed project ตัวอย่าง** (หน้าจอมี empty state
"ยังไม่มี tag — ไปตั้งที่หน้าตั้งค่า")

### 7 · ฟอร์ม

- ติด tag ได้ **ตอนสร้างร่าง** (ฟอร์มบันทึกรายการ + คิวร่าง) และบนใบที่ post แล้ว
- ตัวเลือกเป็น **รายการติ๊กที่โหลดมาจากแค็ตตาล็อก** มีช่องค้นหา (กรองรายการที่มี)
  **แต่พิมพ์สร้าง tag ใหม่จากฟอร์มรายการไม่ได้** · สร้าง tag ได้ที่หน้าตั้งค่าโดย
  `tag.catalog` เท่านั้น (คือสิ่งที่ลูกพี่สั่ง: ตั้งไว้ก่อนแล้วเลือก)
- สิทธิ์: ติด/ถอดบนใบ = `tag.assign` (staff ✓) · แค็ตตาล็อก = `tag.catalog`
  (management ✓ · manager ✗) — ตารางสิทธิ์ ไม่ใช่ชื่อ role ในโค้ด
- UI (ผู้ใช้มีผู้สูงอายุ · ห้ามลด):
  ปุ่ม/แถวเลือกสูง ≥ 52px (มือถือ 56px) · **ทุกปุ่มมีข้อความ** — ปุ่มถอด tag เขียนว่า
  "เอา tag นี้ออก" ไม่ใช่ `✕` เดี่ยว · ตัวอักษร ≥ 16px (ปกติ 18px) + รองรับโหมดตัวใหญ่ ·
  วงแหวนโฟกัส 3px · chip ใช้ `color_token` จาก `tailwind.config.ts` เท่านั้น ·
  ตัวเลขในตารางต่อ tag เป็น tabular · ติดลบใช้วงเล็บ
- ถอด tag ต้องกรอกเหตุผลใน dialog ที่ถามเป็นประโยคเต็ม
  ("เอา tag «ไอริส 235» ออกจากรายการวันที่ 12/09 ยอด 45,000 บาท · เพราะอะไร")
- หน้ารายละเอียดใบแสดง chip ที่ติดอยู่ + ส่วน "ประวัติ tag" (ติด/ถอด/ใคร/เมื่อไหร่/ทำไม)

---

## 6. แผนแตกงาน (ชิ้นที่ไม่แตะไฟล์เดียวกัน · รันขนานใน worktree ได้)

ขนานกันได้: **1 ∥ 2 ∥ 5 ∥ 6** · แล้ว **3** (ต้องรอ 1+2) · แล้ว **4** · แล้ว **7** (serial)

| # | ชิ้นงาน | agent | ไฟล์ที่แตะ (ไม่ทับกัน) |
|---|---|---|---|
| 1 | แค็ตตาล็อก: `tag_kinds` · `tags` + RLS + seed 2 ชนิด + guard ท้ายไฟล์ | `plo-koon` | `supabase/migrations/<ts>_tag_catalog.sql` · `supabase/tests/zz_tag_catalog_test.sql` |
| 2 | ลิงก์: `transaction_tags` + trigger (owner สำเนา/ปลอม tagged_by ไม่ได้/ห้าม DELETE/แช่แข็ง) + index + RLS | `plo-koon` | `supabase/migrations/<ts>_tag_links.sql` · `supabase/tests/zz_tag_links_test.sql` |
| 3 | ประตู + ร่าง + วิว + ด่าน: `fn_post_entry` รับ `tag_ids` · `draft_entry_tags` · `v_ledger_tagged` · `v_tag_touch_totals` · `v_tag_coverage` · `fn_assert_tag_read_path()` · permission key `tag.assign` / `tag.catalog` | `plo-koon` | `supabase/migrations/<ts>_tag_post_and_views.sql` · `supabase/tests/zz_tag_post_entry_test.sql` |
| 4 | server actions + queries + zod: ติด/ถอด tag · query ตัวกรองครบชุด · export CSV ที่มี `transaction_id` + `tags_on_this_txn` + บรรทัด note | `obi-wan` | `src/modules/tags/{actions,queries,schema,types}.ts` · `src/app/(app)/reports/tags/page.tsx` (ไฟล์ใหม่) |
| 5 | component: `TagPicker` (รายการติ๊ก) · `TagChip` · `TagTouchTable` (บังคับ note ไม่งั้น throw) | `luminara` | `src/components/tags/{tag-picker,tag-chip,tag-touch-table}.tsx` |
| 6 | เทสต์สัญญา: tag ไม่เปลี่ยนบรรทัดบัญชี (รวมเคสไม่ส่ง) · Σ ต่อ tag > ยอดจริงเมื่อซ้อน · `v_tag_coverage` = ยอด `v_ledger_posted` · ปิด tag แล้วยังกรองเจอ | `ki-adi-mundi` | `tests/tags/*.test.ts` |
| 7 | ต่อ `TagPicker` เข้าฟอร์มบันทึก/คิวร่าง + หน้ารายละเอียดใบ (ประวัติ tag) | `obi-wan` | ไฟล์ฟอร์มเดิมใน `src/app/(app)/ledger/**` — **ทำเป็นลำดับ ไม่ขนานกับ 4** |
| 8 | ตรวจ diff ทุกชิ้นที่แตะ migration / RLS / ประตู | `mace-windu` | — (บังคับก่อน merge ทุกชิ้น) |
| 9 | CHANGELOG + decision log (D-xxx) | `kit-fisto` | `CHANGELOG.md` · `docs/DECISIONS.md` |

**สัญญาระหว่างชิ้นงาน**

```
-- ชิ้น 3 → ชิ้น 4 (ประตู)
fn_post_entry(jsonb)  -- เพิ่มชื่อช่องใน c_header: 'tag_ids'  (array ของ uuid เท่านั้น)
fn_tag_transaction(p_transaction_id uuid, p_tag_id uuid, p_note text)      returns uuid
fn_untag_transaction(p_transaction_id uuid, p_tag_id uuid, p_reason text)  returns void
   -- ทั้งสองเป็น security INVOKER (ห้าม definer) · reason บังคับที่ untag
v_ledger_tagged(tag_id, tag_code, tag_kind, owner_id, transaction_id, doc_date,
                cash_date, contact_id, coa_id, cf_category, debit, credit, ...)
v_tag_touch_totals(tag_id, tag_kind, owner_id, coa_id, cf_category, period,
                   touched_debit, touched_credit, touched_txn_count,
                   overlap_txn_count, overlap_debit, aggregate_note_th)
v_tag_coverage(... ตัวกรองเดียวกัน ..., tagged_distinct, untagged, ledger_total)
```

```ts
// ชิ้น 4 → ชิ้น 5 และ 7  (src/modules/tags/types.ts)
type TagKind = { key: string; nameTh: string; allowsMulti: boolean; aggregateNoteTh: string };
type Tag     = { id: string; kind: string; code: string; nameTh: string; isActive: boolean;
                 colorToken: string | null };
type TagFilter = {
  tagIds: string[]; mode: "any" | "all"; kinds?: string[]; untaggedOnly?: boolean;
  ownerIds: string[]; dateField: "doc_date" | "cash_date"; from?: string; to?: string;
  contactId?: string; txnTypeCodes?: string[]; assetId?: string;
};
// buildPosting / buildPostingDraft / previewPosting — signature ไม่เปลี่ยน
```

---

## 7. ย้อนกลับได้แค่ไหน

ย้อนได้ง่ายกว่าของอื่นในรีโปนี้ (tag ไม่ใช่ตัวเลขเงิน): drop สาม view · drop
`transaction_tags` / `draft_entry_tags` / `tags` / `tag_kinds` · คืน `fn_post_entry`
รุ่นก่อน (ถอด `tag_ids` ออกจาก `c_header`) — ไม่มีตัวเลขในงบเปลี่ยนแม้บาทเดียว
**แต่ข้อมูลที่ติดไว้หายถาวร** และการกรองย้อนหลังหายไปทั้งฟีเจอร์ → ก่อนย้อนให้ dump
`transaction_tags` ทั้งตาราง
สิ่งที่ย้อนยากจริงคือ **การเลือกทาง A (ไม่มี allocation)**: ถ้าวันหนึ่งเปลี่ยนไปทาง B หรือ C
ต้องกลับไปตัดสินใบที่ติดหลาย project ทีละใบด้วยมือ ซึ่งไม่มีใครทำย้อนหลังได้แม่น —
จึงบันทึกเป็น ADR และ **ขอให้ลูกพี่ยืนยันทาง A หรือสั่ง B ก่อนเริ่มชิ้นงานที่ 1**

## 8. ความเสี่ยงที่ยอมรับไว้ (เขียนไว้เพื่อไม่ให้ลืม)

1. **tag ซ้ำความหมาย** (`ไอริส235` กับ `iris-235`) — ไม่มีฟังก์ชัน merge ในรอบนี้ ·
   กันด้วย `code` unique + ฟอร์มสร้าง tag ต้องค้นก่อนและเตือนเมื่อชื่อใกล้กัน +
   สร้างได้เฉพาะ `tag.catalog` · ถ้าเกิดขึ้นจริง การกรองยัง **ครบ** (กรองสอง tag ได้)
   แค่คุณภาพข้อมูลแย่ลง — ไม่ใช่ตัวเลขผิด
2. ชื่อ project ทุกคนที่ล็อกอินเห็น (หัวข้อ 5 ข้อ 2 ข้อย่อย 4)
3. ไม่มี tag ซ้อนชั้น (project → sub-project) · ถ้าต้องมี ให้ทำเป็น ADR ใหม่พร้อม
   ตัดสินเรื่องการนับซ้ำของชั้นแม่-ลูกไปด้วย **ห้ามเติม `parent_id` เงียบๆ**
4. ยังไม่มีรายงาน "กำไรต่อ project" โดยเจตนา — เป็นสิ่งที่ลูกพี่น่าจะถามหาเร็วที่สุด
   คำตอบที่ต้องให้คือ "ต้องเลือกทาง B หรือ C ก่อน" ไม่ใช่ทำหน้าที่นับซ้ำออกมา
