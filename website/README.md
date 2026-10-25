# SRI Corporation — Website

Mockup v0.2 ของหน้า Homepage (TH / EN) · เปิด `index.html` ในเบราว์เซอร์ได้ทันที (ไฟล์เดียว ไม่ต้อง build)

## โครงหน้า
1. Hero — สร้างความมั่งคั่งที่ส่งต่อได้หลายรุ่น
2. หลักการ 4 ข้อ (มั่นคง · โปร่งใส · รวดเร็ว · ระยะยาว)
3. 3 ธุรกิจหลัก — Real Estate Solution / Financing / Investing
4. การทำงานจริง (รูป + 4 ขั้นตอน)
5. Portfolio (รออัปเดต)
6. ฟอร์ม Be Partner / Team (ชื่อ · อีเมล · เบอร์โทร)
7. Footer — ที่อยู่ · อีเมล · Facebook / IG / TikTok

## ภาษา TH / EN
- ปุ่มสลับภาษามุมขวาบน · จำภาษาที่เลือกไว้ · ลิงก์ตรงภาษาอังกฤษ `index.html?lang=en`
- ข้อความไทยอยู่ใน HTML ส่วนภาษาอังกฤษอยู่ใน `data-en` ของแต่ละบรรทัด (แก้คำแปลที่จุดเดียวกัน)

## Design
- สี CI `#004AAD` + Navy `#061A3A` · เสริมมิติด้วยทอง `#C8A96A` (ใช้น้อย)
- ฟอนต์ IBM Plex Sans Thai (ไทยไม่มีหัว ใกล้ Sukhumvit Set) — ตัวเดียวกับ SRI OS

## สิ่งที่ยังเป็นตัวแทนชั่วคราว
| รายการ | แก้ที่ |
|---|---|
| ภาพหลักหน้าแรก (ตึกกรุงเทพฯ) | วางไฟล์ `assets/img/hero-bangkok.jpg` แล้วขึ้นเองทันที (ยังไม่มีไฟล์จะใช้รูปสำรอง) |
| รูปอื่นๆ (Unsplash) | `IMAGES` ใน `index.html` → ใส่รูปจริงใน `assets/img/` |
| โลโก้ | วาดเป็น SVG จากรูป CI แล้ว (`assets/brand/sri-logo-blue.svg`, `sri-logo-white.svg`) — ถ้ามีไฟล์ vector ต้นฉบับ (AI/SVG) ส่งมาแทนได้ |
| ที่อยู่ / เบอร์โทร | footer ใน `index.html` |
| ฟอร์มยังไม่ส่งจริง | `FORM_TO` (ตอนนี้ sricorpth@gmail.com) และ `FORM_ENDPOINT` |

## เครดิตรูปตัวอย่าง
Unsplash License (ใช้เชิงพาณิชย์ได้ฟรี) — จะเปลี่ยนเป็นรูปงานจริงของ SRI ก่อนขึ้นเว็บจริง
