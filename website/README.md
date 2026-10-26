# SRI Corporation — Website

Mockup v0.2 ของหน้า Homepage (TH / EN) · เปิด `index.html` ในเบราว์เซอร์ได้ทันที (ไฟล์เดียว ไม่ต้อง build)

## โครงหน้า
1. Hero — สร้างความมั่งคั่งที่ส่งต่อได้หลายรุ่น
2. หลักการ 4 ข้อ (มั่นคง · โปร่งใส · รวดเร็ว · ระยะยาว)
3. 3 ธุรกิจหลัก — Real Estate Solution / Financing / Investing
4. การทำงานจริง (รูป + 4 ขั้นตอน)
5. Portfolio (รออัปเดต)
6. ฟอร์ม Be Partner / Team (ชื่อ · อีเมล · เบอร์โทร)
7. Footer — ที่อยู่ · อีเมล · โทร · Facebook / IG / TikTok / LINE OA (@sricorp)

## ภาษา TH / EN
- ปุ่มสลับภาษามุมขวาบน · จำภาษาที่เลือกไว้ · ลิงก์ตรงภาษาอังกฤษ `index.html?lang=en`
- ข้อความไทยอยู่ใน HTML ส่วนภาษาอังกฤษอยู่ใน `data-en` ของแต่ละบรรทัด (แก้คำแปลที่จุดเดียวกัน)

## Design
- สี CI `#004AAD` + Navy `#061A3A` · เสริมมิติด้วยทอง `#C8A96A` (ใช้น้อย)
- ฟอนต์ IBM Plex Sans Thai (ไทยไม่มีหัว ใกล้ Sukhumvit Set) — ตัวเดียวกับ SRI OS

## ไฟล์แบรนด์
- `assets/brand/sri-logo-original.png` — ไฟล์โลโก้ต้นฉบับ (500×500 พื้นขาว)
- `assets/brand/sri-logo-blue.png` / `sri-logo-white.png` — ตัดจากต้นฉบับ พื้นโปร่งใส (ไม่ได้วาดใหม่)
- `assets/img/hero-bangkok.jpg` — ภาพหลักหน้าแรก (ตัดแถบน้ำเงินและโลโก้ด้านบนของภาพเดิมออก)

## สิ่งที่ยังเป็นตัวแทนชั่วคราว
| รายการ | แก้ที่ |
|---|---|
| รูปอื่นๆ (Unsplash) | `IMAGES` ใน `index.html` → ใส่รูปจริงใน `assets/img/` |
| ฟอร์มยังไม่ส่งจริง | `FORM_ENDPOINT` · ปลายทางตั้งแล้วใน `FORM_ROUTES`: Partner → sricorpth@gmail.com, admin@sricorporation.com · Staff Member → sricorpth@gmail.com, hr@sricorporation.com |

## เครดิตรูปตัวอย่าง
Unsplash License (ใช้เชิงพาณิชย์ได้ฟรี) — จะเปลี่ยนเป็นรูปงานจริงของ SRI ก่อนขึ้นเว็บจริง

## เครดิตรูป (Unsplash License)
| ตำแหน่ง | ช่างภาพ | ลิงก์ |
|---|---|---|
| Real Estate | Sua Truong | https://unsplash.com/photos/PHMabtedGwQ |
| Financing | Dimitri Karastelev | https://unsplash.com/photos/ZH4FUYiaczY |
| Investing | Vitaly Gariev | https://unsplash.com/photos/1nVQJc4YLKM |
| ประชุมดีล | Felix Viray | https://unsplash.com/photos/WEKYnsgn0x8 |
| ลงพื้นที่ | Ferdy Yudha Pradana | https://unsplash.com/photos/Z26xhCklph0 |
| ตรวจเอกสาร | blue sky | https://unsplash.com/photos/dMUUUv5erIY |
| ส่งมอบทรัพย์ | Jakub Żerdzicki | https://unsplash.com/photos/bqUZEAeWuok |
| ปิดดีล | Van Tay Media | https://unsplash.com/photos/T5QgMRe-sCs |
| พื้นหลังฟอร์ม | Van Tay Media | https://unsplash.com/photos/HYDapQuENOM |
