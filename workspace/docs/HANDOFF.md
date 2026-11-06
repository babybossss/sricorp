# SRI Workspace — Handoff

เวอร์ชัน 06/11/2026 · เฟสแรก: HR ลงเวลาเข้า-ออกงาน
ตัวเลขและชื่อใน Mockup เป็นข้อมูลตัวอย่าง

## 1. สถานะที่ตรวจจาก Repo

- `main` ตอนนี้มีเฉพาะเอกสาร SRI OS
- โค้ด SRI OS อยู่ branch `claude/blissful-euler-54m3md` (PR #1 ยังเปิดอยู่)
- SRI OS ใช้ Next.js 15, React 19, Supabase schema `sri_os`, Vercel region `sin1`
- โดเมน OS ที่พบในโค้ด: `https://os.sricorporation.com`
- Role เดิม: `super_admin`, `management`, `manager`, `staff`
- มีตาราง `roles`, `permissions`, `role_permissions` และ `fn_can()` อยู่แล้ว
- `.env.example` ของ OS ห้ามใช้ service-role key

ตรวจของจริงซ้ำก่อนสร้างทุกครั้ง เพราะข้อมูลข้างบนเป็น Snapshot ณ วันที่เขียน

## 2. สถาปัตยกรรมที่เสนอ

- `workspace/` เป็น Next.js App แยก Deploy เป็น Vercel Project คนละตัว โดยตั้ง Root Directory เป็น `workspace`
- ใช้ Supabase Project เดิม และ Auth เดิม
- สร้าง schema ใหม่ `sri_workspace` ไม่ปนกับ `sri_os`
- ผูกผู้ใช้กับ `sri_os.app_users`
- เพิ่ม permission key ใหม่ในระบบเดิม เช่น `hr.time.read_team`, `hr.time.export`, `hr.site.manage`
- Migration ต้องอยู่ประวัติเดียวกับ OS ห้ามแยกประวัติ Database สองชุด
- โดเมนเสนอ: `workspace.sricorporation.com` (รอลูกพี่ยืนยัน)

ต้องรอ PR #1 ลง `main` หรือทำงานบนฐาน branch นั้น ก่อนเขียน Migration จริง ให้เสนอแนวทางก่อนทำ

## 3. ขอบเขตเฟสแรก

ทำ:
1. Login และหน้าแรกตามสิทธิ์
2. การ์ด SRI OS เฉพาะผู้มีสิทธิ์ และการ์ด Coming soon ของโมดูลอื่น
3. ประกาศและความยินยอม GPS + รูปถ่าย
4. ลงเวลาเข้า: GPS → เซลฟี่ → บันทึก
5. ลงเวลาออก: GPS → บันทึก
6. ประวัติลงเวลาของฉัน
7. Manager ขึ้นไปดูเวลาทีมและรูปยืนยันได้
8. Admin บันทึกแทนพร้อมเหตุผล
9. Export Excel รายเดือน

ยังไม่ทำ: ลา, OT, ขอเบิกเงิน, Payroll, LINE, Real Estate Op

## 4. กติกาการลงเวลา

- ใช้เวลาเซิร์ฟเวอร์จาก RPC ไม่รับเวลาจาก Client
- RPC คำนวณระยะจากจุดลงเวลาเอง
- เก็บพิกัด, accuracy, ระยะห่าง, สถานที่, ผลอยู่ในพื้นที่, ที่มาของรายการ
- นอกพื้นที่หรือ GPS แม่นยำต่ำ: ลงเวลาได้ แต่ติดธงให้หัวหน้าตรวจ
- เซลฟี่ต้องมาจากกล้องสด ย่อรูปก่อนอัปโหลด ไม่ใช้ Face Recognition
- กันกดซ้ำ: ห้ามมีรายการเข้างานซ้อนโดยยังไม่ออกงาน
- ลืมออกงาน: ขึ้นสถานะรอแก้ไข ห้ามเติมเวลาอัตโนมัติ
- GPS ปลอมได้ ระบบนี้เป็นหลักฐานประกอบ ไม่ใช่การพิสูจน์แบบเด็ดขาด

## 5. ตารางเสนอ (`sri_workspace`)

- `work_sites`: name, lat, lng, radius_m, is_active
- `privacy_notices`: version, body, effective_at
- `privacy_consents`: user_id, notice_version, decision, decided_at, withdrawn_at
- `time_entries`: user_id, kind, server_at, lat, lng, accuracy_m, distance_m, site_id, in_area, flagged_reason, selfie_path, source, created_by
- `time_corrections`: entry_id, reason, requested_by, approved_by, created_at
- `export_logs`: user_id, month, row_count, created_at
- `audit_logs`: actor_id, entity, entity_id, action, before, after, created_at

## 6. สิทธิ์

| Role | สิทธิ์ |
|---|---|
| `staff` | ลงเวลาและดูของตัวเอง |
| `manager` | + ดูทีมตัวเอง, รูปยืนยันทีมตัวเอง, Export ทีมตัวเอง |
| `management` | + ดูทั้งหมด, Export ทั้งหมด, จัดการสถานที่ |
| `super_admin` | ทั้งหมด |

หาก Admin ฝ่าย HR ไม่ใช่ Manager ให้เพิ่มผ่าน permission ไม่สร้างเงื่อนไขในโค้ด

## 7. Export

- `.xlsx` รายเดือน
- คอลัมน์: วันที่, รหัสพนักงาน, ชื่อ, เวลาเข้า, เวลาออก, ชั่วโมงรวม, สถานที่, สถานะพื้นที่, หมายเหตุ, เลขที่ Record
- ไม่ใส่รูปเซลฟี่และพิกัดละเอียด
- บันทึก `export_logs` ทุกครั้ง

## 8. Definition of Done

- RLS Test ครบทุก Role รวมกรณีพนักงานอ่านข้อมูลคนอื่น
- ปฏิเสธ GPS/กล้องแล้วมีข้อความไทยและทางออก
- ทดสอบบน iPhone Safari และ Android Chrome จริง
- ทดสอบ Timezone เป็น Asia/Bangkok
- `npm run lint`, typecheck, test ผ่าน
- OS ไม่ถูกแก้โดยไม่ได้รับอนุมัติ

## 9. ต้องตัดสินใจก่อน Go-live

ลูกพี่:
1. รายชื่อพนักงาน, หัวหน้า, Role
2. สถานที่ลงเวลา พิกัด และรัศมี
3. โดเมนของ Workspace
4. ระยะเวลาเก็บรูปเซลฟี่
5. พนักงานขับรถจะลงเวลาที่ไหน เพราะทำงานนอกสถานที่

ต้องยืนยันกับนักกฎหมาย/ผู้สอบบัญชี:
1. ฐาน PDPA และข้อความแจ้งสำหรับ GPS + เซลฟี่
2. ทางเลือกของผู้ไม่ยินยอม
3. กติกาเวลาทำงานและการเก็บ Record

## 10. Backlog หลังเฟสแรก

1. ขอลา + OT + กล่องอนุมัติ
2. ขอเบิกเงิน: วันที่, เหตุผล, ประเภทบิล, รูปบิล, ยอดเงิน, เจ้าของค่าใช้จ่าย
3. Export ลา/OT/เบิกเงิน
4. แจ้งเตือน LINE
5. Real Estate Op
