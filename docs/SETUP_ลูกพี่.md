# 4 ขั้นที่ลูกพี่ต้องทำ — ทำตามลำดับนี้

> ตรวจชื่อตัวแปรและ path กับโค้ดจริงแล้ว 20 ต.ค.
> Supabase project: **`oyigmbmxxlfhkrevsmxo`** (ชื่อ `sri-os` · ap-southeast-1)
> Vercel project: **`sri-os`** (team `thanakorns`)

**ทำข้อ 1 ข้อเดียวก็พอให้ผมเดินต่อได้อีกหลายชั่วโมง** ข้อ 2–4 ทำตามมาเมื่อไหร่ก็ได้

---

## ข้อ 1 · ใส่ `SRI_DB_URL` — **สำคัญที่สุด**

ตัวนี้ให้ผมต่อฐานข้อมูลตรงเพื่อ apply migration 47 ไฟล์

### หาค่า

1. เปิด https://supabase.com/dashboard/project/oyigmbmxxlfhkrevsmxo/settings/database
2. เลื่อนหา **Connection string** → แท็บ **URI**
3. กด **Copy** · จะได้รูปแบบ
   ```
   postgresql://postgres.oyigmbmxxlfhkrevsmxo:[YOUR-PASSWORD]@aws-0-ap-southeast-1.pooler.supabase.com:6543/postgres
   ```
4. แทน `[YOUR-PASSWORD]` ด้วยรหัสผ่านฐานข้อมูลจริง
   **จำไม่ได้** → ปุ่ม **Reset database password** หน้าเดียวกัน (ตั้งใหม่ได้ ไม่กระทบข้อมูล)

### ใส่ค่า

ในแอป Claude หน้า session นี้ → เมนู **environment** → **Edit** → ช่อง **Network secrets**
(หรือใส่เป็น environment variable ของ environment ก็ได้)

- **ชื่อ**: `SRI_DB_URL`
- **ค่า**: connection string ทั้งเส้น

### ⛔ ห้ามพิมพ์ค่านี้ลงในแชท

รหัสผ่านฐานข้อมูลที่พิมพ์ในแชทจะค้างอยู่ในประวัติการสนทนาตลอดไป
ช่อง secrets ของ environment เป็นที่เดียวที่ถูกต้อง · **ผมจะไม่ขอให้ลูกพี่ส่งมาในแชทเด็ดขาด**

### บอกผมว่าใส่แล้ว
พิมพ์ว่า *"ใส่ SRI_DB_URL แล้ว"* — ผมจะรัน **dry-run ก่อน** ดูว่าฐานข้อมูลจริงบันทึกว่า
apply อะไรไปแล้ว **แล้วรายงานให้ดูก่อนเขียนอะไรลงไปจริง** ไม่ลงมือเองทันที

---

## ข้อ 2 · ใส่ env ของ Supabase ใน Vercel

ทำให้หน้าล็อกอินเลิกขึ้น *"ตั้งค่า Supabase ยังไม่ครบ"*

### หาค่า
เปิด https://supabase.com/dashboard/project/oyigmbmxxlfhkrevsmxo/settings/api

| ตัวแปร | เอาค่าจาก |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | ช่อง **Project URL** (`https://oyigmbmxxlfhkrevsmxo.supabase.co`) |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | **Publishable key** (ขึ้นต้น `sb_publishable_`) หรือ **anon public** ถ้าหน้ายังเป็นรุ่นเก่า |

### ⛔ ห้ามใช้ service_role key
โค้ดมีด่านปฏิเสธไว้แล้ว (`src/lib/supabase/env.ts`) ถ้าใส่ผิดแอปจะไม่ขึ้นเลย
ซึ่งดีกว่าขึ้นแล้วใครก็อ่านข้อมูลได้ทั้งหมด · **key ที่ถูกคือตัวที่เอาไปวางในเบราว์เซอร์ได้**

### ใส่ค่า
Vercel → project **`sri-os`** → **Settings** → **Environment Variables** → Add

- ใส่**ทั้งสองตัว** · ติ๊ก environment ให้ครบ **Production · Preview · Development**
- ใส่เสร็จต้อง **Redeploy** หนึ่งรอบ (Deployments → ปุ่ม `···` ที่ตัวล่าสุด → Redeploy)
  เพราะ Next.js ฝังค่า `NEXT_PUBLIC_*` ตอน build **ไม่ใช่ตอนรัน**

---

## ข้อ 3 · เปิด Google login

### 3.1 สร้าง OAuth client ที่ Google
1. https://console.cloud.google.com/apis/credentials → **Create Credentials** → **OAuth client ID**
2. Application type: **Web application**
3. **Authorized redirect URIs** ใส่
   ```
   https://oyigmbmxxlfhkrevsmxo.supabase.co/auth/v1/callback
   ```
   (ของ Supabase ไม่ใช่ของเว็บเรา — ขั้นนี้คนสับสนบ่อยที่สุด)
4. เก็บ **Client ID** กับ **Client Secret**

### 3.2 เปิดที่ Supabase
https://supabase.com/dashboard/project/oyigmbmxxlfhkrevsmxo/auth/providers
→ **Google** → เปิด → วาง Client ID + Secret → **Save**

### 3.3 ตั้ง URL ที่อนุญาต
https://supabase.com/dashboard/project/oyigmbmxxlfhkrevsmxo/auth/url-configuration

- **Site URL**
  ```
  https://sri-os-git-claude-blissful-euler-54m3md-thanakorns.vercel.app
  ```
- **Redirect URLs** → Add ทั้งสองบรรทัด
  ```
  https://sri-os-git-claude-blissful-euler-54m3md-thanakorns.vercel.app/auth/callback
  http://localhost:3000/auth/callback
  ```

> path คือ **`/auth/callback`** (ตรวจกับ `src/app/auth/callback/route.ts` แล้ว)
> วันหลังถ้าผูก domain ของตัวเอง ต้อง **เพิ่ม** URL ใหม่ที่นี่ · **อย่าลบของเดิม**

---

## ข้อ 4 · ส่งรายชื่อคนที่จะใช้ระบบ

ตอบในแชทเป็นตารางแบบนี้

| ชื่อ | อีเมล Google | ระดับ |
|---|---|---|
| ธนากร ศรีชัยธำรง | ...@gmail.com | Management |
| | | |

**ระดับที่มี** — `Management` · `Manager` · `Staff` · `Viewer`

### ⚠️ Staff ยังสร้างไม่ได้
ติดเงื่อนไข **D-089**: RLS ซ่อนแถวได้แต่**ซ่อนคอลัมน์ไม่ได้** → บัญชี Staff จะเห็นคอลัมน์
ที่ไม่ควรเห็นในแถวที่มันมีสิทธิ์อ่าน · **คืนนี้ผมกำลังปิดเรื่องนี้**
ส่งรายชื่อ Staff มาได้เลย ผมจะสร้างให้หลังปิดเสร็จ

ส่วน Management / Manager / Viewer สร้างได้ทันทีที่ข้อ 1–3 เสร็จ

---

## ลำดับที่แนะนำตอนเช้า

```
ข้อ 1  (5 นาที)   → บอกผม → ผมเริ่ม apply migration ได้เลย
ข้อ 2  (10 นาที)  → Redeploy
ข้อ 3  (20 นาที)  → ขั้นที่ยาวสุด เพราะต้องไป Google Console
ข้อ 4  (2 นาที)   → ตอบในแชท
```

**ถ้ามีเวลาแค่ 5 นาที ทำข้อ 1 อย่างเดียว** — ที่เหลือผมรอได้

---

## ⛔ ของที่ยัง**ห้าม**ทำ

**ห้ามผูก domain ของตัวเองเข้า Vercel ตอนนี้**

Vercel ตั้ง SSO ไว้แบบ `all_except_custom_domains` → URL `.vercel.app` ต้องล็อกอิน Vercel ก่อน
(ปลอดภัยอยู่) แต่ **วินาทีที่ผูก domain ของตัวเอง domain นั้นเปิดสู่อินเทอร์เน็ตทันที**
เหลือล็อกอินของแอปเป็นด่านเดียว ซึ่งยังตรวจสิทธิ์ใครไม่ได้จนข้อ 1–4 เสร็จ

ลำดับที่ปลอดภัย: ข้อ 1–4 → **ทดสอบว่าคนไม่มีบัญชีเข้าไม่ได้จริง** → ค่อยผูก domain
รายละเอียดเต็มอยู่ใน `docs/DOMAIN_SETUP.md`
