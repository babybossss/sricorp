# SRI OS — Family Office ERP (MVP Plan)

> เวอร์ชัน 0.3 · 17/09/2026 · สถานะ: **ร่างแผน รอลูกพี่อนุมัติก่อนเริ่มโค้ด**
> v0.3: Model สำหรับ Claude Max (เร็ว+แม่นยำ) · Deploy ระบบหลักก่อนแล้วอัปเดตต่อเนื่อง (หัวข้อ 14) · สัญญาเช่าไม่สร้างในระบบ ใช้ข้อมูลครบ+แนบไฟล์ · พอร์ตลงทุนถือโดย Thanakorn ทั้งหมด · Design Brief แยกไฟล์ `SRI_OS_DESIGN_BRIEF.md`
> v0.2: ปรับตามคำตอบลูกพี่ — Entity Policy (Corporate เข้ม / Personal override ได้แต่เงินห้ามหาย), ราคาฟรีก่อน, Personal 3 คน, Approval แบบ role ไม่ใช้วงเงิน, Jedi Council Agent Team, ประเมิน 3 วัน, Checklist สิ่งที่ต้องเตรียม
> ใช้เป็น spec ตั้งต้นให้ Claude Code (วางไฟล์นี้เป็น `docs/PLAN.md` ใน repo)

---

## 0. สรุปคำตัดสินใจหลัก (อ่านหน้านี้หน้าเดียวพอ)

| เรื่อง | คำแนะนำ | เหตุผลสั้นๆ |
|---|---|---|
| Stack | **Next.js 15 (App Router) + Supabase (Postgres/Auth/Storage/Edge Functions/Cron) + Vercel** | ตรงกับที่ลูกพี่ล็อกไว้แล้ว, Claude Code ถนัด, ต้นทุนต่ำ |
| Google Sheets | **ไม่ใช้เป็นฐานข้อมูล** — ทำหน้า Grid แบบ Sheet ในเว็บแทน (AG Grid / TanStack Table) + ปุ่ม Import/Export `.xlsx/.csv` + (เฟส 2) sync ออกไป Sheet แบบ *read-only* ให้คนที่ชอบ Sheet | Sheet ไม่มี double-entry, ไม่มี permission ระดับแถว, แก้ย้อนหลังได้โดยไม่มี audit log → งบไม่กระทบ |
| หัวใจระบบ | **ทุกตัวเลขต้องผ่าน Pipeline เดียว: Source → Draft → Approve → Post → Report** | ไม่มีรายการไหน "เข้า Ledger ตรง" ยกเว้นผู้มีสิทธิ์ key manual (ซึ่งก็ยังมี audit log) |
| ยอดคงเหลือ | คำนวณสดจาก `transaction_lines` เสมอ (ไม่เก็บยอด) | ตามสถาปัตยกรรมเดิมที่ตั้งไว้ |
| ผู้ใช้ไม่เห็น Dr/Cr | ผู้ใช้เลือก "ประเภทรายการ" (template) → ระบบลงคู่บัญชีให้ | ผู้สูงอายุใช้ได้, ลดคีย์ผิด |
| Personal vs Corporate | ทุก transaction, asset, account ผูก `owner_id` (บริษัท/บุคคล) บังคับ | หลักการที่ห้ามละเมิด |
| VAT | MVP: **ไม่มี VAT logic** แต่ **สร้างคอลัมน์รอไว้** (`vat_rate`, `vat_amount`, `tax_invoice_no`) ใน corporate | เฟส 2 ต่อได้ไม่ต้อง migrate ใหญ่ |
| AI/LLM | ผ่าน **adapter ชั้นเดียว** (`lib/ai/provider.ts`) เปลี่ยน Claude/OpenAI/Gemini ได้ในหน้า Config | ตามที่ขอ |
| ธีม | Stripe-like: พื้นขาว/เทาอ่อน, การ์ดขอบบาง, ตัวเลขชัด · สีหลักจากโลโก้ **#004AAD** · ฟอนต์ **IBM Plex Sans Thai** | ดูหัวข้อ 9 |
| ใช้เวลา | **3 วัน = "SRI OS Core" ใช้งานจริงได้** (Ledger + อนุมัติ + Asset/BS/NAV + Dashboard v1) · **MVP ครบ 11 โมดูล ≈ 3–4 สัปดาห์** ด้วย Agent Team + ลูกพี่ review ทุกวัน | คอขวดไม่ใช่การเขียนโค้ด แต่คือ **ข้อมูลตั้งต้นที่ถูกต้อง** และการตรวจกฎบัญชี — ดูหัวข้อ 10 |
| Approval | ไม่มีวงเงิน (อนุมัติจ่ายจริงที่ธนาคาร) · ทุกคนสร้างรายการได้ · User/Manager → รอ **Management** อนุมัติ → Ledger · Management ข้ามขั้นได้ | ดูหัวข้อ 8 |
| Entity Policy | **Corporate = เข้ม 100%** (ห้าม override) · **Personal = override ได้บางกรณี แต่เงินห้ามหาย** (invariant บังคับที่ DB) | ดูหัวข้อ 5 |

### ⚠ จุดที่ผมขอแก้/เติมจากโจทย์ (ตรงๆ)

1. **ขายฝาก/จำนอง/ปล่อยกู้ = Investing ไม่ใช่ Financing** — ตามโจทย์ Financing +/− คือ "เรากู้เขา/คืนเขา" ถูกแล้ว แต่เงินต้นที่ **เราปล่อยออกไป** ต้องเป็น `Investing −` (ผูก asset = ลูกหนี้ขายฝาก 1400) และตอนไถ่ถอนเป็น `Investing +` ส่วน **ดอกเบี้ย/ค่าตอบแทน** เป็น `Income +` เท่านั้น ถ้าไม่แยก Cashflow จะเพี้ยนและ PL จะบวมเกินจริง
2. **ขาดประเภท "Transfer" (โอนระหว่างบัญชีตัวเอง)** — เช่น SRI-SCB → Thanakorn-BBL 888 ถ้าไม่มีจะถูกนับเป็นรายได้/รายจ่ายซ้ำ ต้องมี `Transfer` (ไม่เข้า PL) และถ้าข้าม owner ต้องติด `is_intercompany` + เลือกลักษณะ (เงินทดรอง / กู้ยืมกรรมการ / เพิ่มทุน / ปันผล)
3. **ขาด Equity +/−** — เงินทุนอากง (5,337,000) ต้องเป็น `Financing + (Equity)` แยกจาก `Financing + (Director Loan)` 12,833,000 ห้ามรวม (ตามหลักการ)
4. **"เงินค้างรับ/ค้างจ่าย" ต้องแยก 2 วันที่** — วันที่เอกสาร (accrual → PL) กับวันที่เงินเข้าจริง (cash → CF) เหมือนที่ทำใน Excel ERP ไม่งั้น Dashboard AR/AP ทำไม่ได้
5. **ราคาหุ้น: ใช้แหล่งฟรีก่อน** (ลูกพี่ตัดสินแล้ว) — แหล่งฟรีส่วนใหญ่ไม่เป็นทางการ อาจพังได้ ต้องมี manual override + ธง "ราคาเก่า" แล้วค่อยต่อ API จริงทีหลัง — ดูหัวข้อ 2.3
6. ยังค้างจาก Excel: **ผลต่างรอกระทบยอด 34.6M** (เงินป๊า ~23M ที่หาไม่เจอ) — ถ้า migrate เข้าระบบใหม่โดยไม่เคลียร์ ตัวเลข NAV หน้าแรกจะผิดตั้งแต่วันแรก → ต้องเป็นงาน Sprint 0

---

## 1. หลักการออกแบบ: Pipeline ที่ชัด แก้ได้ ต่อยอดได้

```
 ┌─────────── SOURCES ────────────┐     ┌──── QUEUE ─────┐    ┌── LEDGER ──┐    ┌──── REPORTS ─────┐
 │ Manual key (Ledger)            │     │                │    │            │    │ Dashboard        │
 │ Asset schedules (ค่าเช่า/ดอกเบี้ย) │ ──► │  draft_entries │ ─► │transactions│ ─► │ PL / CF          │
 │ Payroll run                    │     │  (รออนุมัติ)     │    │   + lines  │    │ Balance Sheet/NAV│
 │ Reimbursement (เบิกเงินสำรอง)    │     │ Approve/Reject │    │  (posted)  │    │ AR/AP aging      │
 │ Bank confirm (รับ/จ่ายจริง)       │     │ ทีละตัว / Bulk   │    │            │    │ Passive income   │
 │ Price feed (mark-to-market)    │     └────────────────┘    └────────────┘    └──────────────────┘
 └────────────────────────────────┘              ▲                   │
                                         audit_log (ใคร/เมื่อไหร่/แก้อะไร)   void/reverse เท่านั้น ห้ามลบ
```

กฎเหล็ก 6 ข้อ (เขียนลง `CLAUDE.md` ด้วย):

1. **ไม่มีการ DELETE รายการที่ post แล้ว** — แก้ด้วยการ Reverse + ลงใหม่ (trigger บังคับที่ DB)
2. **Double-entry บังคับที่ DB** — ผลรวม Dr = Cr ต่อ transaction (trigger เดิมที่ทดสอบแล้ว)
3. **ทุกแถวมี `owner_id`** และ report ทุกหน้ามี filter Entity: `SRI Corp / SRI Holding / SRI Capital / บุคคล(ชื่อ) / Consolidated`
4. **Module แยกโฟลเดอร์ + แยก schema/table prefix** เพิ่ม/ถอดโมดูลได้โดยไม่แตะ core ledger
5. **ทุกอย่างที่ "ตั้งค่าได้" อยู่ในตาราง config ไม่ hard-code** (ประเภทรายการ, หมวดทรัพย์, ขั้น Kanban, บัญชีธนาคาร, KPI, LLM)
6. **Automation ไม่เคย post เอง** — สร้าง draft เท่านั้น (ยกเว้น mark-to-market ราคาหุ้นซึ่งไม่ใช่ transaction เงินสด เก็บแยกใน `asset_valuations`)

---

## 2. Stack, Integrations, MCP/Plugin ที่แนะนำ

### 2.1 Core (MVP ต้องมี)

| ชั้น | เลือก | หมายเหตุ |
|---|---|---|
| Frontend | Next.js 15 + TypeScript + Tailwind + **shadcn/ui** | shadcn ทำ look แบบ Stripe ได้ง่ายสุด |
| Data grid (หน้าแบบ Sheet) | **AG Grid Community** (ฟรี) หรือ TanStack Table | inline edit, copy-paste จาก Excel, filter, group |
| Charts | Recharts / Tremor | Dashboard |
| Kanban | dnd-kit | ลาก-วาง |
| Gantt | **frappe-gantt** (เบา) หรือ SVAR Gantt | MVP ใช้ frappe-gantt พอ |
| Org chart | react-flow + dagre (auto layout) | auto-gen จาก `employees.reports_to` |
| DB/Auth/Storage | **Supabase**: Postgres 17, RLS, Auth (email magic link + Google), Storage (สลิป/บิล), Edge Functions, `pg_cron` | สร้าง project ใหม่ชื่อ `sri-os` (ตอนนี้ยังไม่มีใน Supabase — มี `hermes database`, `thanakorns`, `sumnight`) |
| Hosting | Vercel (Pro เมื่อใช้งานจริง เพราะ cron/ขนาด function) | |
| Validation | Zod + react-hook-form | ฟอร์มทั้งระบบ |
| i18n | ไทยเป็นหลัก, label อังกฤษกำกับ | |

### 2.2 Integration / MCP / Plugin — เรียงตามคุ้มค่า (ใช้ง่าย) · รายการเต็มพร้อมเฟสอยู่หัวข้อ 14.5

**สำหรับ "ตอนพัฒนา" ใน Claude Code**

| ตัว | ใช้ทำอะไร | ลำดับ |
|---|---|---|
| **Supabase MCP** (ต่ออยู่แล้ว) | สร้าง project, apply migration, ดู logs/advisors, gen TypeScript types | ★ ต้องมี |
| **Vercel MCP** (ต่ออยู่แล้ว) | ดู deploy/log, env vars | ★ ต้องมี |
| **GitHub** (`gh` CLI) | repo, PR, CI | ★ ต้องมี |
| Playwright (มีในเครื่องมือ) | ทดสอบหน้าจอ PC/Tablet/Mobile อัตโนมัติ | ★ |
| Context7 / docs MCP | ดึง docs Next/Supabase ล่าสุด | ดีถ้ามี |

**สำหรับ "ตอนระบบใช้งานจริง" (runtime)**

| บริการ | ใช้ทำอะไร | เฟส |
|---|---|---|
| **LINE Messaging API / LINE OA** | แจ้งเตือนอนุมัติ, ส่งสลิปเข้าระบบเบิกจ่าย, (เดิม) รับดีลขายฝาก | MVP: แจ้งเตือน · เฟส 2: รับสลิป/ดีล |
| **Resend** (email) | เชิญผู้ใช้, สรุปรายสัปดาห์ | MVP |
| **Claude API** (default) + OpenAI/Gemini (สำรอง) | OCR สลิป/ใบเสร็จ, จัดลำดับ To-do, สรุปบทความลงทุน | MVP |
| **Google Calendar** | Schedule ทีม sync 2 ทาง (อ่านเข้า Dashboard) | MVP อ่านอย่างเดียว |
| Google Drive | เก็บสัญญา/เอกสารต้นฉบับ (ลิงก์ในทรัพย์) | เฟส 2 (MVP ใช้ Supabase Storage) |
| PEAK | export ผังบัญชี map `peak_code` เป็น CSV ให้ผู้ทำบัญชี | เฟส 2 |
| n8n / Zapier | งานเชื่อมภายนอกที่ไม่คุ้มเขียนเอง (เช่น scrape listing) | เฟส 2 — **อย่าเอา business logic ไปไว้ใน n8n** |

### 2.3 แหล่งราคาทรัพย์ (Weekly price update) — **ฟรีก่อน, API ทีหลัง** ✅ ตัดสินแล้ว

| ทรัพย์ | MVP (ฟรี) | เฟสหลัง (API จริง) | ข้อสังเกต |
|---|---|---|---|
| หุ้นไทย | Yahoo Finance ticker `.BK` (endpoint ไม่เป็นทางการ) | Settrade Open API ผ่านโบรกเกอร์ / SET SMART | อาจโดนบล็อก/เปลี่ยน format → fallback ราคา manual |
| หุ้น/ETF US | Yahoo Finance (ฟรี) · สำรอง free tier ของ Finnhub/Twelve Data | Paid tier ของผู้ให้บริการเดิม | ดึงสัปดาห์ละครั้ง ใช้ request น้อย |
| กองทุนไทย | **SEC Open Data API** (ฟรี สมัคร key) | – | ทางการอยู่แล้ว ใช้ยาวได้ |
| Crypto | CoinGecko (free) | – | |
| ทองคำ | ราคาประกาศสมาคมค้าทองคำ (scrape) หรือ XAU/USD × USDTHB | – | ระบุหน่วย: บาททองคำ / ออนซ์ |
| FX | Bank of Thailand API (ฟรี สมัคร key) | – | |
| อสังหาฯ | **ไม่ auto** — manual + แนบราคาประเมินกรมธนารักษ์ / LandsMaps | – | เก็บประวัติใน `asset_valuations` |

กติกา: ถ้าดึงราคาไม่ได้ → ใช้ราคาล่าสุด + ธง "ราคาเก่า X วัน" + ขึ้น To-do · ทุกราคาเก็บ `source` เพื่อเปลี่ยนแหล่งทีหลังได้โดยไม่แตะข้อมูลเก่า

ออกแบบเป็น **price adapter** (`lib/prices/{set,us,fund,crypto,gold,fx}.ts`) → เปลี่ยนแหล่งได้ไม่แตะส่วนอื่น ถ้าดึงไม่ได้ ใช้ราคาล่าสุด + ติดป้าย "ราคาเก่า X วัน"

### 2.4 Google Sheet — คำตอบตรงๆ

**ไม่ควรเชื่อม Google Sheet เป็นที่เก็บข้อมูล** — ให้เก็บใน Supabase และทำหน้าเว็บ Grid ที่ "รู้สึกเหมือน Sheet" (แก้ในช่อง, วางจาก Excel, filter, ซ่อนคอลัมน์, export)
ใช้ Sheet ได้ 2 กรณีเท่านั้น: (1) **Import ข้อมูลตั้งต้น** จาก Excel 3 ไฟล์ปัจจุบัน (2) **Export/Sync ออกทางเดียว** ให้อากงหรือผู้สอบบัญชีเปิดดู

---

## 3. สถาปัตยกรรมและโครง Repo

```
sri-os/
├─ CLAUDE.md                      # กฎเหล็ก + คำสั่งให้ Claude Code (ดูหัวข้อ 11)
├─ docs/
│  ├─ PLAN.md                     # ไฟล์นี้
│  ├─ DATA_MODEL.md               # ER + ความหมายคอลัมน์
│  ├─ LEDGER_RULES.md             # ประเภทรายการ → คู่บัญชี
│  └─ decisions/ADR-001-*.md      # บันทึกการตัดสินใจ (แก้ภายหลังรู้ว่าทำไม)
├─ supabase/
│  ├─ migrations/                 # SQL เรียงเลข ห้ามแก้ไฟล์เก่า เพิ่มใหม่เท่านั้น
│  ├─ seed/                       # ผังบัญชี, ประเภทรายการ, บัญชีธนาคาร, หมวดทรัพย์
│  └─ functions/                  # Edge functions: prices-weekly, schedules-monthly, ai-digest, ocr-receipt
├─ src/
│  ├─ app/(app)/
│  │  ├─ dashboard/
│  │  ├─ ledger/                  # tabs: รายการ | รอยืนยันรับ-จ่าย | PL | Cashflow
│  │  ├─ balance-sheet/
│  │  ├─ assets/                  # asset list + [id] detail + schedules + tenants
│  │  ├─ approvals/               # คิวอนุมัติรวม (auto ledger, payroll, reimburse)
│  │  ├─ broker/
│  │  ├─ invest-tips/
│  │  ├─ contacts/
│  │  ├─ reimburse/
│  │  ├─ hr/                      # people | positions | KPI | org chart | payroll
│  │  ├─ board/                   # kanban deals + tickets + gantt
│  │  └─ settings/
│  ├─ modules/<module>/           # server actions, queries, schemas (zod), components ต่อโมดูล
│  ├─ lib/{ledger,ai,prices,auth,format}/
│  └─ components/ui/              # shadcn + design tokens
└─ tests/ (vitest: ledger rules · playwright: flows หลัก 3 ขนาดจอ)
```

Module contract: ทุกโมดูลที่ "สร้างเงิน" ต้องเรียก `createDraftEntry()` จาก `lib/ledger` เท่านั้น — ห้ามเขียน `transactions` เอง

---

## 4. Data Model (MVP)

### 4.1 Core — เจ้าของ / บัญชี / ผังบัญชี

| ตาราง | คอลัมน์สำคัญ | หมายเหตุ |
|---|---|---|
| `owners` | id, type(`company`/`person`), **policy(`corporate_strict`/`personal_flexible`)**, name_th, name_en, tax_id(ไม่แสดงเต็ม), vat_registered, is_active | Corporate: SRI Corporation, SRI Holding, SRI Capital · **Personal: Thanakorn, Thanawin, Benjaporn** (คุณสุธีเป็นผู้ถือหุ้น/ผู้ให้กู้ใน `contacts` ไม่ใช่ owner ฝั่ง Personal — เพิ่มได้ภายหลัง) |
| `bank_accounts` | id, owner_id, bank, account_name, **display_name**, account_no_last4, coa_id, opening_balance, opening_date, sort_order, **is_active** | เพิ่ม/ลด/เปลี่ยนชื่อ/ปิด ได้ในหน้า Config; Inactive ซ่อนจาก dropdown แต่ยังอยู่ในรายงานย้อนหลัง |
| `chart_of_accounts` | code, name_th, name_en, type(asset/liab/equity/income/expense), parent, peak_code, is_active | seed 41 รหัสจาก Excel ERP |
| `txn_types` (template) | code, name_th, **cf_group**(`operating`/`investing`/`financing`/`transfer`/`none`), direction(+/−), dr_coa, cr_coa, requires_asset, requires_contact, affects_pl, is_active | ผู้ใช้เลือกตัวนี้ ระบบลงคู่บัญชีเอง |
| `transactions` | id, owner_id, txn_type, **doc_date**, **cash_date**(null = ค้าง), status(`posted`/`void`), asset_id, contact_id, project_id, is_intercompany, counter_owner_id, memo, attachments[], vat_* (สำรองเฟส 2), created_by, approved_by, source(`manual`/`schedule`/`payroll`/`reimburse`) , source_ref | |
| `transaction_lines` | transaction_id, coa_id, bank_account_id, debit, credit, **cf_category**, asset_id | ยอดคงเหลือทุกอย่างคำนวณจากตารางนี้ |
| `draft_entries` | เหมือน transactions + `status`(`pending`/`approved`/`rejected`), reject_reason, due_date, batch_id | คิวอนุมัติกลาง |
| `cash_confirmations` | transaction_id, expected_amount, actual_amount, actual_date, bank_account_id, slip_url, confirmed_by | Tab "ยืนยันรับ/จ่าย" |
| `audit_log` | table, row_id, action, before, after, user_id, at | trigger ทุกตารางการเงิน |

### 4.2 ประเภทรายการ Ledger (seed ตามโจทย์ + ที่ผมเติม)

| กลุ่ม | ประเภท (ตัวอย่าง) | CF | PL | ผูก Asset |
|---|---|---|---|---|
| **Income +** | ค่าเช่า · ดอกเบี้ย/ค่าตอบแทนขายฝาก · ดอกเบี้ยจำนอง/เงินกู้ · เงินปันผล · ค่าบริการ/นายหน้า · Premium | Operating | ✓ | RE/FIN/INV ตามแหล่ง |
| **Expense −** | ค่าดำเนินงาน · เงินเดือน · ค่าส่วนกลาง · ภาษีที่ดิน · ซ่อมบำรุง(ไม่ใช่ปรับปรุงใหญ่) · ค่าธรรมเนียมโอน/จดจำนอง | Operating | ✓ | ได้ (optional) |
| **Investing −** | ซื้ออสังหาฯ · **ปล่อยเงินต้นขายฝาก/จำนอง/เงินกู้** · ซื้อหุ้น/กองทุน/ETF/crypto/ทอง · **ค่ารีโนเวท (capitalize เข้าต้นทุนทรัพย์)** · ลงทุนธุรกิจ | Investing | ✗ | **บังคับ** |
| **Investing +** | ขายอสังหาฯ · **รับไถ่ถอน/คืนเงินต้น** · ขายหุ้น/กองทุน → ระบบคำนวณ **กำไร/ขาดทุนจากการขาย** แยกบรรทัดเข้า PL | Investing | เฉพาะส่วน gain/loss | **บังคับ** |
| **Financing +** | กู้ธนาคาร · กู้ยืมกรรมการ (อากง) · **เพิ่มทุน (Equity)** | Financing | ✗ | – |
| **Financing −** | คืนเงินต้น · จ่ายดอกเบี้ย (→ ดอกเบี้ยจ่ายเข้า PL) · จ่ายปันผล/ถอนทุน | Financing | ดอกเบี้ย ✓ | – |
| **Transfer** | โอนระหว่างบัญชีตัวเอง · โอนข้าม owner (ต้องเลือกลักษณะ: ทดรอง/กู้ยืม/ทุน) | ไม่นับ (consolidate ตัดทิ้ง) | ✗ | – |

> Cost basis หุ้น/กองทุน: MVP ใช้ **Average cost** (ต้องยืนยันกับผู้สอบบัญชีว่าจะใช้ FIFO หรือ Avg ในฝั่งบริษัท)

### 4.3 Asset

| ตาราง | คอลัมน์สำคัญ |
|---|---|
| `asset_classes` (config) | **Business / Real Estate / Paper / Commodity** |
| `asset_categories` (config, แก้ได้) | RE: `รอขาย` · `ปล่อยเช่า` · `รับจำนอง-ขายฝาก` · `Project` · `รอปรับปรุง` / Finance: `Business` · `Bond` · `Loan Agreement` / Investment: `Stock` · `ETF` · `Fund` · `Crypto` · `Gold` |
| `assets` | id, code, name, class_id, category_id, **owner_id** (ผู้ถือกรรมสิทธิ์จริง), holding_nature(beneficial/nominee), beneficiary_id, status(`active`/`inactive`/`sold`/`redeemed`), acquired_date, cost_basis (คำนวณจาก ledger), location/ticker/units, contract_id, manager_user_id, tags |
| `asset_valuations` | asset_id, date, method(`market_api`/`appraisal`/`treasury`/`manual`/`cost`), unit_price, value, source_url, stale_flag |
| `contracts` | asset_id, type(`lease`/`ขายฝาก`/`จำนอง`/`loan`/`service`), counterparty_contact_id, principal, rate, rate_period, start, end, payment_day, deposit, notice_window_start/end (ขายฝาก), redemption_deadline, **file_urls (บังคับ ≥ 1 ไฟล์)**, completeness_pct (computed) — ✅ **ไม่มีเครื่องมือสร้าง/พิมพ์สัญญาในระบบ** เป็น "ทะเบียนข้อมูลสัญญา" ที่ต้องกรอกครบ + แนบไฟล์สัญญาจริง (PDF/รูป) · ข้อมูลไม่ครบ = สร้างตารางงวด (schedules) ไม่ได้ และขึ้นใน Data health |
| `schedules` | contract_id, period, due_date, expected_amount, txn_type, draft_entry_id, status(`upcoming`/`drafted`/`approved`/`received`/`overdue`/`waived`) |

**พอร์ตลงทุน (Stock/ETF/Fund/Crypto/Gold)** ✅ ถือโดย **Thanakorn คนเดียวทั้งหมด** → ฟอร์มตั้ง owner = Thanakorn เป็นค่าเริ่มต้นและล็อกไว้ (ปลดล็อกได้ในหน้า Config ถ้าอนาคตเปลี่ยน) · หน้า Investment ไม่ต้องมีตัวกรองเจ้าของ

**NAV** = Σ มูลค่าล่าสุดของ asset (ราคาตลาด ถ้ามี, ไม่งั้น cost) + เงินสด − หนี้สิน → แสดงแยก Entity และ Consolidated (ตัด intercompany)

### 4.4 โมดูลอื่น

| ตาราง | ใช้ใน |
|---|---|
| `contacts` (type[]: agent, tenant, seller, buyer, investor, borrower, contractor/ช่าง, supplier, other), `contact_links` (contact ↔ asset/contract/deal) , `activities` (call/meeting/note) | CRM |
| `listings` (property ที่รับฝาก: owner_contact, agent_contact, type ขาย/เช่า, price, received_date, **age_days = today − received_date** (computed), status, exclusive, commission_rate, photos, source_url) | Broker Portal |
| `invest_articles` (title, summary_th, tickers[], asset_class, sources[{title,url}], generated_by_model, published_at, pinned, reviewed_by) | Investment Tips |
| `reimbursements` (requester, owner_id ที่จะเบิกจาก, amount, category, receipt_urls[], slip_urls[], ocr_json, status: `submitted → approved → paid` / `rejected`, draft_entry_id) | เบิกจ่าย |
| `employees`, `positions`, `departments`, `kpi_templates`, `kpi_reviews`, `payroll_runs`, `payroll_lines` | HR |
| `boards` (type: `deal` / `ticket`), `board_stages` (config), `board_fields` (custom property config), `cards` (title, board_id, stage_id, priority, assignee, **start_date, duration_days, due_date**, value, asset_id, contact_id, listing_id, custom jsonb), `card_comments`, `card_attachments` | Kanban / Ticket / Gantt |
| `team_events` (หรือ sync Google Calendar) | Schedule ทีม |
| `app_users` (auth uid, owner_id ถ้าเป็นคนในครอบครัว, **role**), `role_permissions`, `settings` (key/value: llm_provider, llm_model, api keys อ้างอิง Vault, price sources, month-close date) | Config |

---

## 5. Entity Policy — เลือกเจ้าของตอนคีย์ + กติกา Corporate / Personal

### 5.1 ไม่มีเกณฑ์ตายตัว ✅ ตัดสินแล้ว
ตอนสร้างทรัพย์/สัญญา/รายการ ผู้คีย์ **เลือก owner เอง** พร้อมกรอกรายละเอียด ระบบแสดง "แนวทางปกติ" เป็นข้อความช่วย (ไม่บังคับ):

| ธุรกรรม | แนวทางปกติของ SRI |
|---|---|
| ขายฝาก ทรัพย์เล็ก | บุคคล |
| ขายฝาก ทรัพย์ใหญ่ · จำนอง | SRI Corporation |
| ถืออสังหาฯ เล็ก / ใหญ่ / ใหญ่มาก | บุคคล / SRI Corporation / SRI Holding |
| ค่าบริการ เล็กน้อย | บุคคล |
| ค่าบริการ มาก / จากนิติบุคคล / มี VAT | SRI Corporation |

ฟิลด์บังคับตอนเลือก owner: **เหตุผลการเลือก** (dropdown: ขนาดทรัพย์ / ผู้ลงนามสัญญา / แหล่งเงินทุน / ผู้จ่ายเป็นนิติบุคคล / อื่นๆ + ข้อความ) และ **แหล่งเงิน** (บัญชีไหน) — เก็บไว้เป็นหลักฐานเวลาตรวจสอบ

### 5.2 Corporate = เข้ม 100% (`policy = corporate_strict`)
| กติกา | บังคับที่ |
|---|---|
| ทุกรายการต้องมี: วันที่เอกสาร, เลขที่เอกสาร, คู่ค้า (contact), ประเภทจากผังที่อนุมัติแล้ว, **ไฟล์หลักฐาน** (ใบแจ้งหนี้/ใบเสร็จ/สัญญา/สลิป) | Zod + DB constraint |
| ห้ามหมวด "อื่นๆ" แบบไม่ระบุ · ห้าม override ใดๆ | UI + DB |
| รายการที่ post แล้ว **แก้ไม่ได้** → Reverse + ลงใหม่เท่านั้น | DB trigger |
| ปิดงวดแล้วล็อกถาวร (แก้ย้อนหลังไม่ได้ ต้องปรับปรุงในงวดปัจจุบัน) | DB trigger |
| รายการข้าม owner ต้องระบุลักษณะ (เงินทดรอง / กู้ยืม / เพิ่มทุน / ปันผล) + สร้างขาอีกฝั่งอัตโนมัติ | ledger engine |
| ช่อง VAT/ใบกำกับภาษี สำรองไว้ (เฟส 2) · map `peak_code` ให้ตรง PEAK | schema |

### 5.3 Personal = ยืดหยุ่น แต่ "เงินห้ามหาย" (`policy = personal_flexible`)
**Override ได้** (ต้องใส่เหตุผล + บันทึก audit):
- ไม่แนบหลักฐานได้ (ขึ้นเตือนใน Data health)
- ใช้หมวด "อื่นๆ" / ไม่ผูกคู่ค้าได้
- แก้รายการที่ post แล้วในงวดที่ยังไม่ปิด → เบื้องหลังระบบทำ reverse + ลงใหม่ให้อัตโนมัติ (ผู้ใช้เห็นเป็น "แก้ไข" แต่ประวัติเงินไม่หาย)
- ลงย้อนหลังได้ · เปิดงวดที่ปิดแล้วได้ (เฉพาะ Management)

**ห้าม override เด็ดขาด — Money Invariants (ทั้ง Corporate และ Personal)**:
1. ทุก transaction สมดุล (เงินเข้า = เงินออก ในมุมบัญชีคู่)
2. ทุกการเคลื่อนไหวเงินสดต้องผูก `bank_account` หรือ "กระเป๋าเงินสด" ที่มีตัวตน — ไม่มีเงินลอย
3. โอนระหว่างบัญชี/ข้าม owner ต้องมี **2 ขาเสมอ** (ขาออก + ขาเข้า) ระบบสร้างคู่ให้
4. **ห้าม DELETE** — มีแต่ void/reverse ที่เห็นร่องรอย
5. **กระทบยอดธนาคาร** รายสัปดาห์/ก่อนปิดเดือน: ยอดในระบบ vs ยอด statement ต่อบัญชี · ถ้าต่าง → ปิดเดือนไม่ได้ จนกว่าจะหาเจอ หรือ (Personal เท่านั้น) ลง "รายการปรับปรุงผลต่าง" พร้อมเหตุผล ซึ่งจะแสดงเป็นบรรทัดแยกให้เห็นชัดใน PL/CF
6. Consolidated ต้องตัด intercompany แล้วยอดเงินสดรวม = ผลรวมยอดธนาคารทุกบัญชีเสมอ (`fn_health_check`)

> ⚠ **ต้องยืนยันกับนักกฎหมาย/ผู้สอบบัญชี**: การแยกถือทรัพย์/รับรายได้ระหว่างบุคคลกับบริษัทต้องมีเหตุผลทางธุรกิจจริง **ไม่ใช่การแบ่งรายได้เพื่อหลบเกณฑ์ VAT** — ระบบมีรายงาน "รายได้ค่าบริการสะสม 12 เดือนต่อบุคคล" เตือนเมื่อเข้าใกล้เกณฑ์ VAT เพื่อให้ตัดสินใจอย่างถูกต้อง

---

## 6. หน้าจอและฟังก์ชัน (PC/Tablet = ครบ · Mobile = เร็ว)

รูปแบบ nav: **PC/Tablet** = sidebar ซ้าย + top bar (ตัวเลือก Entity + เดือน) · **Mobile** = bottom tab 5 ปุ่ม: `หน้าแรก · อนุมัติ · + บันทึก · บอร์ด · เมนู`

### 6.1 Dashboard (หน้าแรก)

Top bar: **เลือกเดือน (◀ ก.ย. 2026 ▶)** · เลือก Entity (Consolidated / SRI Corp / Holding / Capital / รายบุคคล) · เปรียบเทียบ (เดือนก่อน / ปีก่อน)

| แถว | Widget | รายละเอียด |
|---|---|---|
| 1 KPI | **NAV** · Total Assets · Liabilities · Equity | ตัวเลขใหญ่ + % เปลี่ยน + sparkline 12 เดือน |
| 2 KPI | **PL เดือนนี้** (Income − Expense) · **Net Cashflow +/−** (Op/Inv/Fin) · **Passive Income/เดือน** (actual vs forecast vs เป้า 1M→5M→10M) | แถบ progress สู่เป้า |
| 3 | **ค้างรับ (AR)** · **ค้างจ่าย (AP)** แยก aging 0–30/31–60/61–90/90+ | คลิกเข้า list |
| 4 | **Asset allocation** (donut ตาม class/category) · **Asset Management: Active / Inactive / ทรัพย์ไม่มีรายได้** | |
| 5 | **To-do Priority (AI แนะนำ)** — รวมจาก: schedule ค้างรับ, สัญญาใกล้หมด, ช่วงส่ง Notice ขายฝาก, deadline ไถ่ถอน, คิวอนุมัติ, card เลยกำหนด, ราคาเก่า | แต่ละข้อมีเหตุผล 1 บรรทัด + ปุ่ม "สร้าง Card" / "มอบหมาย" |
| 6 | **Schedule ทีม** (สัปดาห์นี้) · **Contract Watch** (หมดสัญญา 90 วัน, notice window) | |
| 7 (เพิ่มที่แนะนำ) | **Cash runway** (เงินสดพร้อมใช้ ÷ ค่าใช้จ่าย/เดือน) · **Concentration risk** (ทรัพย์/ลูกหนี้รายใหญ่สุด % ของ NAV) · **Yield ต่อทรัพย์เทียบเป้า 6.5%** · **Pipeline value** จาก Kanban · **Data health** (รายการยังไม่แนบหลักฐาน, ยอดธนาคารไม่กระทบ จาก `fn_health_check`) | |

Mobile: เหลือ NAV · PL · Net CF · ค้างรับ/จ่าย · To-do 5 ข้อแรก · ปุ่มคิวอนุมัติ (badge ตัวเลข)

**AI To-do logic**: rule-based คะแนนก่อน (เงิน × ความเร่งด่วน × ความเสี่ยงกฎหมาย) → ส่ง Top 20 ให้ LLM เรียงและเขียนเหตุผลภาษาไทย → cache รายวัน (ประหยัด token, ถ้า AI ล่ม rule-based ยังใช้ได้)

### 6.2 Ledger (สมุดบัญชี)

**Tab 1 · รายการ (Transactions)** — Grid แบบ Sheet
- Filter: เดือน/ช่วง, Entity, บุคคล (ชื่อ), บัญชีธนาคาร, กลุ่ม (Income/Expense/Investing/Financing/Transfer), asset, สถานะ (ค้าง/จ่ายแล้ว)
- ปุ่ม **+ บันทึกรายการ** (manual key): เลือกประเภท → ฟอร์มปรับตามประเภท (ถ้า Investing บังคับเลือก asset; ถ้าขาย ระบบคำนวณ gain/loss ให้เห็นก่อนยืนยัน)
- ปุ่ม Import CSV/xlsx (statement ธนาคาร) → จับคู่ → เข้าคิว draft
- แถวคลิกแล้วเห็น: คู่บัญชีที่ระบบลง (ซ่อน Dr/Cr ใช้คำว่า "เงินเข้า/เงินออก/เพิ่ม/ลด"), ไฟล์แนบ, history, ปุ่ม **Void/Reverse**
- Mobile: ฟอร์มบันทึกเร็ว 4 ขั้น (ประเภท → จำนวน → บัญชี → ถ่ายสลิป) + list 30 วันล่าสุด

**Tab 2 · ยืนยันรับ/จ่าย (Cash Control)**
- แสดงรายการที่ `cash_date` ว่าง (AR/AP) จัดกลุ่มตาม **บัญชีธนาคารที่ตั้ง Config ไว้**
- ต่อแถว: ยอดที่คาด · ยอดจริง (แก้ได้ รองรับรับบางส่วน) · วันที่จริง · แนบสลิป · ปุ่ม ✓ ยืนยัน
- Bulk confirm (ติ๊กหลายรายการ) + กล่องยืนยันเป็นประโยคเต็ม "ยืนยันรับเงิน 3 รายการ รวม 45,000 บาท เข้าบัญชี SRI - SCB ใช่หรือไม่"
- ส่วนต่าง → สร้าง draft ปรับปรุง (ค่าธรรมเนียม/ส่วนลด/ค้างเพิ่ม)

**Tab 3 · PL** — รายเดือน 12 คอลัมน์ · Entity/Consolidated · drill-down ถึงรายการ
**Tab 4 · Cashflow** — Direct method แยก Operating/Investing/Financing, ยอดยกมา-ยกไปต่อบัญชีธนาคาร, ตัด Transfer/Intercompany ในโหมด Consolidated

### 6.3 Balance Sheet / Asset Register

- มุมมอง 3 แบบสลับได้: **ตามหมวด** (tree: Class → Category → Asset) · **ตามเจ้าของ** · **Consolidated (ตัด intercompany)**
- โครงหมวด:
  - **Real Estate**: RE รอขาย · RE ปล่อยเช่า · RE รับจำนอง-ขายฝาก (บัญชีเป็นลูกหนี้ 1400/14xx) · RE Project · RE รอปรับปรุง
  - **Finance**: Business (SME equity) · Bond · Loan Agreement
  - **Investment**: Stock (TH/US) · ETF · Funds · Crypto · Gold
  - + เงินสดตามบัญชีธนาคาร / หนี้สิน (ธนาคาร, กู้ยืมกรรมการ, เงินมัดจำผู้เช่า) / Equity (ทุน, กำไรสะสม, ส่วนเกินมูลค่ายุติธรรมที่ยังไม่รับรู้)
- คอลัมน์: ทรัพย์ · เจ้าของ · ต้นทุน · มูลค่าปัจจุบัน · วันที่ราคา/แหล่ง · Unrealized G/L · Yield ต่อปี · สถานะ
- **เพิ่ม/ลด/แก้ทรัพย์ง่าย**: ปุ่ม + ทรัพย์ (wizard 3 ขั้น: หมวด → ข้อมูล → สัญญา/ตารางรับเงิน) · เปลี่ยนหมวดด้วย drag หรือ dropdown (เช่น รอปรับปรุง → ปล่อยเช่า) พร้อมเก็บประวัติสถานะ
- **Price update ทุกสัปดาห์** (จันทร์ 07:00): Edge Function ดึงราคา → `asset_valuations` → ถ้าดึงไม่ได้ ติดธง + แจ้งใน To-do · มีปุ่ม "อัปเดตราคาตอนนี้"
- ⚠ มูลค่าตลาดใช้แสดง NAV เพื่อบริหาร — **ไม่ใช่ตัวเลขงบตามกฎหมาย** (PEAK) ต้องมีป้ายบอกชัด

### 6.4 Asset Management (Auto Ledger ประจำเดือน)

- หน้า **Asset detail** (คลิกจาก list): ข้อมูลทรัพย์ · **ข้อมูลสัญญา (กรอกครบ + แนบไฟล์สัญญา PDF แทนการสร้างสัญญาในระบบ, มีตัวบอก "ข้อมูลครบ X%")** · ตารางงวด (schedule) · ประวัติรับเงิน · ค่าใช้จ่าย/รีโนเวท · yield จริง vs เป้า · เอกสาร · **ผู้เช่า/ลูกหนี้ (คลิกเข้า Contact)** · card ที่เกี่ยวข้อง
- **Auto Ledger**: วันที่ 25 ของทุกเดือน (ตั้งค่าได้) `pg_cron` สร้าง draft ของเดือนถัดไปจาก contracts ที่ active → ค่าเช่า, ดอกเบี้ยขายฝาก/จำนอง/เงินกู้, ค่าส่วนกลาง, ภาษี, ค่าประกัน
- **หน้าอนุมัติ (Bulk)**: ตาราง draft ติ๊กทั้งหมด/รายตัว · แก้ยอดก่อนอนุมัติได้ · ปุ่ม `อนุมัติที่เลือก` / `ยกเลิก (ใส่เหตุผล)` / `เลื่อนงวด` → อนุมัติแล้วเข้า Ledger เป็น "ค้างรับ" รอ Tab ยืนยันรับเงิน
- Mobile: swipe ขวา = อนุมัติ, ซ้าย = ยกเลิก (มี undo 5 วินาที)
- **Tenant/Borrower database**: list ผู้เช่าทั้งหมด + สถานะจ่าย (ตรง/ช้า/ค้าง) + วันหมดสัญญา + เงินมัดจำที่ถืออยู่

### 6.5 Broker Portal

- ทรัพย์ที่รับฝากขาย/เช่า (ไม่ใช่ทรัพย์เรา — แยกตาราง `listings` ไม่เข้า Balance Sheet)
- Card/Grid: รูป · ชื่อ · ขาย/เช่า · ราคา · ทำเล · เจ้าของ (contact) · **วันที่รับฝาก · อายุ (วัน)** ป้ายสี: <30 เขียว / 30–90 เหลือง / >90 แดง · Exclusive? · ค่าคอม
- Action: ส่งต่อเป็น Deal card · จับคู่กับ Contact ที่เป็นผู้ซื้อ/ผู้เช่า (filter ตามงบ/ทำเล) · สร้างลิงก์แชร์ listing (เฟส 2)
- ปิดดีล → สร้าง draft Income ค่านายหน้า (เข้า Entity ตามกฎหัวข้อ 5)

### 6.6 Investment Portal (Tips)

- Feed บทความสั้น (150–300 คำภาษาไทย) + **ลิงก์อ้างอิงทุกบทความ** + tag ticker/asset class + ป้าย "AI-generated · ยังไม่ได้ตรวจ" / "ตรวจแล้วโดย ___"
- Pipeline: สัปดาห์ละ 2 ครั้ง Edge Function ดึง RSS/ข่าวที่กำหนดในหน้า Config (เช่น SET news, ประกาศ ธปท., ข่าว ticker ที่ถืออยู่) → LLM สรุป → **draft** → ลูกพี่กด Publish (หรือ auto-publish ถ้าตั้งไว้)
- ผูกกับ portfolio: บทความที่เกี่ยวกับ ticker ที่เราถือขึ้นก่อน
- ⚠ ข้อความทุกบทความ: "ข้อมูลเพื่อประกอบการตัดสินใจภายใน ไม่ใช่คำแนะนำการลงทุน" · ห้ามดึงเนื้อหาเต็มจากเว็บที่มีลิขสิทธิ์ ใช้สรุป + ลิงก์เท่านั้น

### 6.7 Contacts (CRM)

- ประเภท (เลือกได้หลายแท็ก): เอเจนต์ · ผู้เช่า · ผู้ขาย · ผู้ซื้อ · นักลงทุน · ผู้กู้/ผู้ขายฝาก · ช่าง/ผู้รับเหมา · supplier · ทนาย/บัญชี
- หน้า Contact: ข้อมูล, LINE ID, ความสัมพันธ์ (ทรัพย์/สัญญา/ดีล/listing), timeline กิจกรรม, ยอดค้างรับ/จ่ายกับคนนี้, rating (ช่าง: คุณภาพ/ราคา/ตรงเวลา)
- ข้อมูลส่วนบุคคล (บัตรประชาชน, สำเนาเอกสาร) → เก็บ Storage แบบ private, เห็นเฉพาะ role Management · ⚠ PDPA: ต้องมีเหตุผลการเก็บและระยะเวลาเก็บ (ยืนยันกับนักกฎหมาย)

### 6.8 เบิกจ่ายเงินสำรอง (Reimbursement)

Flow: `ผู้ใช้ส่งคำขอ (แนบบิล) → Management อนุมัติ → โอนจ่ายจริงที่ธนาคาร → แนบสลิปโอน (ยืนยันจ่าย) → Post เข้า Ledger`
- Mobile-first: ถ่ายรูปบิล/ใบเสร็จ → **AI OCR** ดึง ร้าน/วันที่/ยอด/เลขผู้เสียภาษี → ผู้ใช้ตรวจ → ส่ง
- เลือก: เบิกจาก Entity ไหน · ผูก asset/project (เช่น ค่าช่างทรัพย์ Iris 235) · หมวดค่าใช้จ่าย
- กันซ้ำ: เตือนถ้ายอด+วันที่+ร้านซ้ำกับรายการเดิม
- Tab สำหรับ Finance: รอจ่าย · จ่ายแล้ว · ยอดสำรองคงค้างรายคน

### 6.9 HR (Performance / KPI / Org / Payroll)

- **People**: ข้อมูลพนักงาน, ตำแหน่ง, หัวหน้า (`reports_to`), วันเริ่มงาน, สังกัด Entity (จ่ายเงินเดือนจากไหน), เงินเดือน (เห็นเฉพาะ Management)
- **Positions**: JD สั้น + KPI template ต่อตำแหน่ง (น้ำหนักรวม 100%)
- **KPI Review**: รอบรายไตรมาส · self-score + manager-score · สรุปคะแนน/เกรด · ข้อความ feedback
- **Org Chart**: auto-generate จาก reports_to (react-flow) คลิกดูคน/ตำแหน่ง · แสดงตำแหน่งว่างที่ลูกพี่อยากจ้าง (คนขับรถ, เลขา, HR, แอดมินตัดต่อ, deal sourcing) เป็นกล่องเส้นประ
- **Payroll run** รายเดือน: ระบบดึงเงินเดือน+รายการเพิ่ม/หัก → **draft ต่อคน** → อนุมัติ bulk → เข้า Ledger เป็น Expense (เงินเดือน) + ค้างจ่าย → ยืนยันจ่ายใน Tab Cash Control
- ⚠ MVP **ไม่คำนวณ ภ.ง.ด.1 / ประกันสังคม อัตโนมัติ** — ใส่เป็นช่องกรอกเอง (เฟส 2 ทำ calculator) และต้องยืนยันอัตรากับผู้ทำบัญชี

### 6.10 Kanban Board + Ticket + Gantt

**Board หลายกระดาน (config ได้)**
1. **Deal Pipeline** — ขั้นเริ่มต้น: `Open → On Process → Close (Won/Lost)` (เพิ่ม/ลด/เปลี่ยนชื่อขั้นได้)
2. **Tickets** *(ฟังก์ชันที่ลูกพี่เพิ่ม)* — `Open → In Progress → Waiting → Resolved → Closed`

**Open Ticket** — ช่องทางเปิด:
- ปุ่ม **+ Ticket** ในบอร์ด / จาก Asset detail ("แจ้งซ่อม") / จาก Contact (ผู้เช่าแจ้งปัญหา) / จาก To-do บน Dashboard / (เฟส 2) ผู้เช่าแจ้งผ่าน LINE OA → เปิด ticket อัตโนมัติ
- ฟิลด์: หัวเรื่อง · ประเภท (ซ่อมบำรุง / เอกสาร-สัญญา / การเงิน / ผู้เช่าร้องเรียน / IT-ระบบ / อื่นๆ — config ได้) · ความสำคัญ (P1–P4) · ทรัพย์ · ผู้แจ้ง (contact) · ผู้รับผิดชอบ · ช่าง (contact) · **SLA/Due date** · รูป/ไฟล์ · ค่าใช้จ่ายประมาณ
- ปิด ticket ที่มีค่าใช้จ่าย → ปุ่ม "สร้างรายการค่าใช้จ่าย" → draft Expense ผูกทรัพย์ (หรือ Investing ถ้าเป็นปรับปรุงใหญ่)
- ตัวชี้วัด: ticket เปิดค้าง, เกิน SLA, เวลาเฉลี่ยปิดงาน, ต้นทุนซ่อมต่อทรัพย์

**Card ทุกบอร์ด**: title · assignee · priority · **start_date · duration (วัน) · due_date** (กรอก 2 ใน 3 ระบบคำนวณตัวที่ 3) · มูลค่าดีล · link asset/contact/listing · checklist · comments · ไฟล์
**Custom Properties (หน้า Config)**: เพิ่มฟิลด์ต่อบอร์ด (text/number/date/select/person/money) — เก็บใน `cards.custom jsonb`
**มุมมอง**: Kanban · Table · **Gantt** (frappe-gantt ลากเลื่อนวันได้) · Calendar (เฟส 2)
Mobile: list ตามขั้น + ปุ่มเลื่อนขั้น (ไม่ใช้ drag บนมือถือ)

### 6.11 Settings / Config

| หมวด | ตั้งค่าได้ |
|---|---|
| **ผู้ใช้** | เชิญด้วย email · กำหนด role · ผูกผู้ใช้กับ owner (คนในครอบครัว) · ปิดใช้งาน |
| **Role** | `User` · `Manager` · `Management` (+ `Viewer/Auditor` แนะนำเพิ่ม สำหรับผู้สอบบัญชีที่ดูอย่างเดียว) · ไม่มีวงเงินอนุมัติ |
| **Entity & บัญชีธนาคาร** | เพิ่ม/ลด/เปลี่ยนชื่อ/Active-Inactive/เรียงลำดับ (seed: SRI-SCB ✓, SRI-BBL ✗, SRI-BAY ✗, Thanakorn-BBL 888 ✓, Thanawin-KBANK ✓, Thanawin-BBL ✓, Benjaporn-BBL ✓) |
| **ผังบัญชี & ประเภทรายการ** | แก้ชื่อ, map peak_code, เปิด/ปิด (ห้ามลบถ้ามีรายการใช้แล้ว) |
| **หมวดทรัพย์** | Class/Category เพิ่มลดได้ |
| **Routing rules** | เกณฑ์ X/Y/Z/W หัวข้อ 5 |
| **Board** | ขั้น Kanban, custom fields, ประเภท ticket, SLA ต่อ priority |
| **Automation** | วันที่สร้าง auto ledger, วัน/เวลาอัปเดตราคา, แหล่งราคา, แหล่งข่าวบทความ, เปิด/ปิดแต่ละ job |
| **AI / LLM** | Provider (Claude / OpenAI / Gemini) · Model · API key (เก็บใน Supabase Vault ไม่เก็บเป็นข้อความ) · งบ token/เดือน · ทดสอบการเชื่อมต่อ |
| **แจ้งเตือน** | LINE Notify ผ่าน LINE OA / email: ใครได้รับเรื่องอะไร |
| **เป้าหมาย** | Passive income target (1M/5M/10M), yield target 6.5%, ปีบัญชี |
| **ปิดงวด** | Lock เดือน (หลังล็อก แก้ย้อนหลังไม่ได้ ต้อง reverse ในเดือนปัจจุบัน) |
| **Import/Export** | Excel ตั้งต้น, export PL/CF/BS เป็น xlsx/PDF |

---

## 7. Automation Jobs (MVP)

| Job | เวลา | ทำอะไร | ผลลัพธ์ |
|---|---|---|---|
| `schedules-monthly` | ทุกวันที่ 25, 06:00 | สร้าง draft รายรับ/จ่ายเดือนหน้า จาก contracts | คิวอนุมัติ + แจ้ง LINE |
| `payroll-draft` | ทุกวันที่ 25 | draft เงินเดือน | คิวอนุมัติ |
| `prices-weekly` | จันทร์ 07:00 | ดึงราคา หุ้น/กองทุน/crypto/ทอง/FX | asset_valuations |
| `ar-aging-daily` | ทุกวัน 08:00 | อัปเดตสถานะ overdue, สัญญาใกล้หมด, notice window | To-do + แจ้งเตือน |
| `ai-todo-daily` | ทุกวัน 08:15 | จัดลำดับ To-do + เหตุผล | Dashboard |
| `invest-digest` | จันทร์/พฤหัส 09:00 | สรุปข่าว → draft บทความ | Investment Portal |
| `health-check-nightly` | ทุกคืน 02:00 | `fn_health_check()` กระทบยอด CF vs ยอดธนาคาร, draft ค้างนาน, รายการไม่มีหลักฐาน | Data health widget |
| `backup-weekly` | อาทิตย์ | export DB → Storage/Drive | (Supabase PITR ใช้แผน Pro) |

Implementation: `pg_cron` เรียก Edge Function · ทุก job เขียน `job_runs` (เริ่ม/จบ/error) ดูได้ในหน้า Config

---

## 8. สิทธิ์การใช้งาน (RLS)

**หลักการ ✅ ตัดสินแล้ว**: ไม่มีวงเงินอนุมัติในระบบ (การอนุมัติจ่ายเงินจริงเกิดที่ธนาคาร) · **ทุกคนสร้างรายการได้** · ระบบทำหน้าที่ "ด่านตรวจก่อนเข้า Ledger"

```
User / Manager สร้างรายการ ──► pending ──► Management อนุมัติ ──► Ledger (posted)
Management สร้างรายการ ──────► [ข้ามขั้น] ติ๊ก "บันทึกเข้า Ledger ทันที" ──► Ledger
Management เปิดคิว pending ────► อนุมัติทีละตัว / Bulk ──► Ledger
```

| ความสามารถ | User | Manager | Management |
|---|---|---|---|
| สร้างรายการ Ledger / เบิกจ่าย / Ticket | ✓ → pending | ✓ → pending | ✓ → post ตรงได้ (ข้ามขั้น) |
| **อนุมัติเข้า Ledger** | ✗ | ✗ | ✓ ทีละตัว / Bulk |
| ยืนยันรับ/จ่ายเงิน (แนบสลิป) | ✓ → pending | ✓ → pending | ✓ |
| Void/Reverse · เปิดงวดที่ปิด (Personal) | ✗ | ✗ | ✓ |
| ดู Dashboard / รายงาน | งานของตัวเอง | Entity ที่ได้รับมอบ (ไม่เห็น Personal ของคนอื่น) | ทั้งหมด + Consolidated |
| ดูฝั่ง Personal | ✗ | เฉพาะของตัวเอง (ถ้าผูก owner) | ✓ |
| เงินเดือน/HR | ของตัวเอง | ทีมตัวเอง (ไม่เห็นเงินเดือน) + ให้คะแนน KPI ทีม | ✓ |
| Kanban/Ticket/Contacts/Broker | ✓ | ✓ + จัดการบอร์ด/มอบหมายงาน | ✓ |
| Settings | ✗ | บอร์ด/หมวดงาน | ✓ ทั้งหมด (ผู้ใช้, role, บัญชี, LLM) |

แนวทางมอบบทบาทเริ่มต้น (แก้ได้): ลูกพี่ = Management · อากง = Management (โหมดดูเป็นหลัก, UI ตัวใหญ่) · มาวิน = Manager (งานอสังหาฯ มี checklist) · แพทตี้ = User หรือ Manager ตามงานที่รับ · ผูกผู้ใช้กับ owner Personal: Thanakorn / Thanawin / Benjaporn

---

## 9. UI / Theme (Stripe-like × SRI CI)

**Design tokens**
```
--brand-600: #004AAD   (สีโลโก้ ปุ่มหลัก ลิงก์)
--brand-700: #003A8A   (hover)
--brand-50:  #EEF4FC   (พื้นเน้น)
--ink-900:   #0A2540   (ตัวอักษรหลัก แบบ Stripe)
--ink-500:   #425466   (ตัวอักษรรอง)
--line:      #E3E8EE   (เส้นขอบการ์ด)
--bg:        #F6F9FC   (พื้นหลังแอป)
--pos:       #0E9F6E   (เงินเข้า/บวก)   --neg: #DF1B41 (เงินออก/ลบ)   --warn: #F5A524
radius 10px · เงาบาง 0 1px 3px rgba(10,37,64,.08) · ตัวเลขใช้ tabular-nums
Font: IBM Plex Sans Thai (ไทย+อังกฤษ), ตัวเลขเงิน IBM Plex Sans Thai tabular
```
- โลโก้: วาฬ SRI (`Logo/4.png` สำหรับ sidebar/favicon, `Logo/3.png` หน้า login) — แนะนำให้ทำ **SVG** จากโลโก้เพื่อความคม
- Dark mode: เฟส 2
- **Accessibility (ผู้สูงอายุ)**: ตัวอักษร ≥ 18px (โหมด "ตัวใหญ่" 20px ต่อผู้ใช้), ปุ่ม ≥ 52px มีป้ายข้อความเสมอ (ไม่ใช้ไอคอนอย่างเดียว), แยก **โหมดดู/โหมดแก้ไข**, กล่องยืนยันเป็นประโยคเต็ม, คอนทราสต์ ≥ 4.5:1
- **Responsive**: Desktop ≥1280 (sidebar + grid เต็ม) · Tablet 768–1279 (sidebar ยุบเป็นไอคอน+ป้าย, grid เลือกคอลัมน์) · Mobile <768 (bottom tab, การ์ดแทนตาราง, ฟอร์มทีละขั้น, ปุ่มลอย + บันทึก)
- รูปแบบตัวเลข: `฿ 1,234,567` · ติดลบ `(12,000)` สีแดง · ย่อ `12.5M` ใน KPI · วันที่ `DD/MM/YYYY` ค.ศ.

---

## 10. MVP Scope & แผน Sprint

### ใน MVP ✓
Dashboard · Ledger (4 tabs) · Balance Sheet/NAV + weekly price · Asset Mgmt + auto ledger + bulk approve · Contacts · Reimbursement (มี OCR) · Kanban Deal + **Ticket** + Gantt · HR (people/position/KPI/org chart/payroll draft) · Broker Portal (basic) · Investment Tips (draft+publish) · Settings · LINE/email แจ้งเตือน · Import Excel ตั้งต้น

### เลื่อนไปเฟส 2 ✗
VAT/ใบกำกับภาษี/ภ.พ.30 ฝั่งบริษัท · ภ.ง.ด./ประกันสังคมอัตโนมัติ · Bank statement auto-match · LINE OA รับดีลขายฝาก/แจ้งซ่อมจากผู้เช่า · Google Sheet sync ออก · PEAK export · Dark mode · Portal ภายนอก (ผู้เช่า/นักลงทุน) · Depreciation · Multi-currency เต็มรูป

### 10.1 ประเมินความยาก — ทำเสร็จใน 3 วันได้ไหม?

**คำตอบตรงๆ: MVP ครบ 11 โมดูลใน 3 วัน "ไม่ได้" แบบที่เชื่อตัวเลขได้ · แต่ "SRI OS Core" ที่ใช้งานจริงได้ใน 3 วัน "ได้" ถ้าข้อมูลตั้งต้นพร้อมก่อนวันที่ 1**

Agent เขียนโค้ดได้เร็ว แต่ 3 อย่างนี้เร่งไม่ได้: (1) ข้อมูลตั้งต้นที่กระทบยอดแล้ว (2) ลูกพี่ต้องตรวจว่าแต่ละประเภทรายการลงบัญชีถูก (3) ทดสอบกับข้อมูลจริง ถ้าข้าม 3 ข้อนี้จะได้ระบบที่ "ดูสวยแต่ตัวเลขผิด" ซึ่งแย่กว่า Excel

| โมดูล | ความยาก (1–5) | เวลาโดย Agent Team* | ความเสี่ยงหลัก |
|---|---|---|---|
| Foundation (repo, auth, roles, RLS, design tokens) | 2 | 0.5 วัน | RLS รั่วข้อมูล Personal |
| **Ledger engine** (txn types, double-entry, triggers, invariants, void) | **5** | 1 วัน | กฎบัญชีผิด = ทุกหน้าผิด |
| Approval queue + Cash Control | 3 | 0.5 วัน | |
| Assets + Balance Sheet + NAV + ราคาฟรี | 4 | 1 วัน | ข้อมูลตั้งต้น, แหล่งราคาพัง |
| PL / Cashflow / Consolidated | 4 | 0.5 วัน | ตัด intercompany |
| Excel import (opening balance) | 4 | 0.5 วัน | ข้อมูลไม่สะอาด (34.6M) |
| Dashboard v1 | 3 | 0.5 วัน | |
| Contracts + schedules + Auto ledger รายเดือน | 4 | 1.5 วัน | งวด/วันครบกำหนดขายฝาก |
| Kanban Deal + Ticket + Gantt + custom fields | 3 | 1.5 วัน | |
| Contacts CRM | 2 | 1 วัน | PDPA |
| Reimbursement + OCR | 3 | 1 วัน | OCR ภาษาไทย |
| HR + Org chart + Payroll draft | 3 | 1.5 วัน | ข้อมูลเงินเดือนลับ |
| Broker Portal | 2 | 1 วัน | |
| Investment Tips (AI digest) | 2 | 1 วัน | ลิขสิทธิ์เนื้อหา |
| AI To-do priority | 3 | 0.5 วัน | |
| LINE/email แจ้งเตือน | 2 | 0.5 วัน | |
| Mobile polish + Playwright 3 จอ + UAT/แก้บั๊ก | 3 | 3 วัน | |
| **รวม** | | **≈ 17–18 วันทำงาน ≈ 3–4 สัปดาห์** | |

\* สมมติฐาน: ลูกพี่ว่าง review/ตัดสินใจ 2–3 ชม./วัน, ข้อมูลตั้งต้นพร้อม, ใช้ Claude Code แผน Max และ Agent Team ในหัวข้อ 11 · ตัวเลขเป็นการประเมิน ไม่ใช่คำสัญญา

### 10.2 แผน 3 วัน — "SRI OS Core"

| วัน | ส่งมอบ | ลูกพี่ต้องทำ |
|---|---|---|
| **Day 0 (ก่อนเริ่ม)** | – | เตรียมข้อมูล + บัญชีบริการตาม Checklist หัวข้อ 12.1 · **เคลียร์ผลต่าง 34.6M** |
| **Day 1 · Foundation + Ledger engine** | Repo + CLAUDE.md + Agent Team · Supabase `sri-os` · schema หลัก · seed owners (3 บริษัท + Thanakorn/Thanawin/Benjaporn) · 7 บัญชีธนาคาร · ผังบัญชี · ประเภทรายการ · triggers + Money Invariants + unit test · Login 3 role | ตรวจตาราง "ประเภทรายการ → ลงบัญชียังไง" (1 ชม.) |
| **Day 2 · Ledger UI + Assets/BS** | หน้า Ledger (บันทึก / คิวอนุมัติ / ยืนยันรับ-จ่าย / PL / CF) · Asset register + หมวด · Balance Sheet 3 มุมมอง + NAV · Import Excel opening balance | ตรวจยอด BS ในระบบเทียบ Excel ต่อ owner (1–2 ชม.) |
| **Day 3 · Dashboard + Deploy + UAT** | Dashboard v1 (NAV/Assets/Liab/Equity/PL/CF/AR-AP/Allocation) · ราคาฟรีรายสัปดาห์ · Mobile: บันทึกเร็ว + อนุมัติ · Settings (ผู้ใช้/role/บัญชี) · Deploy Vercel | ลองคีย์รายการจริง 1 วัน + อนุมัติ + ปิดกล่องบั๊ก (2–3 ชม.) |

### 10.3 หลัง 3 วัน (Sprint ต่อ ~1 สัปดาห์/sprint)

| Sprint | ส่งมอบ | Definition of Done |
|---|---|---|
| **S2 · Asset Automation** | Contracts, schedules, Auto ledger รายเดือน + bulk approve, AR/AP aging, Contract watch, Tenant database | draft ต.ค. 2026 ออกครบทุกสัญญา ตรงกับ Excel Schedule |
| **S3 · Work & People** | Kanban Deal + **Ticket** + Gantt, Contacts CRM, Reimbursement + OCR, HR + Org chart + Payroll draft | ทีมใช้จริง 1 สัปดาห์ |
| **S4 · Intelligence & Polish** | AI To-do, Investment Tips, Broker Portal, LINE/email, Mobile polish, Playwright 3 ขนาดจอ | UAT ลูกพี่+อากง, go-live |

**Parallel run**: ใช้ Excel คู่กับระบบ 1 รอบเดือน (ต.ค. 2026) ก่อนเลิก Excel

---

## 11. วิธีทำงานกับ Claude Code (ให้แก้ได้ภายหลัง ต่อยอดได้)

1. **`CLAUDE.md`** ใส่: กฎเหล็ก 6 ข้อ (หัวข้อ 1), โครง repo, คำสั่ง `pnpm test`, กฎ migration (ห้ามแก้ไฟล์ migration เก่า), ภาษาไทยใน UI, token สี/ฟอนต์, หลักการ owner/entity
2. **ทำงานทีละ Sprint ด้วย Plan Mode** → อนุมัติแผน → ลงมือ → PR → ลูกพี่ดู preview URL ของ Vercel
3. **Custom slash commands / skills ใน `.claude/`**:
   - `/new-module <name>` — scaffold โมดูลตาม contract (route, zod schema, server actions, RLS policy, test)
   - `/new-txn-type` — เพิ่มประเภทรายการ + test คู่บัญชี
   - `/migration <desc>` — สร้างไฟล์ SQL + regenerate types
   - `/close-month-check` — รัน health check ก่อนปิดงวด
4. **Subagents**: ใช้ Jedi Council Agent Team (หัวข้อ 11.1)
5. **ADR** ทุกการตัดสินใจสำคัญ (`docs/decisions/`) — อีก 6 เดือนย้อนดูได้ว่าทำไมเลือกแบบนั้น
6. **Feature flags** ในตาราง `settings` — เปิดโมดูลใหม่ทีละคนก่อนปล่อยทั้งทีม
7. **Supabase branching** สำหรับทดสอบ migration ก่อนขึ้น production

### 11.1 Jedi Council — Agent Team ของ SRI OS (ปรับสำหรับ Claude Max: เร็ว + แม่นยำ)

หลักคิดใหม่ (มี Max แล้ว ข้อจำกัดไม่ใช่ค่า token แต่คือ **โควตาการใช้งานต่อรอบเวลา** และ **ความเร็ว**):
- **Opus = ทุกอย่างที่แตะเงิน / โครงสร้าง / ข้อมูล** (ผิดแล้วแพง ต้องแม่น)
- **Sonnet = งานสร้างหน้าจอและเชื่อมระบบ** (เร็ว คุณภาพสูงพอ)
- **Haiku = รัน-อ่าน-รายงานซ้ำๆ** (เร็วสุด ไม่ต้องคิดลึก)
- **ความเร็วมาจากการทำขนาน** — Agent ที่ไม่แตะไฟล์เดียวกันรันพร้อมกันใน git worktree แยก

| ชื่อ (สภาเจได) | ตำแหน่งในสภา → หน้าที่ใน SRI OS | Model | เหตุผลที่เลือก | Tools |
|---|---|---|---|---|
| **Main session (ลูกพี่คุยด้วย)** | Orchestrator — สั่งงาน รวมผล | **Opus** | ตัดสินใจแตกงานถูกตั้งแต่ต้น ลดงานแก้ | ทั้งหมด |
| **Yoda** | Grand Master → **Chief Architect** · schema, แตกงาน, ADR | **Opus** (thinking สูง) | ออกแบบผิด = รื้อทั้งระบบ | Read, Grep, Glob, Write (docs) |
| **Mace Windu** | Master of the Order → **Ledger & Compliance Guardian** · ตรวจทุก diff ที่แตะเงิน, Money Invariants, Corporate strict, RLS · **veto ได้** | **Opus** (thinking สูง) | ด่านสุดท้ายก่อนเงินผิด | Read, Grep, Glob, Bash (test) |
| **Plo Koon** | Master ผู้ดูแลกองกำลัง → **Ledger Engine & Data** · migrations, triggers, ledger engine (`lib/ledger`), Excel import, health check | **Opus** ⬆ | โค้ดตรงนี้คือหัวใจเงิน ต้องแม่น 100% | Read, Write, Edit, Bash, Supabase MCP |
| **Obi-Wan Kenobi** | อาจารย์หลัก → **Lead Full-stack** · หน้าจอ, server actions, ฟอร์ม, รายงาน | **Sonnet** | งานปริมาณมาก ต้องเร็ว · โค้ดเงินเรียกผ่าน `lib/ledger` ของ Plo Koon เท่านั้น | ทั้งหมด |
| **Luminara Unduli** | Master ผู้ละเอียด → **UI/UX & Accessibility** · design tokens, component, responsive 3 จอ, นำแบบจาก Claude Design มาทำเป็นโค้ด | **Sonnet** | งานภาพ/CSS เร็วและดีพอ | Read, Write, Edit, Bash (Playwright) |
| **Shaak Ti** | Master ระบบฝึก → **Integrations & DevOps** · Edge Functions, cron, price adapters, LINE/Resend, CI/CD, Vercel/Supabase env | **Sonnet** | งานเชื่อมต่อ มีรูปแบบชัด | Read, Write, Edit, Bash, WebFetch, Vercel MCP |
| **Ki-Adi-Mundi** | Master นักวิเคราะห์ → **QA Runner** · typecheck/lint/vitest/Playwright แล้วรายงานเฉพาะ fail (ไม่แก้โค้ด) | **Haiku** | รันซ้ำบ่อยที่สุด ต้องเร็วสุด | Read, Grep, Glob, Bash |
| **Kit Fisto** | Master ว่องไว → **Docs & Release Notes** · DATA_MODEL.md, CHANGELOG, สรุปงานรายวันภาษาไทย | **Haiku** | งานเขียนตามแม่แบบ | Read, Write, Edit, Grep |

> ถ้าโควตา Max ใกล้หมดในรอบนั้น: สลับ Main session เป็น Sonnet ชั่วคราว **แต่ห้ามลด Plo Koon / Mace Windu ลงจาก Opus**

**ตัวอย่างไฟล์** `.claude/agents/mace-windu.md`
```markdown
---
name: mace-windu
description: Ledger & Compliance Guardian. ใช้ทุกครั้งที่ PR หรือ diff แตะ lib/ledger, supabase/migrations, RLS policy หรือโค้ดที่สร้าง/แก้รายการเงิน ตรวจ double-entry, Money Invariants, Corporate strict policy และการ bypass draft pipeline
model: opus
tools: Read, Grep, Glob, Bash
---
คุณคือผู้ตรวจบัญชีของ SRI OS อ่าน docs/LEDGER_RULES.md และหัวข้อ 5 ของ docs/PLAN.md ก่อน
ตรวจเฉพาะ diff ที่ได้รับ ห้ามแก้โค้ด
ตอบกลับไม่เกิน 200 คำ รูปแบบ: VERDICT (PASS / BLOCK) → รายการปัญหา [ไฟล์:บรรทัด] → เหตุผลบัญชี 1 บรรทัดต่อข้อ
```

**Workflow ขนานเพื่อความเร็ว (ต่อ 1 feature)**
```
Yoda (แผน + สัญญา interface ระหว่างงาน)
  ├─► Plo Koon   (worktree A: migration + lib/ledger)      ┐
  ├─► Obi-Wan    (worktree B: หน้าจอ + server actions)       ├ ขนานกัน
  ├─► Luminara   (worktree C: components ตาม Claude Design) │
  └─► Shaak Ti   (worktree D: job / integration)           ┘
       → Ki-Adi-Mundi (Haiku: รัน test ทุก worktree)
       → Mace Windu (Opus: ตรวจ diff ที่แตะเงิน)  → merge → Preview URL
       → Kit Fisto (Haiku: CHANGELOG)             → ลูกพี่กดอนุมัติ release
```

**กติกา เร็ว + แม่นยำ (ใส่ใน CLAUDE.md)**
1. Main session ใช้ **Opus** · งานใหญ่เริ่มด้วย Plan Mode เสมอ
2. แยกงานเป็นชิ้นที่ **ไม่แตะไฟล์เดียวกัน** แล้วรัน Agent ขนานใน worktree (`isolation: worktree`)
3. **Test-first สำหรับเงิน**: Plo Koon เขียน test ของประเภทรายการ/invariant ก่อนเขียนโค้ด
4. Subagent ตอบกลับ **สรุป ≤ 200 คำ** + ไฟล์ที่แก้ — ไม่ส่งเนื้อไฟล์เต็มกลับ (ประหยัด context = เร็วขึ้น)
5. `CLAUDE.md` สั้น (< 150 บรรทัด) รายละเอียดแยกใน `docs/`
6. ห้ามโหลด Excel/CSV ใหญ่เข้า context — เขียนสคริปต์อ่านแล้วสรุป
7. ค้นโค้ดใช้ `Explore` agent หรือ Haiku
8. งานซ้ำทำเป็น slash command/skill (`/new-module`, `/new-txn-type`, `/migration`, `/release`)
9. `/clear` ระหว่าง feature · Mace Windu ตรวจเฉพาะ diff ที่แตะเงิน
10. **Hook อัตโนมัติ**: หลังแก้ไฟล์ใน `lib/ledger` หรือ `supabase/migrations` → รัน vitest ledger ทันที (PostToolUse hook)

---

## 12. Migration จาก Excel ปัจจุบัน

| ต้นทาง (COWORK SRI) | ปลายทาง |
|---|---|
| `SRI_Balance_Sheet_Asset_Register.xlsx` → Setup / Asset Register / Loan-Sutee | owners, assets, asset_valuations, opening balances, director loan vs equity |
| `SRI_Transaction_ERP.xlsx` → Setup / Transactions / AR-AP | chart_of_accounts, txn_types, contacts, projects, transactions (opening + ตัวอย่าง) |
| `SRI_Asset_Management.xlsx` → Asset Master / Schedule / Contract & Notice / Task Tracker | contracts, schedules (ตั้งแต่ ต.ค. 2026), cards (12 งานตั้งต้น → Ticket/Deal) |
| `SRI Transaction Log and Reimbursement.xlsx` | reimbursements (ประวัติ) |

วิธี: สคริปต์ import (Python/TS) → staging tables → รายงานความต่าง → ลูกพี่ยืนยัน → เข้าตารางจริงเป็น **Opening Balance ณ 30/09/2026**

**ข้อมูลที่ยังต้องเติมก่อน go-live** (จาก overview เดิม): ราคาประเมิน/ตลาดทรัพย์บุคคล 36 รายการ · วันเริ่มสัญญาเช่าจริง · ยอดเงินสดคงเหลือจริงทุกบัญชี · เจ้าหนี้ค้างจ่าย · เงินมัดจำผู้เช่า · หนี้ธนาคารคงค้าง · สัญญา/เงื่อนไขเงินกู้ 10M พี่โอ๊ต

### 12.1 Checklist สิ่งที่ลูกพี่ต้องเตรียม (ก่อน Day 1)

**A. ตัดสินใจ (30 นาที)**
- [ ] **วันตัดยอดเปิดระบบ (Opening Balance date)** — แนะนำ **30/09/2026** ทุก owner ใช้วันเดียวกัน
- [ ] ยืนยันรายชื่อ owner: SRI Corporation / SRI Holding / SRI Capital (จดทะเบียนแล้วทั้ง 3 หรือยัง?) + Thanakorn / Thanawin / Benjaporn
- [ ] รายชื่อผู้ใช้ + email + role (Management / Manager / User) + ผูกกับ owner Personal คนไหน

**B. ข้อมูลการเงิน — ณ วันตัดยอด (สำคัญที่สุด)**

| # | ข้อมูล | แยกตาม | ลูกพี่เข้าใจไว้แล้ว? |
|---|---|---|---|
| 1 | **Balance Sheet** Corp/Personal | owner | ✓ ข้อ 1 ของลูกพี่ |
| 2 | **Asset Management + ผู้ขายฝาก/จำนอง** — เงินต้น, อัตรา, วันเริ่ม-ครบ, วันไถ่ถอน, ช่วงส่ง Notice, งวดที่รับแล้ว/ค้าง, ชื่อผู้ขายฝาก/ผู้จำนอง, ทรัพย์ค้ำ | สัญญา | ✓ ข้อ 2 ของลูกพี่ |
| 3 | **ยอดเงินคงเหลือจริงทุกบัญชี** (7 บัญชี) ตาม statement ณ วันตัดยอด + สถานะ Active/Inactive | บัญชี | ➕ ต้องเพิ่ม |
| 4 | **ผลต่างรอกระทบยอด 34.6M** — เงินอากงแยก ทุน (Equity) / เงินกู้กรรมการ (หนี้สิน) ให้ลงตัว | – | ➕ **ต้องเคลียร์ก่อน ไม่งั้น NAV ผิด** |
| 5 | **สัญญาเช่า + ผู้เช่า** — ค่าเช่า, วันจ่าย, เริ่ม-หมดสัญญา, **เงินมัดจำที่ถืออยู่**, สถานะจ่าย | ทรัพย์ | ➕ |
| 6 | **หนี้สิน** — เงินกู้ธนาคาร (เงินต้นคงค้าง/ดอกเบี้ย/งวด), เงินกู้กรรมการ, เจ้าหนี้ค้างจ่าย | owner | ➕ |
| 7 | **ลูกหนี้ค้างรับ (AR)** — ดอกเบี้ย/ค่าเช่าที่ถึงกำหนดแล้วยังไม่ได้รับ (เช่น iCondo งวด 4-5-6) | สัญญา | ➕ |
| 8 | **พอร์ตหลักทรัพย์** — ticker, ตลาด (TH/US), จำนวนหน่วย, ต้นทุนเฉลี่ย, สกุลเงิน, โบรกเกอร์ · กองทุน (รหัสกองทุน) · crypto · ทอง (หน่วย) | **owner (ใครถือ)** | ➕ |
| 9 | **เงินลงทุนธุรกิจ / Loan Agreement** — เช่น เงินกู้ 10M พี่โอ๊ต: สัญญา, ดอกเบี้ย, หลักประกัน | สัญญา | ➕ |
| 10 | ราคาประเมิน/ตลาดทรัพย์ (อย่างน้อยทรัพย์ Personal 36 รายการ) — ไม่มีให้ใช้ต้นทุนไปก่อน | ทรัพย์ | ➕ |

**C. ข้อมูลงาน/คน (Day 1–3 ใช้แค่รายชื่อผู้ใช้ ที่เหลือใช้ Sprint ถัดไป)**
- [ ] Contacts: ผู้ขายฝาก/ผู้จำนอง, ผู้เช่า, เอเจนต์, ช่าง — ชื่อ, เบอร์, LINE, ประเภท
- [ ] พนักงาน: ตำแหน่ง, หัวหน้า, เงินเดือน, จ่ายจาก Entity ไหน
- [ ] งานค้าง/ดีลที่เปิดอยู่ (12 งานใน Task Tracker + ดีลใหม่) สำหรับ Kanban/Ticket
- [ ] ไฟล์สัญญา PDF จัดโฟลเดอร์ตามรหัสทรัพย์ (ไม่จำเป็นใน 3 วันแรก)

**D. บัญชีบริการ / เครื่องมือ**
- [ ] **GitHub** — สร้าง repo private `sri-os`
- [ ] **Supabase** — สร้าง project ใหม่ `sri-os` (แนะนำ region Singapore) · ใช้งานจริงควรเป็นแผนเสียเงิน เพราะ project ฟรีจะถูก pause เมื่อไม่มีการใช้งาน (ดูราคาปัจจุบันก่อนสมัคร)
- [ ] **Vercel** — ต่อกับ GitHub (ตรวจเงื่อนไขแผนฟรีสำหรับใช้งานเชิงธุรกิจ)
- [ ] **Claude Code** บน Mac + แผนที่พอสำหรับใช้ Agent Team หลายตัว
- [ ] **Anthropic API key** แยกสำหรับฟีเจอร์ AI ในแอป (OCR, To-do, บทความ) — คนละส่วนกับ Claude Code
- [ ] Domain / subdomain ที่จะใช้
- [ ] (Sprint ถัดไป) LINE OA channel, Resend, SEC API key, BOT API key
- [ ] โลโก้ SRI เป็นไฟล์ **SVG** (ถ้ามี)

**E. เวลาของลูกพี่**
- [ ] ว่าง 2–3 ชม./วัน ช่วง 3 วัน สำหรับตัดสินใจ + ตรวจตัวเลข
- [ ] กำหนด **เจ้าของข้อมูล 1 คน** ที่ตอบคำถามข้อมูลได้เร็ว (ถ้าไม่ใช่ลูกพี่)
- [ ] (แนะนำ) นัดผู้สอบบัญชียืนยัน ผังบัญชี + ประเภทรายการฝั่ง Corporate ภายในสัปดาห์แรก

---

## 13. ความเสี่ยง & คำถามที่ต้องตอบก่อนเริ่ม Sprint 0

**ความเสี่ยงหลัก (เรียงตามผลกระทบ)**
1. **ข้อมูลตั้งต้นไม่กระทบ (34.6M)** → NAV/Equity ผิดตั้งแต่วันแรก ความเชื่อมั่นระบบพัง
2. **เร่ง 3 วันแล้วข้ามการตรวจ** — 11 โมดูลใน 3–4 สัปดาห์ทำได้แบบ "ใช้งานได้" ไม่ใช่ "สมบูรณ์" ถ้าต้องตัด แนะนำเลื่อน Investment Tips + Broker Portal + KPI review ไปท้ายสุด (ไม่กระทบตัวเงิน) · ห้ามตัดการตรวจของ Mace Windu และ UAT ตัวเลข
3. **ความปลอดภัยข้อมูลส่วนบุคคล/การเงินครอบครัว** — ต้องมี 2FA สำหรับ Management, RLS test อัตโนมัติ, ไม่เก็บเลขบัญชีเต็ม/เลขบัตรในตารางธรรมดา
4. **ราคาหุ้นไทยจากแหล่งไม่เป็นทางการ** อาจหยุดทำงาน → มี manual override + ธงราคาเก่า
5. **ภาษี/กฎหมาย** — routing rules, intercompany (transfer pricing), ดอกเบี้ยขายฝาก/จำนองเกินเพดาน, PDPA ข้อมูลผู้เช่า → **ต้องยืนยันกับนักกฎหมาย/ผู้สอบบัญชี** ระบบช่วยเตือน ไม่ใช่ตัดสิน

**คำถาม — ตอบแล้ว ✅**
1. ~~เกณฑ์ขนาดทรัพย์~~ → ไม่ตายตัว เลือกตอนคีย์ + Entity Policy (หัวข้อ 5)
2. ~~แหล่งราคาหุ้น~~ → ฟรีก่อน API ทีหลัง (หัวข้อ 2.3)
3. ~~Personal~~ → Thanakorn, Thanawin, Benjaporn
4. ~~วงเงินอนุมัติ~~ → ไม่มี · Management อนุมัติ/ข้ามขั้น (หัวข้อ 8)

**คำถามที่ยังค้าง**
5. Cost basis หุ้น: Average หรือ FIFO? (ฝั่ง Corporate ยืนยันกับผู้สอบบัญชี)
6. Domain ที่จะใช้ และ LINE OA ใช้ตัวเดิมหรือเปิดใหม่?
7. วันตัดยอดเปิดระบบ 30/09/2026 ได้ไหม?
8. SRI Holding / SRI Capital จดทะเบียนแล้วหรือยัง (ถ้ายัง ให้สร้างเป็น owner สถานะ "planned" ซ่อนจากรายงาน)
9. ยอมให้เลื่อน Investment Tips / Broker Portal ไป sprint ท้ายสุดไหม ถ้าเวลาไม่พอ?

---

## 14. Deploy ระบบหลักก่อน แล้วอัปเดตต่อเนื่อง (Release Pipeline)

**ได้ครับ — และควรทำแบบนี้ตั้งแต่วันแรก** ระบบหลักขึ้น Production วันที่ 3 จากนั้นทุกโมดูลใหม่ปล่อยเป็นรอบอัปเดต โดยผู้ใช้ไม่ต้องหยุดใช้งาน และข้อมูลเดิมไม่หาย

### 14.1 สภาพแวดล้อม 3 ชั้น

| ชั้น | ใช้ทำอะไร | App | Database |
|---|---|---|---|
| **Local** | Agent พัฒนา + test | `pnpm dev` บน Mac | Supabase local (Docker) |
| **Preview** | ลูกพี่ลองก่อนปล่อย ทุก PR ได้ลิงก์ของตัวเอง | Vercel Preview URL | Supabase Branch (สำเนาโครงสร้าง + ข้อมูลตัวอย่าง) หรือ project `sri-os-staging` |
| **Production** | ใช้งานจริง | Vercel Production (domain จริง) | Supabase `sri-os` |

### 14.2 ขั้นตอนต่อ 1 รอบอัปเดต

```
1. แตก branch  feat/auto-ledger
2. Agent Team พัฒนา + test (หัวข้อ 11.1)
3. เปิด PR ──► GitHub Actions: typecheck · lint · vitest (ledger) · Playwright smoke · ตรวจ migration
             ──► Vercel สร้าง Preview URL อัตโนมัติ + Supabase preview branch รัน migration
4. Mace Windu review (ถ้าแตะเงิน) + ลูกพี่เปิด Preview URL ลองกดจริง → Approve
5. Merge เข้า main ──► GitHub Action: supabase db push (migration ขึ้น Production ก่อน)
                   ──► Vercel deploy Production อัตโนมัติ
6. Smoke test อัตโนมัติบน Production + fn_health_check()
7. Tag release  v1.1.0 + CHANGELOG ภาษาไทย (Kit Fisto) + แจ้งทีมใน LINE "มีอะไรใหม่"
```

### 14.3 กติกาเพื่อไม่ให้ Production พัง / ข้อมูลหาย

1. **Migration แบบเพิ่มอย่างเดียว (expand → contract)** — เพิ่มคอลัมน์/ตารางได้ทันที · ลบ/เปลี่ยนชื่อคอลัมน์ต้องทำ 2 release (release แรกเลิกใช้, release ถัดไปค่อยลบ)
2. **ห้ามแก้ไฟล์ migration ที่ขึ้น Production แล้ว**
3. **Backup ก่อน migration ทุกครั้ง** (Supabase backup/PITR ตามแผนที่ใช้) · ข้อมูลเงินห้าม `DROP` ในทุกกรณี
4. **Feature flag** — โมดูลใหม่เปิดให้ Management ก่อน 2–3 วัน แล้วค่อยเปิดทั้งทีม
5. **Rollback**: แอป → Vercel Instant Rollback (กดย้อนเวอร์ชันได้ทันที) · ฐานข้อมูล → แก้ด้วย migration ใหม่ (forward-fix) ไม่ย้อน schema
6. **Hotfix**: branch `hotfix/*` → PR → deploy ได้ภายในวัน โดยยังผ่าน test ledger
7. Environment variables/secrets อยู่ใน Vercel + Supabase Vault เท่านั้น ไม่อยู่ใน repo

### 14.4 Release Roadmap

| Version | เนื้อหา | เป้า |
|---|---|---|
| **v1.0 — Core** | Ledger · อนุมัติ · ยืนยันรับ-จ่าย · PL/CF · Asset register + BS/NAV · Dashboard v1 · Settings · Mobile บันทึก/อนุมัติ | Day 3 |
| v1.1 — Asset Automation | ทะเบียนข้อมูลสัญญา + แนบไฟล์ · ตารางงวด · Auto Ledger รายเดือน · AR/AP aging · Contract watch | +1 สัปดาห์ |
| v1.2 — Work | Kanban Deal + Ticket + Gantt · Contacts CRM · เบิกจ่าย + OCR | +1 สัปดาห์ |
| v1.3 — People | HR · KPI · Org chart · Payroll draft | +0.5 สัปดาห์ |
| v1.4 — Intelligence | AI To-do · Investment Tips · Broker Portal · LINE แจ้งเตือน | +1 สัปดาห์ |
| v2.0 | VAT/ใบกำกับภาษีฝั่ง Corporate · Bank statement auto-match · API ราคาหุ้นแบบเสียเงิน · LINE OA รับดีล | หลังใช้งานจริง 1 เดือน |

### 14.5 เครื่องมือ / Integration / Connector ทั้งหมด

**A. ใช้ตอนพัฒนา (บนเครื่องลูกพี่ + Claude Code)**

| เครื่องมือ | ใช้ทำอะไร | ต้องมีตอน | วิธีเชื่อม |
|---|---|---|---|
| **Claude Code (Max)** | Agent Team เขียน/ทดสอบ/deploy | v1.0 | ติดตั้งบน Mac |
| **GitHub** (repo private + Actions) | เก็บโค้ด, PR, CI/CD, release tag | v1.0 | `gh` CLI + GitHub MCP |
| **Claude GitHub App** | สั่ง `@claude` ใน PR ให้ review/แก้ | v1.0 (แนะนำ) | ติดตั้งผ่าน `/install-github-app` |
| **Supabase CLI** | migration, local DB, gen types, db push | v1.0 | `pnpm dlx supabase` |
| **Vercel CLI** | env, deploy manual ถ้าจำเป็น | v1.0 | `vercel` |
| **Docker Desktop** | รัน Supabase local | v1.0 | ติดตั้งบน Mac |
| **Node.js LTS + pnpm** | รันโปรเจกต์ | v1.0 | ติดตั้งบน Mac |

**B. MCP Server ใน Claude Code**

| MCP | ใช้ทำอะไร | ต้องมีตอน |
|---|---|---|
| **Supabase MCP** | สร้าง project/branch, apply migration, ดู logs & advisors, gen types | v1.0 ★ |
| **Vercel MCP** | ดู deployment, build/runtime logs, env, rollback | v1.0 ★ |
| **GitHub MCP** | PR, issues, Actions status | v1.0 ★ |
| **Playwright MCP** | เปิดเว็บทดสอบ PC/Tablet/Mobile + screenshot | v1.0 ★ |
| **Context7** | ดึงเอกสาร Next.js/Supabase/shadcn เวอร์ชันล่าสุด (ลดโค้ดผิดเวอร์ชัน) | v1.0 (แนะนำ) |
| **Hostinger MCP** | ตั้ง DNS ชี้ domain ไป Vercel (ถ้า domain อยู่ Hostinger) | v1.0 (ถ้าใช้) |
| Google Drive / Calendar MCP | อ่านไฟล์สัญญา/ตารางทีมตอนพัฒนาเชื่อมต่อ | v1.2 |

**C. บริการที่ระบบใช้ตอนทำงานจริง (Runtime)**

| บริการ | ใช้ทำอะไร | ต้องมีตอน |
|---|---|---|
| **Supabase** — Postgres, Auth, Storage, Edge Functions, pg_cron, Vault | ฐานข้อมูล, login, เก็บไฟล์สัญญา/สลิป, งานอัตโนมัติ, เก็บ API key | v1.0 ★ |
| **Vercel** — Hosting, Preview, Analytics, Speed Insights | เว็บแอป + ลิงก์ทดลองทุก PR | v1.0 ★ |
| **Domain + DNS** | เช่น `os.<domain ของ SRI>` | v1.0 ★ |
| **Sentry** | แจ้ง error จริงจากผู้ใช้ พร้อมหน้า/ขั้นตอนที่เกิด | v1.0 (แนะนำมาก) |
| **Uptime monitor** (Better Stack / UptimeRobot) | แจ้งเตือนเว็บล่ม | v1.0 |
| **Yahoo Finance (ฟรี)** · **CoinGecko** · **SEC Open Data API** · **BOT API** | ราคาหุ้นไทย/US · crypto · กองทุน · อัตราแลกเปลี่ยน | v1.0 |
| **Anthropic API** (key แยกจาก Max) | OCR สลิป/ใบเสร็จ, AI To-do, สรุปบทความ | v1.2 |
| **Resend** | อีเมลเชิญผู้ใช้, สรุปรายสัปดาห์ | v1.0 (เชิญผู้ใช้) |
| **LINE Messaging API (LINE OA)** | แจ้งเตือนอนุมัติ/ครบกำหนด, (v2) รับสลิป/ดีล | v1.4 |
| **Google Calendar API** | ตารางทีมบน Dashboard | v1.4 |
| **PEAK** (export CSV) | ส่งข้อมูลฝั่ง Corporate ให้ผู้ทำบัญชี | v2.0 |

**D. ออกแบบ**

| เครื่องมือ | ใช้ทำอะไร |
|---|---|
| **Claude Design** | ออกแบบหน้าจอจาก `SRI_OS_DESIGN_BRIEF.md` → export HTML/ภาพให้ Luminara แปลงเป็นโค้ด |
| **shadcn/ui + Tailwind** | ชุด component ในโค้ด ให้หน้าตาตรงแบบ |
| Figma | ไม่จำเป็น (ใช้ Claude Design แทน) |

**สิ่งที่ไม่ต้องใช้ (ตัดออกเพื่อความง่าย)**: Google Sheets เป็นฐานข้อมูล · n8n/Zapier ใน v1.x (เขียนเป็น Edge Function แทน เพื่อให้ logic อยู่ที่เดียว) · Notion

> หมายเหตุ: บาง feature ของ Supabase (เช่น Branching, PITR) และ Vercel สำหรับใช้งานเชิงธุรกิจอยู่ในแผนเสียเงิน — ตรวจแผนและราคาปัจจุบันก่อนสมัคร

---

*แหล่งอ้างอิงที่ใช้ในแผน*: [Settrade Open API](https://developer.settrade.com/open-api/) · [SET SMART Marketplace](https://www.set.or.th/en/services/connectivity-and-data/data/smart-marketplace) · [SEC API Developer Portal — Fund Daily Info](https://api-portal.sec.or.th/docs/services/fund-daily-info) · ไฟล์ Excel 3 ตัวใน COWORK SRI · `sri-excel-system-overview.md`
