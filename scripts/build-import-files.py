"""
สร้างไฟล์ Excel สองไฟล์ที่ลูกพี่ต้องกรอกแล้ว import เข้าระบบ

  1. SRI_OS_1_ผังบัญชี_และหมวดงบ.xlsx   — ตั้งค่าบัญชีและโครงงบ PL/BS
  2. SRI_OS_2_ยอดตั้งต้นงบดุล.xlsx      — ยอดตั้งต้นแยกตามผู้ถือ ทีละบัญชี

อ่านผังบัญชี โครงงบ และตารางกฎจาก JSON ที่ `scripts/dump-rules.ts` ส่งออกมา
**ห้ามแก้ตัวเลขหรือรหัสบัญชีในไฟล์ .xlsx โดยตรง** — แก้ที่ `src/lib/rules/`
แล้ว generate ใหม่ ไม่งั้นครั้งหน้าจะถูกทับ

รัน: npm run build:import
"""
import json
import sys

from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.formatting.rule import CellIsRule
from openpyxl.utils import get_column_letter

# ---------- สไตล์ ให้เหมือนเทมเพลตเดิมที่ลูกพี่เคยเห็นแล้ว ----------
BRAND = "004AAD"
INK = "0A2540"
POS = "0E7C4A"
NEG = "B3261E"
REQ_FILL = PatternFill("solid", fgColor="FDF2F4")
OPT_FILL = PatternFill("solid", fgColor="F6F9FC")
LOCK_FILL = PatternFill("solid", fgColor="F0F1F3")
NOTE_FILL = PatternFill("solid", fgColor="EEF4FC")
WARN_FILL = PatternFill("solid", fgColor="FDF3E4")
SUM_FILL = PatternFill("solid", fgColor="F4F7FB")
EX_FILL = PatternFill("solid", fgColor="FBFCFE")
OK_FILL = PatternFill("solid", fgColor="E9F7EF")
BAD_FILL = PatternFill("solid", fgColor="FDECEA")
THIN = Side(style="thin", color="E3E8EE")
BORDER = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)
TOPLINE = Border(top=Side(style="medium", color="C7CDD4"))

F = "IBM Plex Sans Thai"
TITLE = Font(name=F, size=16, bold=True, color=BRAND)
H2 = Font(name=F, size=12, bold=True, color=INK)
HEAD = Font(name=F, size=11, bold=True, color=INK)
BODY = Font(name=F, size=11, color=INK)
LOCKED = Font(name=F, size=11, color="6B7280")
NOTE = Font(name=F, size=10, color="425466")
EXF = Font(name=F, size=11, color="8792A2", italic=True)
BOLD = Font(name=F, size=11, bold=True, color=INK)
MONEY = "#,##0.00;(#,##0.00)"

TYPE_TH = {
    "asset": "สินทรัพย์",
    "liability": "หนี้สิน",
    "equity": "ส่วนของเจ้าของ",
    "income": "รายได้",
    "expense": "ค่าใช้จ่าย",
}
CUTOFF = "30/09/2026"


def head_row(ws, row, cols, widths=None):
    """cols: list of (header, required|'lock', hint)"""
    for i, (header, req, hint) in enumerate(cols, start=1):
        c = ws.cell(row=row, column=i, value=header + (" *" if req is True else ""))
        c.font = HEAD
        c.fill = LOCK_FILL if req == "lock" else (REQ_FILL if req else OPT_FILL)
        c.border = BORDER
        c.alignment = Alignment(wrap_text=True, vertical="center")
        h = ws.cell(row=row + 1, column=i, value=hint)
        h.font = NOTE
        h.border = BORDER
        h.alignment = Alignment(wrap_text=True, vertical="top")
        ws.column_dimensions[get_column_letter(i)].width = (widths or {}).get(header, 20)
    ws.row_dimensions[row].height = 30
    ws.row_dimensions[row + 1].height = 32


def titled(wb, name, title, note, span=6):
    ws = wb.create_sheet(name)
    ws.sheet_view.showGridLines = False
    ws["A1"] = title
    ws["A1"].font = TITLE
    ws.merge_cells(start_row=1, start_column=1, end_row=1, end_column=span)
    ws["A2"] = note
    ws["A2"].font = NOTE
    ws["A2"].fill = NOTE_FILL
    ws["A2"].alignment = Alignment(wrap_text=True, vertical="center")
    ws.merge_cells(start_row=2, start_column=1, end_row=2, end_column=span)
    ws.row_dimensions[2].height = 34
    return ws


def readme(wb, title, subtitle, blocks):
    ws = wb.create_sheet("อ่านก่อน")
    ws.sheet_view.showGridLines = False
    ws.column_dimensions["A"].width = 5
    ws.column_dimensions["B"].width = 42
    ws.column_dimensions["C"].width = 86
    ws["B1"] = title
    ws["B1"].font = Font(name=F, size=18, bold=True, color=BRAND)
    ws["B2"] = subtitle
    ws["B2"].font = NOTE
    r = 4
    for kind, left, right in blocks:
        if kind == "h":
            ws.cell(row=r, column=2, value=left).font = H2
            r += 1
            continue
        a = ws.cell(row=r, column=1, value={"warn": "!", "ok": "✓"}.get(kind, ""))
        a.font = Font(name=F, size=11, bold=True, color=NEG if kind == "warn" else POS)
        b = ws.cell(row=r, column=2, value=left)
        b.font = BOLD if kind == "warn" else BODY
        b.alignment = Alignment(wrap_text=True, vertical="top")
        c = ws.cell(row=r, column=3, value=right)
        c.font = NOTE
        c.alignment = Alignment(wrap_text=True, vertical="top")
        if kind == "warn":
            for col in (1, 2, 3):
                ws.cell(row=r, column=col).fill = WARN_FILL
        ws.row_dimensions[r].height = 30
        r += 1
    return ws


def dropdown(ws, col, options, first, last):
    dv = DataValidation(type="list", formula1='"' + ",".join(options) + '"', allow_blank=True)
    dv.error = "เลือกจากรายการเท่านั้น"
    dv.errorTitle = "ค่าไม่ถูกต้อง"
    ws.add_data_validation(dv)
    dv.add(f"{col}{first}:{col}{last}")


# =====================================================================
# ไฟล์ 1 — ผังบัญชีและหมวดงบ
# =====================================================================
def build_coa_file(d, out):
    wb = Workbook()
    wb.remove(wb.active)

    readme(
        wb,
        "ไฟล์ 1 · ผังบัญชีและหมวดงบ (PL / BS)",
        "ตั้งค่าว่าระบบมีบัญชีอะไร และแต่ละบัญชีไปโผล่บรรทัดไหนในงบ",
        [
            ("h", "ไฟล์นี้ใช้ทำอะไร", ""),
            ("", "ชีท 'ผังบัญชี'", "รายชื่อบัญชีทั้งหมด แก้ชื่อได้ เพิ่มบัญชีใหม่ได้ ปิดการใช้งานได้"),
            ("", "ชีท 'โครงงบดุล'", "บรรทัดในงบดุล และบัญชีที่รวมอยู่ในแต่ละบรรทัด — สลับลำดับหรือรวม/แยกบรรทัดได้"),
            ("", "ชีท 'โครงงบกำไรขาดทุน'", "เหมือนกัน แต่ของงบ P&L"),
            ("", "ชีท 'ตารางกฎหมวดย่อย'", "คู่บัญชีของทุกประเภทรายการ — ชีทนี้ให้ตรวจ ไม่ใช่ช่องกรอก"),
            ("h", "", ""),
            ("h", "กติกาที่ต้องรู้ก่อนแก้", ""),
            (
                "warn",
                "ทุกบัญชีต้องอยู่ในงบใดงบหนึ่ง",
                "ถ้าเพิ่มบัญชีใหม่ในชีท 'ผังบัญชี' ต้องไปใส่ในชีทโครงงบด้วย "
                "ไม่งั้นยอดของบัญชีนั้นจะหายจากรายงานโดยไม่มีอะไรฟ้อง — ระบบมีเทสต์กันไว้ จะ import ไม่ผ่าน",
            ),
            (
                "warn",
                "ห้ามใส่บัญชีเดียวกันสองบรรทัด",
                "จะถูกนับสองรอบ ทำให้ยอดรวมบวมแต่งบยัง 'ลงตัว' อยู่ — หาเจอยากที่สุด",
            ),
            (
                "warn",
                "รหัสบัญชีที่เคยมีรายการแล้ว ห้ามเปลี่ยนรหัส",
                "เปลี่ยนชื่อได้ตลอด แต่เปลี่ยนรหัสจะทำให้รายการเก่าชี้ไปบัญชีที่ไม่มีอยู่ "
                "ถ้าไม่ใช้แล้วให้ตั้ง 'ใช้งาน' = ไม่ แทนการลบ",
            ),
            (
                "warn",
                "ชีทตารางกฎแก้ในไฟล์นี้ไม่ได้",
                "คู่บัญชี (เดบิต/เครดิต) ของแต่ละหมวดถูกบังคับด้วยเทสต์ในโค้ด "
                "ถ้าต้องเพิ่มหรือแก้ประเภทรายการ บอกผม จะทำให้พร้อมเทสต์",
            ),
            ("h", "", ""),
            ("h", "สิ่งที่ผมเพิ่มให้ใหม่ (เดิมไม่มี ตั้งยอดตั้งต้นไม่ได้)", ""),
            ("ok", "3300 กำไรสะสม", "เดิมมีแต่ 'ทุนตั้งต้น' ถ้าไม่มีบัญชีนี้ กำไรที่สะสมมาก่อนวันตัดยอดต้องไปกองรวมกับทุน ซึ่งอ่านไม่ออกว่าเงินส่วนไหนลงทุนไป ส่วนไหนหามาได้"),
            ("ok", "5910 ขาดทุนจากการขายทรัพย์", "เดิมขาดทุนจากการขายไปกองใน 'ค่าใช้จ่ายอื่น' ปนกับค่าใช้จ่ายจร — ตอนนี้แยกบรรทัด คู่กับ 4300 กำไรจากการขายทรัพย์"),
            ("h", "", ""),
            ("", "ช่องหัวสีเทา = ระบบคำนวณหรือกำหนดให้", "แก้ได้แต่ต้องเข้าใจผลกระทบ"),
            ("", "ช่องหัวสีแดงอ่อน = บังคับ", "เว้นว่างไม่ได้"),
        ],
    )

    # ---------- ผังบัญชี ----------
    ws = titled(
        wb,
        "ผังบัญชี",
        "ผังบัญชี (Chart of Accounts)",
        f"{len(d['accounts'])} บัญชี · เพิ่มบรรทัดใหม่ต่อท้ายได้ "
        "· เพิ่มแล้วต้องไปใส่ในชีทโครงงบด้วย ไม่งั้นยอดจะหายจากรายงาน",
        span=10,
    )
    cols = [
        ("รหัส", True, "4 หลัก · 1xxx สินทรัพย์ 2xxx หนี้สิน 3xxx ทุน 4xxx รายได้ 5xxx ค่าใช้จ่าย"),
        ("ชื่อบัญชี (ไทย)", True, "ชื่อที่จะแสดงบนหน้าจอและในงบ"),
        ("ชื่อบัญชี (อังกฤษ)", False, "ไม่บังคับ ใช้ตอนทำงบภาษาอังกฤษ"),
        ("ประเภท", True, "กำหนดว่าเดบิตเพิ่มหรือลด — เลือกจากรายการ"),
        ("งบ", "lock", "คำนวณจากประเภท · 1-3xxx = BS · 4-5xxx = PL"),
        ("หมวดในงบ", True, "ต้องตรงกับชีทโครงงบ"),
        ("บรรทัดในงบ", True, "ต้องตรงกับชีทโครงงบ"),
        ("ผูกบัญชีธนาคาร", "lock", "บัญชี 11xx บังคับผูกบัญชีเงินทุกรายการ (Money Invariant 2)"),
        ("ตั้งค้างได้", False, "บัญชีลูกหนี้/เจ้าหนี้ที่ใช้ตอนติ๊ก 'ยังไม่ได้รับ-จ่ายเงิน'"),
        ("ใช้งาน", True, "ไม่ = ซ่อนจากตัวเลือกในฟอร์ม แต่รายงานย้อนหลังยังเห็น"),
    ]
    widths = {
        "รหัส": 9, "ชื่อบัญชี (ไทย)": 34, "ชื่อบัญชี (อังกฤษ)": 28, "ประเภท": 15,
        "งบ": 8, "หมวดในงบ": 30, "บรรทัดในงบ": 30, "ผูกบัญชีธนาคาร": 14,
        "ตั้งค้างได้": 12, "ใช้งาน": 10,
    }
    head_row(ws, 4, cols, widths)

    accrual_by_code = {}
    for s in d["subs"]:
        if s["accrualCoa"]:
            accrual_by_code.setdefault(s["accrualCoa"], set()).add(s["typeLabel"])

    r = 6
    for a in d["accounts"]:
        vals = [
            a["code"], a["nameTh"], a["nameEn"], TYPE_TH[a["type"]], a["statement"],
            a["group"], a["line"],
            "ใช่" if a["code"].startswith("11") else "",
            "ใช่" if a["code"] in accrual_by_code else "",
            "ใช่",
        ]
        for i, v in enumerate(vals, start=1):
            c = ws.cell(row=r, column=i, value=v)
            c.font = LOCKED if i in (5, 8) else BODY
            c.border = BORDER
            if i in (5, 8):
                c.fill = LOCK_FILL
        r += 1
    last = r + 40
    dropdown(ws, "D", list(TYPE_TH.values()), 6, last)
    dropdown(ws, "I", ["ใช่"], 6, last)
    dropdown(ws, "J", ["ใช่", "ไม่"], 6, last)
    ws.freeze_panes = "C6"
    ws.auto_filter.ref = f"A4:J{r - 1}"

    # ---------- โครงงบดุล ----------
    ws = titled(
        wb,
        "โครงงบดุล",
        "โครงงบดุล (Balance Sheet)",
        "เรียงจากบนลงล่างตามที่จะแสดงในงบ · ช่อง 'รหัสบัญชีที่รวม' ใส่ได้หลายรหัส คั่นด้วยเครื่องหมายจุลภาค",
        span=6,
    )
    head_row(ws, 4, [
        ("ลำดับ", True, "เลขน้อยอยู่บน"),
        ("ฝั่ง", True, "สินทรัพย์ / หนี้สิน / ส่วนของเจ้าของ"),
        ("หมวด", True, "หัวข้อกลุ่มในงบ"),
        ("บรรทัดในงบ", True, "ชื่อบรรทัดที่ลูกพี่จะเห็น"),
        ("รหัสบัญชีที่รวม", True, "คั่นด้วย , เช่น 1200, 1210"),
        ("หัก (contra)", False, "ใส่ 'ใช่' ถ้าบรรทัดนี้ต้องเอาไปหักออกจากกลุ่ม เช่น เงินถอนของเจ้าของ"),
    ], {"ลำดับ": 8, "ฝั่ง": 18, "หมวด": 34, "บรรทัดในงบ": 34, "รหัสบัญชีที่รวม": 26, "หัก (contra)": 14})
    r, order = 6, 10
    for g in d["bsLayout"]:
        for l in g["lines"]:
            vals = [order, TYPE_TH[g["side"]], g["group"], l["line"],
                    ", ".join(l["codes"]), "ใช่" if l.get("contra") else ""]
            for i, v in enumerate(vals, start=1):
                c = ws.cell(row=r, column=i, value=v)
                c.font = BODY
                c.border = BORDER
            r += 1
            order += 10
    dropdown(ws, "B", list(TYPE_TH.values())[:3], 6, r + 30)
    dropdown(ws, "F", ["ใช่"], 6, r + 30)
    ws.freeze_panes = "A6"

    # ---------- โครงงบกำไรขาดทุน ----------
    ws = titled(
        wb,
        "โครงงบกำไรขาดทุน",
        "โครงงบกำไรขาดทุน (P&L)",
        "กำไรสุทธิ = รายได้ − ค่าใช้จ่าย − ต้นทุนทางการเงิน · ลำดับในไฟล์นี้คือลำดับที่แสดงในงบ",
        span=5,
    )
    head_row(ws, 4, [
        ("ลำดับ", True, "เลขน้อยอยู่บน"),
        ("ส่วน", True, "รายได้ / ค่าใช้จ่าย / ต้นทุนทางการเงิน"),
        ("บรรทัดในงบ", True, "ชื่อบรรทัดที่ลูกพี่จะเห็น"),
        ("รหัสบัญชีที่รวม", True, "คั่นด้วย , เช่น 4200, 4210"),
        ("เครื่องหมาย", "lock", "รายได้ = บวก · ค่าใช้จ่าย = หัก"),
    ], {"ลำดับ": 8, "ส่วน": 22, "บรรทัดในงบ": 34, "รหัสบัญชีที่รวม": 34, "เครื่องหมาย": 14})
    r, order = 6, 10
    sections = []
    for s in d["plLayout"]:
        sections.append(s["section"])
        for l in s["lines"]:
            vals = [order, s["section"], l["line"], ", ".join(l["codes"]),
                    "บวก" if s["kind"] == "revenue" else "หัก"]
            for i, v in enumerate(vals, start=1):
                c = ws.cell(row=r, column=i, value=v)
                c.font = LOCKED if i == 5 else BODY
                c.border = BORDER
                if i == 5:
                    c.fill = LOCK_FILL
            r += 1
            order += 10
    dropdown(ws, "B", sections, 6, r + 30)
    ws.freeze_panes = "A6"

    # ---------- ตารางกฎหมวดย่อย (อ่านเท่านั้น) ----------
    ws = titled(
        wb,
        "ตารางกฎหมวดย่อย",
        "ตารางกฎประเภทรายการ — สำหรับตรวจ ไม่ใช่ช่องกรอก",
        f"{len(d['subs'])} หมวดย่อย · คู่บัญชีของทุกหมวดถูกบังคับด้วยเทสต์ในโค้ด "
        "ถ้าเห็นตรงไหนผิดหลักบัญชี บอกผม จะแก้พร้อมเทสต์",
        span=11,
    )
    head_row(ws, 4, [
        ("ประเภทรายการ", "lock", ""),
        ("หมวดย่อย", "lock", ""),
        ("เดบิต", "lock", "บัญชีฝั่งเดบิต"),
        ("เครดิต", "lock", "บัญชีฝั่งเครดิต"),
        ("กำไร", "lock", "บัญชีรับรู้กำไรจากการขาย"),
        ("ขาดทุน", "lock", "บัญชีรับรู้ขาดทุนจากการขาย"),
        ("ดอกเบี้ย", "lock", "บัญชีดอกเบี้ยตอนแยกเงินต้น"),
        ("ค้างรับ/ค้างจ่าย", "lock", "บัญชีที่ใช้ตอนยังไม่ได้รับ-จ่ายเงิน"),
        ("กระแสเงินสด", "lock", ""),
        ("ต้องกรอกเพิ่ม", "lock", ""),
        ("คำอธิบายภาษาคน", "lock", ""),
    ], {"ประเภทรายการ": 22, "หมวดย่อย": 32, "เดบิต": 9, "เครดิต": 9, "กำไร": 9,
        "ขาดทุน": 9, "ดอกเบี้ย": 10, "ค้างรับ/ค้างจ่าย": 16, "กระแสเงินสด": 14,
        "ต้องกรอกเพิ่ม": 30, "คำอธิบายภาษาคน": 72})
    cf_th = {"operating": "ดำเนินงาน", "investing": "ลงทุน", "financing": "จัดหาเงิน", "none": "ไม่นับ"}
    r = 6
    for s in d["subs"]:
        vals = [s["typeLabel"], s["label"], s["dr"], s["cr"], s["gainCoa"], s["lossCoa"],
                s["interestCoa"], s["accrualCoa"], cf_th[s["cashflow"]], s["requires"], s["plain"]]
        for i, v in enumerate(vals, start=1):
            c = ws.cell(row=r, column=i, value=v)
            c.font = LOCKED
            c.fill = LOCK_FILL
            c.border = BORDER
            c.alignment = Alignment(wrap_text=(i == 11), vertical="top")
        r += 1
    ws.freeze_panes = "C6"
    ws.auto_filter.ref = f"A4:K{r - 1}"

    wb.save(out)
    return out


# =====================================================================
# ไฟล์ 2 — ยอดตั้งต้นงบดุล แยกตามผู้ถือ
# =====================================================================
def build_opening_file(d, out):
    wb = Workbook()
    wb.remove(wb.active)

    # เรียงตามลำดับที่แสดงในงบ ไม่ใช่ลำดับในผังบัญชี — คนกรอกจะไล่จากบนลงล่างได้
    order = {}
    n = 0
    contra_codes = set()
    for g in d["bsLayout"]:
        for l in g["lines"]:
            for code in l["codes"]:
                order[code] = n
                n += 1
                if l.get("contra"):
                    contra_codes.add(code)

    # ไม่เอาบัญชี contra (เงินถอนของเจ้าของ) เข้ามาในยอดตั้งต้น
    # มันเป็นยอดที่เกิดระหว่างงวด ไม่ใช่ยอดคงเหลือต้นงวด — ถอนสะสมถูกหักอยู่ในกำไรสะสมแล้ว
    # ถ้าใส่เป็นอีกบรรทัดจะถูกนับสองรอบ
    bs = sorted(
        (a for a in d["accounts"] if a["isBs"] and a["code"] not in contra_codes),
        key=lambda a: order[a["code"]],
    )
    owners = d["owners"]
    banks_by_owner = {}
    for b in d["banks"]:
        banks_by_owner.setdefault(b["ownerId"], []).append(b)

    readme(
        wb,
        "ไฟล์ 2 · ยอดตั้งต้นงบดุล แยกตามผู้ถือ",
        "กรอกยอดคงเหลือของทุกบัญชี ณ วันตัดยอด ทีละผู้ถือ — ระบบจะใช้เป็นจุดเริ่มของทุกรายงาน",
        [
            ("h", "วันตัดยอด", ""),
            ("", f"ใช้ {CUTOFF} ทุกชีท", "ถ้าสรุปไม่ทันจริงๆ เลื่อนเป็น 31/10/2026 ได้ แต่ต้องเลื่อนทั้งไฟล์พร้อมกัน ห้ามชีทละวัน"),
            ("h", "", ""),
            ("h", "กรอกอย่างไร", ""),
            ("", "หนึ่งชีทต่อหนึ่งผู้ถือ", f"{len(owners)} ชีท: {' · '.join(o['name'] for o in owners)}"),
            ("", "กรอกช่อง 'ยอดตั้งต้น' ช่องเดียว", "ใส่จำนวนบวก ไม่ต้องคิดว่าเป็นเดบิตหรือเครดิต ระบบรู้จากประเภทบัญชี · ข้อยกเว้นเดียวคือ 3300 กำไรสะสม ที่ติดลบได้ถ้าขาดทุนสะสม — ใส่ติดลบได้เลย"),
            ("", "บัญชีที่ไม่มียอด เว้นว่างไว้", "ไม่ต้องใส่ 0"),
            ("", "ชีท 'รวมทุกผู้ถือ'", "คำนวณให้อัตโนมัติ ไม่ต้องกรอก ใช้ตรวจว่ายอดรวมกองกลางตรงกับที่ลูกพี่รู้"),
            ("h", "", ""),
            ("h", "สามข้อที่ต้องเข้าใจก่อนกรอก", ""),
            (
                "warn",
                "ใส่ราคาทุน ไม่ใช่ราคาประเมิน",
                "งบดุลตั้งต้นลงตามราคาทุน/ตามบัญชี · ราคาประเมินกับราคาตลาดใส่ในชีท 'ทรัพย์สิน' "
                "ของไฟล์เทมเพลตข้อมูลตั้งต้น (คอลัมน์ 'มูลค่าปัจจุบัน') "
                "ถ้าเอาราคาประเมินมาใส่ที่นี่ งบจะไม่ลงตัว เพราะยังไม่มีบัญชีส่วนเกินทุนจากการตีราคา",
            ),
            (
                "warn",
                "เงินสดต้องแยกทีละบัญชีธนาคาร",
                "แต่ละชีทมีตารางย่อยให้กรอกยอดแต่ละบัญชี แล้วบรรทัด 1100 จะรวมให้เอง "
                "ระบบบังคับว่าทุกบรรทัดเงินสดต้องผูกบัญชีจริง (Money Invariant 2)",
            ),
            (
                "warn",
                "แต่ละชีทต้องลงตัวในตัวเอง",
                "สินทรัพย์ − หนี้สิน − ส่วนของเจ้าของ = 0 · ช่องตรวจล่างสุดจะเป็นสีเขียวเมื่อลงตัว "
                "ถ้ายังไม่ตรง ใส่ผลต่างที่บรรทัด 'ผลต่างรอกระทบยอด' อย่าไปดัดตัวเลขอื่นให้ตรง",
            ),
            ("h", "", ""),
            ("h", "ทำไมไม่มีบรรทัด 'เงินถอนของเจ้าของ'", ""),
            (
                "",
                "เงินถอนสะสมถูกหักอยู่ในกำไรสะสมแล้ว",
                "3200 เงินถอนของเจ้าของ เป็นยอดที่เกิดระหว่างงวด ไม่ใช่ยอดคงเหลือ ณ วันตั้งต้น "
                "· ถ้าใส่เป็นอีกบรรทัดจะถูกนับสองรอบ ส่วนของเจ้าของจะบวมเท่าที่ถอนออกไป "
                "· การถอนหลังวันตัดยอดบันทึกเป็นรายการปกติในระบบ",
            ),
            ("h", "", ""),
            ("h", "ผลต่างรอกระทบยอด", ""),
            (
                "",
                "ใส่ที่บรรทัด 3300 กำไรสะสม ชั่วคราว",
                "แล้วเขียนไว้ในช่องหมายเหตุว่าเป็นผลต่างเท่าไร · พอสรุปของจริงได้แล้วค่อยแยกว่า "
                "ส่วนไหนเป็นทุน (3100) ส่วนไหนเป็นเงินกู้กรรมการ (2300) แล้ว import ทับได้เลย",
            ),
            ("h", "", ""),
            ("h", "หุ้น/กองทุน ใช้ FIFO", ""),
            (
                "",
                "ชีท 'พอร์ตลงทุน (รายล็อต)'",
                "FIFO ต้องรู้ว่าซื้อล็อตไหนก่อน จึงต้องกรอก **ทีละล็อต** (วันที่ซื้อ + จำนวน + ราคาต่อหน่วย) "
                "ไม่ใช่ต้นทุนเฉลี่ย · ยอดรวมของชีทนี้ต้องเท่ากับบรรทัด 1700 ในชีทของผู้ถือคนนั้น",
            ),
        ],
    )

    def owner_sheet(o):
        short = o["name"].split(" (")[0]
        ws = titled(
            wb,
            f"BS-{short}"[:31],
            f"ยอดตั้งต้นงบดุล — {o['name']}",
            f"ณ วันที่ {CUTOFF} · ราคาทุน/ตามบัญชี "
            + ("· ผู้ถือนิติบุคคล: ทุกรายการต้องมีหลักฐาน" if o["policy"] == "corporate_strict"
               else "· ถือในชื่อบุคคล แต่ยังเป็นกองกลางของครอบครัว"),
            span=6,
        )
        head_row(ws, 4, [
            ("รหัส", "lock", ""),
            ("ชื่อบัญชี", "lock", ""),
            ("ฝั่ง", "lock", ""),
            ("หมวดในงบ", "lock", ""),
            ("ยอดตั้งต้น", True, "ใส่จำนวนบวกเสมอ · ไม่มียอดให้เว้นว่าง"),
            ("หมายเหตุ / ที่มาของตัวเลข", False, "เช่น 'ยอด statement 30/09' หรือ 'ตามสัญญาเลขที่ ...'"),
        ], {"รหัส": 9, "ชื่อบัญชี": 36, "ฝั่ง": 16, "หมวดในงบ": 32, "ยอดตั้งต้น": 18,
            "หมายเหตุ / ที่มาของตัวเลข": 46})

        r = 6
        rows_by_side = {"asset": [], "liability": [], "equity": []}
        row_of_code = {}
        for a in bs:
            vals = [a["code"], a["nameTh"], TYPE_TH[a["type"]], a["group"], None, None]
            for i, v in enumerate(vals, start=1):
                c = ws.cell(row=r, column=i, value=v)
                c.border = BORDER
                if i <= 4:
                    c.font = LOCKED
                    c.fill = LOCK_FILL
                else:
                    c.font = BODY
                if i == 5:
                    c.number_format = MONEY
            rows_by_side[a["type"]].append(r)
            row_of_code[a["code"]] = r
            r += 1

        # ---- ผลรวมแต่ละฝั่ง ----
        r += 1
        sum_rows = {}
        for side, label in (("asset", "รวมสินทรัพย์"), ("liability", "รวมหนี้สิน"), ("equity", "รวมส่วนของเจ้าของ")):
            ws.cell(row=r, column=2, value=label).font = BOLD
            cells = ",".join(f"E{x}" for x in rows_by_side[side])
            c = ws.cell(row=r, column=5, value=f"=SUM({cells})")
            c.font = BOLD
            c.number_format = MONEY
            for col in range(1, 7):
                ws.cell(row=r, column=col).fill = SUM_FILL
                ws.cell(row=r, column=col).border = BORDER
            sum_rows[side] = r
            r += 1

        # ---- ช่องตรวจ ----
        r += 1
        ws.cell(row=r, column=2, value="ตรวจ: สินทรัพย์ − หนี้สิน − ส่วนของเจ้าของ").font = BOLD
        chk = ws.cell(row=r, column=5,
                      value=f"=E{sum_rows['asset']}-E{sum_rows['liability']}-E{sum_rows['equity']}")
        chk.font = BOLD
        chk.number_format = MONEY
        ws.cell(row=r, column=6, value="ต้องเป็น 0 — ถ้าไม่ใช่ ใส่ผลต่างที่ 3300 กำไรสะสม แล้วเขียนหมายเหตุไว้").font = NOTE
        for col in range(1, 7):
            ws.cell(row=r, column=col).border = BORDER
        cell = f"E{r}"
        ws.conditional_formatting.add(cell, CellIsRule(operator="equal", formula=["0"], fill=OK_FILL,
                                                       font=Font(name=F, size=11, bold=True, color=POS)))
        ws.conditional_formatting.add(cell, CellIsRule(operator="notEqual", formula=["0"], fill=BAD_FILL,
                                                       font=Font(name=F, size=11, bold=True, color=NEG)))
        check_row = r

        # ---- แยกเงินสดตามบัญชีธนาคาร ----
        r += 3
        ws.cell(row=r, column=2, value="แยกยอดเงินสดตามบัญชี (ต้องรวมได้เท่าบรรทัด 1100)").font = H2
        ws.cell(row=r + 1, column=2,
                value="บัญชีที่ระบบมีอยู่แล้วเติมให้ · บัญชีใหม่กรอกในแถวว่างด้านล่าง · ทุกบาทของบรรทัด 1100 ต้องมีบัญชีรองรับ").font = NOTE
        r += 1
        r += 1
        for lab in ("บัญชี", "ธนาคาร / ช่องทาง", "เลขท้าย", "ยอดตั้งต้น"):
            c = ws.cell(row=r, column=2 + ("บัญชี", "ธนาคาร / ช่องทาง", "เลขท้าย", "ยอดตั้งต้น").index(lab))
            c.value = lab
            c.font = HEAD
            c.fill = REQ_FILL if lab == "ยอดตั้งต้น" else LOCK_FILL
            c.border = BORDER
        r += 1
        bank_rows = []
        for b in banks_by_owner.get(o["id"], []):
            ws.cell(row=r, column=2, value=b["name"]).font = LOCKED
            ws.cell(row=r, column=3, value=b["bank"]).font = LOCKED
            ws.cell(row=r, column=4, value=b["last4"]).font = LOCKED
            c = ws.cell(row=r, column=5)
            c.font = BODY
            c.number_format = MONEY
            for col in range(2, 6):
                ws.cell(row=r, column=col).border = BORDER
            bank_rows.append(r)
            r += 1
        # แถวว่างสำหรับบัญชีที่ยังไม่มีในระบบ — ถ้าไม่มีที่ให้กรอก คนจะยัดยอดรวมลงบรรทัด 1100
        # แล้วได้เงินสดที่ไม่ผูกบัญชีจริง ซึ่งคือ "เงินลอย" ที่ Money Invariant 2 ห้าม
        for _ in range(6):
            ws.cell(row=r, column=2, value=None).font = BODY
            for col in range(2, 6):
                c = ws.cell(row=r, column=col)
                c.border = BORDER
                if col == 5:
                    c.number_format = MONEY
            ws.cell(row=r, column=6, value="← บัญชีใหม่ที่ยังไม่มีในระบบ กรอกชื่อ+ธนาคาร+ยอด").font = NOTE
            bank_rows.append(r)
            r += 1
        if bank_rows:
            ws.cell(row=r, column=2, value="รวมเงินสด").font = BOLD
            c = ws.cell(row=r, column=5, value=f"=SUM(E{bank_rows[0]}:E{bank_rows[-1]})")
            c.font = BOLD
            c.number_format = MONEY
            ws.cell(row=r, column=6,
                    value=f"ต้องเท่ากับบรรทัด 1100 (แถว {row_of_code['1100']})").font = NOTE
            for col in range(2, 7):
                ws.cell(row=r, column=col).fill = SUM_FILL
                ws.cell(row=r, column=col).border = BORDER
            r += 1
            ws.cell(row=r, column=2, value="ตรวจ: ผลต่างกับบรรทัด 1100").font = BOLD
            diff = ws.cell(row=r, column=5, value=f"=E{r - 1}-E{row_of_code['1100']}")
            diff.font = BOLD
            diff.number_format = MONEY
            ws.conditional_formatting.add(f"E{r}", CellIsRule(operator="equal", formula=["0"], fill=OK_FILL))
            ws.conditional_formatting.add(f"E{r}", CellIsRule(operator="notEqual", formula=["0"], fill=BAD_FILL))
            for col in range(2, 6):
                ws.cell(row=r, column=col).border = BORDER

        ws.freeze_panes = "A6"
        return sum_rows, check_row

    per_owner = {}
    for o in owners:
        per_owner[o["id"]] = owner_sheet(o)

    # แถวของบัญชีระหว่างกัน เท่ากันทุกชีทเพราะเรียงจากโครงงบชุดเดียว
    ic_row = {c: 6 + next(i for i, a in enumerate(bs) if a["code"] == c) for c in ("1310", "2310")}

    # ---------- รวมทุกผู้ถือ ----------
    ws = titled(
        wb,
        "รวมทุกผู้ถือ",
        f"รวมทุกผู้ถือ — {d['consolidatedName']}",
        "คำนวณจากชีทของแต่ละผู้ถือ ไม่ต้องกรอก · ใช้ตรวจว่ายอดรวมกองกลางตรงกับที่ลูกพี่รู้",
        span=3 + len(owners),
    )
    head = [("บัญชี", "lock", "")] + [(o["name"].split(" (")[0], "lock", "") for o in owners] + [("รวม", "lock", "")]
    head_row(ws, 4, head, {"บัญชี": 40, "รวม": 20})
    r = 6
    for side, label in (("asset", "รวมสินทรัพย์"), ("liability", "รวมหนี้สิน"), ("equity", "รวมส่วนของเจ้าของ")):
        ws.cell(row=r, column=1, value=label).font = BOLD
        ws.cell(row=r, column=1).border = BORDER
        for i, o in enumerate(owners, start=2):
            short = o["name"].split(" (")[0]
            srow = per_owner[o["id"]][0][side]
            c = ws.cell(row=r, column=i, value=f"='BS-{short}'!E{srow}")
            c.font = BODY
            c.number_format = MONEY
            c.border = BORDER
        c = ws.cell(row=r, column=2 + len(owners),
                    value=f"=SUM(B{r}:{get_column_letter(1 + len(owners))}{r})")
        c.font = BOLD
        c.number_format = MONEY
        c.border = BORDER
        r += 1

    r += 1
    ws.cell(row=r, column=1, value="ตรวจ: ทุกชีทลงตัวหรือยัง").font = BOLD
    for i, o in enumerate(owners, start=2):
        short = o["name"].split(" (")[0]
        c = ws.cell(row=r, column=i, value=f"='BS-{short}'!E{per_owner[o['id']][1]}")
        c.font = BOLD
        c.number_format = MONEY
        c.border = BORDER
        ws.conditional_formatting.add(f"{get_column_letter(i)}{r}",
                                      CellIsRule(operator="equal", formula=["0"], fill=OK_FILL))
        ws.conditional_formatting.add(f"{get_column_letter(i)}{r}",
                                      CellIsRule(operator="notEqual", formula=["0"], fill=BAD_FILL))
    # ---- ช่องตรวจรายการระหว่างกัน ----
    # แต่ละชีทลงตัวได้ทั้งที่งบรวมไม่ลงตัว ถ้าฝ่ายหนึ่งบันทึกลูกหนี้ระหว่างกันแต่อีกฝ่ายไม่บันทึกเจ้าหนี้
    # ข้อความเตือนอย่างเดียวไม่พอ ต้องมีเลขให้เห็น (Money Invariant 6)
    r += 2
    ws.cell(row=r, column=1, value="รายการระหว่างกัน — ต้องหักกลบกันได้พอดี").font = H2
    r += 1
    for label, code in (("รวมลูกหนี้ระหว่างกัน (1310)", "1310"), ("รวมเจ้าหนี้ระหว่างกัน (2310)", "2310")):
        ws.cell(row=r, column=1, value=label).font = BODY
        ws.cell(row=r, column=1).border = BORDER
        for i, o in enumerate(owners, start=2):
            short = o["name"].split(" (")[0]
            c = ws.cell(row=r, column=i, value=f"='BS-{short}'!E{ic_row[code]}")
            c.font = BODY
            c.number_format = MONEY
            c.border = BORDER
        c = ws.cell(row=r, column=2 + len(owners),
                    value=f"=SUM(B{r}:{get_column_letter(1 + len(owners))}{r})")
        c.font = BOLD
        c.number_format = MONEY
        c.border = BORDER
        r += 1

    ws.cell(row=r, column=1, value="ตรวจ: ลูกหนี้ − เจ้าหนี้ ระหว่างกัน").font = BOLD
    ws.cell(row=r, column=1).border = BORDER
    tot = get_column_letter(2 + len(owners))
    chk = ws.cell(row=r, column=2 + len(owners), value=f"={tot}{r - 2}-{tot}{r - 1}")
    chk.font = BOLD
    chk.number_format = MONEY
    chk.border = BORDER
    ws.conditional_formatting.add(f"{tot}{r}",
                                  CellIsRule(operator="equal", formula=["0"], fill=OK_FILL))
    ws.conditional_formatting.add(f"{tot}{r}",
                                  CellIsRule(operator="notEqual", formula=["0"], fill=BAD_FILL))
    r += 2
    for line in [
        "ถ้าช่องตรวจไม่เป็น 0 แปลว่ามีฝ่ายเดียวที่บันทึก — อีกฝ่ายลืมบันทึกหรือใส่ยอดไม่ตรง",
        "งบรวมจะตัดสองบัญชีนี้ออก ยอดกองกลางจึงต้องไม่เปลี่ยนเพราะรายการระหว่างกัน",
    ]:
        c = ws.cell(row=r, column=1, value=line)
        c.font = NOTE
        c.fill = WARN_FILL
        ws.merge_cells(start_row=r, start_column=1, end_row=r, end_column=2 + len(owners))
        r += 1

    # ---------- พอร์ตลงทุนรายล็อต (FIFO) ----------
    ws = titled(
        wb,
        "พอร์ตลงทุน (รายล็อต)",
        "พอร์ตหลักทรัพย์ — กรอกทีละล็อต (FIFO)",
        "ลูกพี่เลือก FIFO จึงต้องรู้ว่าล็อตไหนซื้อก่อน · กรอกทุกล็อตที่ยังถืออยู่ ณ วันตัดยอด "
        "· ยอดรวม 'ต้นทุนรวม' ของแต่ละผู้ถือ ต้องเท่ากับบรรทัด 1700 ในชีทของผู้ถือคนนั้น",
        span=9,
    )
    head_row(ws, 4, [
        ("ถือในชื่อ", True, "ต้องตรงกับชื่อชีทผู้ถือ"),
        ("ประเภท", True, "หุ้นไทย / หุ้น US / ETF / กองทุน / Crypto / ทองคำ / พันธบัตร"),
        ("ชื่อ/รหัส", True, "เช่น PTT, VOO, BTC"),
        ("วันที่ซื้อ", True, "FIFO ใช้วันนี้เรียงลำดับ — ถ้าไม่มีวันที่ คำนวณ FIFO ไม่ได้"),
        ("จำนวนหน่วย", True, "ที่ยังถืออยู่ในล็อตนี้ ณ วันตัดยอด"),
        ("ราคาต่อหน่วย", True, "ราคาที่ซื้อจริงของล็อตนี้ ไม่ใช่ราคาเฉลี่ย"),
        ("ค่าธรรมเนียมซื้อ", False, "รวมเป็นต้นทุน ถ้ามี"),
        ("ต้นทุนรวม", "lock", "คำนวณให้ = จำนวน × ราคา + ค่าธรรมเนียม"),
        ("สกุลเงิน", True, "THB / USD"),
    ], {"ถือในชื่อ": 20, "ประเภท": 16, "ชื่อ/รหัส": 16, "วันที่ซื้อ": 14, "จำนวนหน่วย": 14,
        "ราคาต่อหน่วย": 15, "ค่าธรรมเนียมซื้อ": 16, "ต้นทุนรวม": 18, "สกุลเงิน": 11})
    for r in range(6, 206):
        c = ws.cell(row=r, column=8, value=f"=IF(E{r}=\"\",\"\",E{r}*F{r}+N(G{r}))")
        c.font = LOCKED
        c.fill = LOCK_FILL
        c.number_format = MONEY
        for col in (5, 6, 7):
            ws.cell(row=r, column=col).number_format = MONEY
    dropdown(ws, "A", [o["name"].split(" (")[0] for o in owners], 6, 205)
    dropdown(ws, "B", ["หุ้นไทย", "หุ้น US", "ETF", "กองทุน", "Crypto", "ทองคำ", "พันธบัตร"], 6, 205)
    dropdown(ws, "I", ["THB", "USD"], 6, 205)
    ws.freeze_panes = "D6"

    wb.save(out)
    return out


if __name__ == "__main__":
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    print(build_coa_file(data, "templates/SRI_OS_1_ผังบัญชี_และหมวดงบ.xlsx"))
    print(build_opening_file(data, "templates/SRI_OS_2_ยอดตั้งต้นงบดุล.xlsx"))
