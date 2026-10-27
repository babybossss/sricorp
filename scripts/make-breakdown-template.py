#!/usr/bin/env python3
"""
สร้าง `templates/SRI_OS_3_แจกแจงทรัพย์สิน.xlsx` — ตารางแจกแจงทรัพย์ทีละชิ้น
แล้วสรุปยอด **ต่อผู้ถือ × ต่อบรรทัดงบดุล** ให้เอาไปใส่ในชีทงบดุลของ `SRI_OS_2_ยอดตั้งต้นงบดุล.xlsx`

ทำไมต้องมีไฟล์นี้: ชีท "4 ทะเบียนทรัพย์สิน" ลิสต์ทรัพย์ได้ และ `SRI_OS_2` มีงบดุลต่อผู้ถือ
แต่ **ไม่มียอดรวมที่โยงสองฝั่งเข้าหากัน** → ลูกพี่ต้องบวกเอง และไม่มีอะไรจับได้ถ้าบวกผิด

ทำไมเขียน Office Open XML เอง: เครื่องนี้ไม่มี `openpyxl` และติดตั้งไม่ได้ (network จำกัด)
จึงประกอบ zip + XML ด้วย `zipfile` ของ python ตรงๆ  **ห้ามแก้ไฟล์ .xlsx เดิมด้วยวิธีนี้**
(ไฟล์เดิมมีสูตร/validation/merged cell ที่จะเสียหาย) — สคริปต์นี้จึง *สร้างไฟล์ใหม่ล้วน* เท่านั้น

รัน:   /usr/bin/python3 scripts/make-breakdown-template.py
ตรวจ: npx vitest run src/lib/db/import/__tests__/breakdown-template.test.ts
       (เทสต์อ่านไฟล์ที่สร้างด้วยตัวอ่าน xlsx ของโปรเจกต์เอง `src/lib/db/import/xlsx.ts`)

ตรวจ "สูตรคำนวณได้จริง" (ทำมือ ไม่อยู่ใน CI เพราะต้องมี LibreOffice)
  1. คัดลอกไฟล์ไปชื่อ ASCII แล้วลบค่า cache ออกจากช่องสูตร (regex ตัด `<v>` ที่อยู่หลัง `<f>`)
     — ถ้าไม่ลบ LibreOffice จะโชว์ค่าที่ cache ไว้ ไม่คำนวณใหม่ (ถูกหลอกได้)
  2. `soffice --headless --convert-to 'csv:Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,true,false,false,-1' …`
  3. เทียบค่าที่ LibreOffice คำนวณกับค่าที่สคริปต์ cache ไว้ ต้องตรงกันทุกช่อง
  ทำแล้ว 26/10: ตรงกันทุกช่อง และเมื่อลองใส่ข้อมูลผิด (ไม่ระบุผู้ถือ · ผู้ถือนอกรายชื่อ ·
  รหัสบัญชีนอกรายการ · ค่ารีโนเวทกรอกในบรรทัด 1510) **ช่องตรวจขึ้นเป็นตัวเลขทุกกรณี** ไม่เงียบ

กติกาที่ฝังในไฟล์
  - ทรัพย์แต่ละชิ้นมีต้นทุนของตัวเอง **ห้ามเฉลี่ยข้ามชิ้น** (D-117 — คอนโดคนละห้องคือคนละชิ้น)
  - ค่ารีโนเวทที่บันทึกเป็นทุนไปลงบัญชี 1510 แยกจากต้นทุนทรัพย์ (1500)
  - สูตรในไฟล์เป็นเครื่องมือช่วยลูกพี่เท่านั้น ระบบคำนวณยอดรวมใหม่เองเสมอ (xlsx.ts: formula ≠ ข้อมูลนำเข้า)
"""

import sys
import zipfile
from pathlib import Path

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "templates/SRI_OS_3_แจกแจงทรัพย์สิน.xlsx")

# ---------------------------------------------------------------- ค่าคงที่ของโดเมน
# เรียงตามลำดับชีทงบดุลใน SRI_OS_2 เพื่อให้ลูกพี่ไล่สายตาตรงกันทั้งสองไฟล์
OWNERS = ["SRI Corporation", "สุธี", "ธนากร", "ธนวินท์", "เบ็ญจพร", "สุดจิตต์"]

# (รหัสบัญชี, ชื่อบัญชี) — ตรงกับ src/lib/rules/coa.ts
#
# **รายการนี้เขียนมือและต้องตามผังบัญชีให้ทัน** — ถ้าเพิ่มบัญชีที่ต้องแจกแจง
# รายชิ้นแล้วลืมเติมที่นี่ ไฟล์จะไม่มีที่ให้กรอก แล้วทรัพย์ของบัญชีนั้นจะไม่มี
# ต้นทุนรายชิ้นในสมุด ซึ่งแปลว่า **ขายไม่ออก** (ด่านต้องการต้นทุน > 0)
# เพิ่ม 1320/1520 เมื่อ 27/10 ตามบัญชีใหม่ที่ลูกพี่สั่งแยก
LINES = [
    ("1500", "อสังหาริมทรัพย์เพื่อการลงทุน เพื่อการเช่า"),
    ("1520", "อสังหาริมทรัพย์เพื่อการลงทุน เพื่อการขาย"),
    ("1510", "ค่ารีโนเวท (บันทึกเป็นทุน)"),
    ("1300", "เงินให้กู้ยืม - เงินต้น"),
    ("1320", "เงินให้กู้ยืมแบบมีสินทรัพย์ค้ำประกัน - เงินต้น"),
    ("1400", "เงินลงทุนขายฝาก - เงินต้น"),
    ("1410", "เงินลงทุนจำนอง - เงินต้น"),
    ("1600", "เงินมัดจำจ่าย"),
]
RENO_LINE = "1510"

FIRST_DATA_ROW = 6
LAST_DATA_ROW = 205

DETAIL_SHEET = "แจกแจงทรัพย์"
INTRO_SHEET = "อ่านก่อน"

HEADERS = [
    ("ถือในชื่อ *", True, "เลือกจากรายชื่อผู้ถือ — ต้องตรงกับชื่อชีทงบดุลใน SRI_OS_2"),
    ("รหัสทรัพย์", False, "ถ้ามีในชีท '4 ทะเบียนทรัพย์สิน' ใส่รหัสเดียวกัน"),
    ("ชื่อทรัพย์ *", True, "ระบุให้แยกชิ้นได้จริง เช่น เลขห้อง/เลขโฉนด"),
    ("บรรทัดในงบดุล *", True, "เลือกรหัสบัญชีที่ยอดนี้ไปลง (ดูชื่อบัญชีในตารางสรุปด้านล่าง)"),
    ("ต้นทุน *", True, "ราคาที่ได้มาจริงของชิ้นนี้ ห้ามเฉลี่ยข้ามชิ้น (D-117)"),
    ("ค่ารีโนเวทสะสม", False, "ค่าปรับปรุงที่บันทึกเป็นทุน — ยอดนี้ไปลงบัญชี 1510 ไม่รวมในต้นทุน"),
    ("หมายเหตุ", False, "ที่มาของตัวเลข เอกสารอ้างอิง หรือข้อสงสัย"),
]

# ตัวอย่าง 2 คอนโดของธนากร — รวมต้นทุน 8,000,000 (เทสต์ยืนยันตัวเลขนี้)
SAMPLES = [
    ("ธนากร", "CONDO-A", "คอนโด ลุมพินี ห้อง 1203", "1500", 3_000_000, None, "ตัวอย่าง — ลบได้"),
    ("ธนากร", "CONDO-B", "คอนโด ลุมพินี ห้อง 1507", "1500", 5_000_000, 500_000,
     "ตัวอย่าง — ลบได้ · ค่ารีโนเวท 500,000 ไปลงบัญชี 1510"),
]
# ยอดที่ลูกพี่กรอกว่า "ในงบดุลใส่ไว้เท่าไหร่" สำหรับแถวตัวอย่าง (ผู้ถือ, บรรทัด) -> ยอด
SAMPLE_BS = {("ธนากร", "1500"): 8_000_000, ("ธนากร", RENO_LINE): 500_000}

COLS = "ABCDEFGHIJ"


def col(i: int) -> str:
    """0 -> A"""
    return COLS[i]


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def arr(items) -> str:
    """array constant ของ Excel: {"a";"b"} (คอลัมน์เดียว)"""
    return "{" + ";".join('"' + x + '"' for x in items) + "}"


# ---------------------------------------------------------------- สไตล์
NUMFMT_MONEY = 164
NUMFMT_COUNT = 165

FONTS = [
    '<font><sz val="11"/><color rgb="FF0A2540"/><name val="IBM Plex Sans Thai"/></font>',            # 0 body
    '<font><b/><sz val="16"/><color rgb="FF004AAD"/><name val="IBM Plex Sans Thai"/></font>',         # 1 title
    '<font><b/><sz val="12"/><color rgb="FF0A2540"/><name val="IBM Plex Sans Thai"/></font>',         # 2 h2
    '<font><sz val="10"/><color rgb="FF425466"/><name val="IBM Plex Sans Thai"/></font>',             # 3 note
    '<font><b/><sz val="11"/><color rgb="FF0A2540"/><name val="IBM Plex Sans Thai"/></font>',         # 4 th
    '<font><i/><sz val="11"/><color rgb="FF8792A2"/><name val="IBM Plex Sans Thai"/></font>',         # 5 sample
    '<font><b/><sz val="11"/><color rgb="FFB3261E"/><name val="IBM Plex Sans Thai"/></font>',         # 6 warn
    '<font><b/><sz val="11"/><color rgb="FF004AAD"/><name val="IBM Plex Sans Thai"/></font>',         # 7 brand
]
FILLS = [
    '<fill><patternFill patternType="none"/></fill>',
    '<fill><patternFill patternType="gray125"/></fill>',
    '<fill><patternFill patternType="solid"><fgColor rgb="FFFDF2F4"/><bgColor indexed="64"/></patternFill></fill>',  # 2 บังคับ
    '<fill><patternFill patternType="solid"><fgColor rgb="FFF6F9FC"/><bgColor indexed="64"/></patternFill></fill>',  # 3 ไม่บังคับ
    '<fill><patternFill patternType="solid"><fgColor rgb="FFEEF4FC"/><bgColor indexed="64"/></patternFill></fill>',  # 4 note
    '<fill><patternFill patternType="solid"><fgColor rgb="FFFDF3E4"/><bgColor indexed="64"/></patternFill></fill>',  # 5 warn
    '<fill><patternFill patternType="solid"><fgColor rgb="FFF4F7FB"/><bgColor indexed="64"/></patternFill></fill>',  # 6 sum
    '<fill><patternFill patternType="solid"><fgColor rgb="FFFFFBEA"/><bgColor indexed="64"/></patternFill></fill>',  # 7 input
]
_TH = '<color rgb="FFE3E8EE"/>'
BORDERS = [
    "<border><left/><right/><top/><bottom/><diagonal/></border>",
    f'<border><left style="thin">{_TH}</left><right style="thin">{_TH}</right>'
    f'<top style="thin">{_TH}</top><bottom style="thin">{_TH}</bottom><diagonal/></border>',
]


def xf(font=0, fill=0, border=0, numfmt=0, wrap=False, valign=None, halign=None) -> str:
    a = (
        f'<xf numFmtId="{numfmt}" fontId="{font}" fillId="{fill}" borderId="{border}" xfId="0"'
        f' applyFont="1" applyFill="1" applyBorder="1" applyNumberFormat="1"'
    )
    if wrap or valign or halign:
        al = '<alignment' + (' wrapText="1"' if wrap else "")
        al += f' vertical="{valign}"' if valign else ""
        al += f' horizontal="{halign}"' if halign else ""
        return a + ' applyAlignment="1">' + al + "/></xf>"
    return a + "/>"


# ดัชนีสไตล์ที่โค้ดด้านล่างอ้างถึง
S_DEFAULT = 0
S_TITLE = 1
S_H2 = 2
S_NOTE = 3
S_TH_REQ = 4
S_TH_OPT = 5
S_HINT = 6
S_TEXT = 7
S_MONEY = 8
S_COUNT = 9
S_SAMPLE = 10
S_SAMPLE_MONEY = 11
S_SUM_TEXT = 12
S_SUM_MONEY = 13
S_SUM_COUNT = 14
S_INPUT_MONEY = 15
S_CHK_LABEL = 16
S_CHK_MONEY = 17
S_CHK_COUNT = 18
S_NOTE_FILL = 19
S_BRAND = 20
S_SUM_HEAD = 21

CELL_XFS = [
    xf(),                                                                        # 0
    xf(font=1),                                                                  # 1
    xf(font=2),                                                                  # 2
    xf(font=3, wrap=True, valign="top"),                                         # 3
    xf(font=4, fill=2, border=1, wrap=True, valign="center"),                    # 4
    xf(font=4, fill=3, border=1, wrap=True, valign="center"),                    # 5
    xf(font=3, border=1, wrap=True, valign="top"),                               # 6
    xf(border=1, wrap=False, valign="center"),                                   # 7
    xf(border=1, numfmt=NUMFMT_MONEY, valign="center"),                          # 8
    xf(border=1, numfmt=NUMFMT_COUNT, valign="center"),                          # 9
    xf(font=5, border=1, valign="center"),                                       # 10
    xf(font=5, border=1, numfmt=NUMFMT_MONEY, valign="center"),                   # 11
    xf(fill=6, border=1, valign="center"),                                       # 12
    xf(fill=6, border=1, numfmt=NUMFMT_MONEY, valign="center"),                   # 13
    xf(fill=6, border=1, numfmt=NUMFMT_COUNT, valign="center"),                   # 14
    xf(fill=7, border=1, numfmt=NUMFMT_MONEY, valign="center"),                   # 15
    xf(fill=5, border=1, wrap=True, valign="center"),                            # 16
    xf(font=6, fill=5, border=1, numfmt=NUMFMT_MONEY, valign="center"),           # 17
    xf(font=6, fill=5, border=1, numfmt=NUMFMT_COUNT, valign="center"),           # 18
    xf(font=3, fill=4, wrap=True, valign="center"),                              # 19
    xf(font=7),                                                                  # 20
    xf(font=4, fill=6, border=1, wrap=True, valign="center"),                     # 21
]

STYLES_XML = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<numFmts count="2">'
    f'<numFmt numFmtId="{NUMFMT_MONEY}" formatCode="#,##0.00;(#,##0.00)"/>'
    f'<numFmt numFmtId="{NUMFMT_COUNT}" formatCode="#,##0"/>'
    "</numFmts>"
    f'<fonts count="{len(FONTS)}">' + "".join(FONTS) + "</fonts>"
    f'<fills count="{len(FILLS)}">' + "".join(FILLS) + "</fills>"
    f'<borders count="{len(BORDERS)}">' + "".join(BORDERS) + "</borders>"
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    f'<cellXfs count="{len(CELL_XFS)}">' + "".join(CELL_XFS) + "</cellXfs>"
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    "</styleSheet>"
)


# ---------------------------------------------------------------- ตัวช่วยสร้างชีท
class Sheet:
    def __init__(self, name, cols_width=None, freeze_row=None, grid=False):
        self.name = name
        self.cols_width = cols_width or {}
        self.freeze_row = freeze_row
        self.grid = grid
        self.rows = {}        # row -> {col_letter: xml}
        self.heights = {}     # row -> ht
        self.validations = []  # (sqref, [options])

    def _put(self, row, c, xml):
        self.rows.setdefault(row, {})[c] = xml

    def text(self, row, c, value, style=S_DEFAULT):
        if value is None or value == "":
            self.blank(row, c, style)
            return
        idx = share(str(value))
        self._put(row, c, f'<c r="{c}{row}" s="{style}" t="s"><v>{idx}</v></c>')

    def num(self, row, c, value, style=S_DEFAULT):
        if value is None:
            self.blank(row, c, style)
            return
        v = int(value) if float(value).is_integer() else value
        self._put(row, c, f'<c r="{c}{row}" s="{style}"><v>{v}</v></c>')

    def blank(self, row, c, style=S_DEFAULT):
        self._put(row, c, f'<c r="{c}{row}" s="{style}"/>')

    def fnum(self, row, c, formula, cached, style=S_DEFAULT):
        """ช่องสูตรที่ผลเป็นตัวเลข — เก็บค่าที่คำนวณไว้ด้วย (Excel คำนวณใหม่เมื่อเปิดไฟล์)"""
        v = int(cached) if float(cached).is_integer() else cached
        self._put(row, c, f'<c r="{c}{row}" s="{style}"><f>{esc(formula)}</f><v>{v}</v></c>')

    def fstr(self, row, c, formula, cached, style=S_DEFAULT):
        self._put(
            row, c,
            f'<c r="{c}{row}" s="{style}" t="str"><f>{esc(formula)}</f><v>{esc(str(cached))}</v></c>',
        )

    def height(self, row, ht):
        self.heights[row] = ht

    def validate(self, sqref, options):
        self.validations.append((sqref, options))

    def xml(self) -> str:
        max_row = max(self.rows) if self.rows else 1
        max_col = "A"
        for cells in self.rows.values():
            for c in cells:
                if COLS.index(c) > COLS.index(max_col):
                    max_col = c
        body = []
        for r in sorted(self.rows):
            cells = self.rows[r]
            ht = f' ht="{self.heights[r]}" customHeight="1"' if r in self.heights else ""
            inner = "".join(cells[c] for c in sorted(cells, key=COLS.index))
            body.append(f'<row r="{r}"{ht}>{inner}</row>')

        cols = ""
        if self.cols_width:
            items = "".join(
                f'<col min="{COLS.index(c) + 1}" max="{COLS.index(c) + 1}" width="{w}" customWidth="1"/>'
                for c, w in sorted(self.cols_width.items(), key=lambda kv: COLS.index(kv[0]))
            )
            cols = f"<cols>{items}</cols>"

        pane = ""
        if self.freeze_row:
            pane = (
                f'<pane ySplit="{self.freeze_row - 1}" topLeftCell="A{self.freeze_row}"'
                ' activePane="bottomLeft" state="frozen"/>'
            )
        gl = "" if self.grid else ' showGridLines="0"'

        dv = ""
        if self.validations:
            items = []
            for sqref, options in self.validations:
                lst = ",".join(options)
                assert len(lst) <= 250, f"รายการ dropdown ยาวเกินที่ Excel รับได้: {lst[:40]}…"
                items.append(
                    '<dataValidation type="list" allowBlank="1" showInputMessage="1" showErrorMessage="1"'
                    ' errorTitle="ค่าไม่ถูกต้อง" error="เลือกจากรายการเท่านั้น"'
                    f' sqref="{sqref}"><formula1>"{esc(lst)}"</formula1></dataValidation>'
                )
            dv = f'<dataValidations count="{len(items)}">' + "".join(items) + "</dataValidations>"

        return (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
            ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            f'<dimension ref="A1:{max_col}{max_row}"/>'
            f'<sheetViews><sheetView{gl} workbookViewId="0">{pane}</sheetView></sheetViews>'
            '<sheetFormatPr defaultRowHeight="18"/>'
            f"{cols}<sheetData>" + "".join(body) + "</sheetData>" + dv + "</worksheet>"
        )


_shared: dict[str, int] = {}


def share(s: str) -> int:
    if s not in _shared:
        _shared[s] = len(_shared)
    return _shared[s]


# ---------------------------------------------------------------- ชีท "อ่านก่อน"
def build_intro() -> Sheet:
    s = Sheet(INTRO_SHEET, cols_width={"A": 5, "B": 44, "C": 86})
    s.text(1, "B", "SRI OS — แจกแจงทรัพย์สินต่อผู้ถือ", S_TITLE)
    s.text(2, "B", "ลิสต์ทรัพย์ทีละชิ้น → ได้ยอดรวมต่อผู้ถือต่อบรรทัดงบดุล → เอาไปใส่ในไฟล์ยอดตั้งต้นงบดุล", S_NOTE)

    rows = [
        ("", "ไฟล์นี้ใช้ทำอะไร", ""),
        ("", "ปัญหาที่แก้", "ไฟล์ยอดตั้งต้นงบดุลให้กรอกยอดรวมต่อบัญชี แต่ไม่มีที่ให้แจกแจงว่ายอดนั้นมาจากทรัพย์ชิ้นไหนบ้าง "
                            "ถ้าบวกผิดจะไม่มีอะไรจับได้"),
        ("", "วิธีใช้", f"กรอกในชีท \"{DETAIL_SHEET}\" ทีละชิ้น แล้วอ่านตารางสรุปด้านล่างของชีทนั้น"),
        ("1", "ลิสต์ทรัพย์ทีละชิ้น", "คอนโด 2 ห้อง = 2 บรรทัด · ที่ดิน 3 แปลง = 3 บรรทัด ใส่ผู้ถือและบรรทัดในงบดุลให้ครบทุกบรรทัด"),
        ("2", "อ่านตารางสรุป", "สรุปให้เองว่า ผู้ถือคนนี้ บรรทัดนี้ มีกี่รายการ รวมเท่าไหร่ (เช่น ธนากร · 1500 · 2 รายการ · 8,000,000)"),
        ("3", "เอายอดไปใส่ในงบดุล", "เปิด SRI_OS_2_ยอดตั้งต้นงบดุล.xlsx ชีทของผู้ถือคนนั้น ใส่ยอดในบรรทัดบัญชีเดียวกัน"),
        ("4", "กรอกยอดกลับมาที่ช่องตรวจ", "คอลัมน์ \"ยอดที่กรอกในงบดุล\" ในตารางสรุป — ถ้าต่างจากยอดรวม ช่อง \"ผลต่าง\" จะโชว์เป็นตัวเลข "
                                        "และ \"สถานะ\" จะขึ้นว่า ต่างกัน"),
        ("", "", ""),
        ("", "กฎที่ห้ามพลาด", ""),
        ("!", "ทรัพย์แต่ละชิ้นมีต้นทุนของตัวเอง ห้ามเฉลี่ยข้ามชิ้น",
            "D-117 — \"แยกทรัพย์สินแม้จะอยู่คอนโดเดียวกัน แต่คนละห้องก็แยก จะไม่นำต้นทุนมาคำนวณหรือเฉลี่ยเด็ดขาด\" "
            "คอนโดคนละห้องคือคนละชิ้น ต้นทุนของแต่ละห้องคือราคาที่ซื้อห้องนั้นจริง "
            "(เฉลี่ยต้นทุนได้เฉพาะหุ้นในตลาดและคริปโต ซึ่งไม่อยู่ในไฟล์นี้)"),
        ("!", "ค่ารีโนเวทเป็นอีกบรรทัดในงบดุล",
            "ค่าปรับปรุงที่บันทึกเป็นทุนไปลงบัญชี 1510 ไม่รวมกับต้นทุนทรัพย์ (1500) "
            "กรอกในคอลัมน์ \"ค่ารีโนเวทสะสม\" ของทรัพย์ชิ้นนั้น ไม่ต้องสร้างบรรทัดใหม่"),
        ("!", "เงินที่ปล่อยออกไปเป็นสินทรัพย์",
            "ปล่อยกู้ (1300) ขายฝาก (1400) จำนอง (1410) คือลูกหนี้ของเรา ไม่ใช่ค่าใช้จ่าย และไม่ใช่หนี้สิน"),
        ("!", "ห้ามหักหนี้ออกจากทรัพย์",
            "คอนโดติดจำนองอยู่ ให้ลงต้นทุนเต็มจำนวนที่นี่ ส่วนยอดหนี้ไปลงฝั่งหนี้สินในไฟล์งบดุล ห้าม net กัน"),
        ("!", "ยอดตั้งต้นต้องเป็นวันตัดยอดเดียวกับไฟล์อื่น",
            "ใช้วันตัดยอดเดียวกันทั้งชุด ไม่งั้นงบดุลไม่ลงตัว"),
        ("", "", ""),
        ("", "เรื่องเทคนิคที่ควรรู้", ""),
        ("", "สูตรในไฟล์นี้เป็นตัวช่วยของลูกพี่", "เวลา import ระบบจะคำนวณยอดรวมใหม่เองจากบรรทัดที่กรอก ไม่เชื่อผลสูตรใน Excel"),
        ("", "แถวสีเทาเอียงคือตัวอย่าง", "คอนโด 2 ห้องของธนากร (3,000,000 + 5,000,000 = 8,000,000) ลบทิ้งได้เลย"),
        ("", "กรอกได้ถึงแถว 205", f"ถ้าต้องการมากกว่านี้ ให้แทรกแถวกลางตาราง (Excel จะขยายช่วงสูตรให้เอง) ห้ามพิมพ์ทับตารางสรุป"),
        ("", "ไฟล์นี้สร้างจากสคริปต์", "scripts/make-breakdown-template.py — แก้ที่สคริปต์แล้ว generate ใหม่ ไม่แก้ .xlsx ด้วยมือ"),
    ]
    r = 4
    for mark, head, detail in rows:
        if mark == "!":
            s.text(r, "A", "!", S_BRAND)
        elif mark:
            s.text(r, "A", mark, S_BRAND)
        s.text(r, "B", head, S_H2 if head and not detail else (S_DEFAULT if detail else S_DEFAULT))
        if detail:
            s.text(r, "C", detail, S_CHK_LABEL if mark == "!" else S_NOTE)
            s.height(r, 46 if len(detail) > 110 else 30)
        r += 1
    return s


# ---------------------------------------------------------------- ชีทแจกแจง + สรุป
def build_detail() -> Sheet:
    s = Sheet(
        DETAIL_SHEET,
        cols_width={"A": 20, "B": 14, "C": 34, "D": 17, "E": 17, "F": 17, "G": 34, "H": 20, "I": 16, "J": 20},
        freeze_row=FIRST_DATA_ROW,
    )
    s.text(1, "A", "แจกแจงทรัพย์สินต่อผู้ถือ → ยอดในงบดุล", S_TITLE)
    s.text(2, "A",
           "กรอกทรัพย์ทีละชิ้นในตารางนี้ (แถว 6 ถึง 205) แล้วอ่านยอดรวมในตารางสรุปด้านล่าง "
           "· ทรัพย์แต่ละชิ้นมีต้นทุนของตัวเอง ห้ามเฉลี่ยข้ามชิ้น (D-117)", S_NOTE_FILL)
    s.height(2, 32)

    for i, (header, required, hint) in enumerate(HEADERS):
        c = col(i)
        s.text(4, c, header, S_TH_REQ if required else S_TH_OPT)
        s.text(5, c, hint, S_HINT)
    s.height(4, 32)
    s.height(5, 34)

    for i, row in enumerate(SAMPLES):
        r = FIRST_DATA_ROW + i
        for j, v in enumerate(row):
            c = col(j)
            if j in (4, 5):
                s.num(r, c, v, S_SAMPLE_MONEY)
            else:
                s.text(r, c, v, S_SAMPLE)

    for r in range(FIRST_DATA_ROW + len(SAMPLES), LAST_DATA_ROW + 1):
        for j in range(len(HEADERS)):
            s.blank(r, col(j), S_MONEY if j in (4, 5) else S_TEXT)

    s.validate(f"A{FIRST_DATA_ROW}:A{LAST_DATA_ROW}", OWNERS)
    s.validate(f"D{FIRST_DATA_ROW}:D{LAST_DATA_ROW}", [code for code, _ in LINES])

    # ---- ช่วงอ้างอิงแบบ absolute
    A = f"$A${FIRST_DATA_ROW}:$A${LAST_DATA_ROW}"
    D = f"$D${FIRST_DATA_ROW}:$D${LAST_DATA_ROW}"
    E = f"$E${FIRST_DATA_ROW}:$E${LAST_DATA_ROW}"
    F = f"$F${FIRST_DATA_ROW}:$F${LAST_DATA_ROW}"

    # ---- ตารางสรุป: ผู้ถือ × บรรทัดงบดุล
    grid_head = LAST_DATA_ROW + 3          # 208
    grid_first = grid_head + 1             # 209
    grid_rows = []                         # (row, owner, code)
    r = grid_first
    for owner in OWNERS:
        for code, _name in LINES:
            grid_rows.append((r, owner, code))
            r += 1
    grid_last = r - 1
    chk_head = grid_last + 2
    chk_first = chk_head + 1

    s.text(grid_head - 1, "A", "ตารางสรุปอัตโนมัติ — ยอดรวมต่อผู้ถือ × ต่อบรรทัดงบดุล", S_H2)
    sum_headers = [
        ("ผู้ถือ", "A"),
        ("บรรทัดในงบดุล", "B"),
        ("ชื่อบัญชี", "C"),
        ("จำนวนรายการ", "D"),
        ("รวมต้นทุน", "E"),
        ("รวมค่ารีโนเวท (ไปลงบัญชี 1510)", "F"),
        ("ยอดที่ไปลงบัญชีนี้", "G"),
        ("ยอดที่กรอกในงบดุล", "H"),
        ("ผลต่าง", "I"),
        ("สถานะ", "J"),
    ]
    for name, c in sum_headers:
        s.text(grid_head, c, name, S_SUM_HEAD)
    s.height(grid_head, 40)

    # ค่าที่คำนวณไว้ล่วงหน้าจากแถวตัวอย่าง (Excel จะคำนวณใหม่ตอนเปิดไฟล์ — fullCalcOnLoad)
    def sample_cost(owner, code):
        return sum(x[4] or 0 for x in SAMPLES if x[0] == owner and x[3] == code)

    def sample_reno(owner, code):
        return sum(x[5] or 0 for x in SAMPLES if x[0] == owner and x[3] == code)

    def sample_reno_all(owner):
        return sum(x[5] or 0 for x in SAMPLES if x[0] == owner)

    def sample_count(owner, code):
        return sum(1 for x in SAMPLES if x[0] == owner and x[3] == code)

    names = dict(LINES)
    total_cost_grid = 0
    total_reno_grid = 0
    mismatch = 0
    for row, owner, code in grid_rows:
        s.text(row, "A", owner, S_SUM_TEXT)
        s.text(row, "B", code, S_SUM_TEXT)
        s.text(row, "C", names[code], S_SUM_TEXT)
        s.fnum(row, "D", f"COUNTIFS({A},$A{row},{D},$B{row})", sample_count(owner, code), S_SUM_COUNT)
        s.fnum(row, "E", f"SUMIFS({E},{A},$A{row},{D},$B{row})", sample_cost(owner, code), S_SUM_MONEY)
        s.fnum(row, "F", f"SUMIFS({F},{A},$A{row},{D},$B{row})", sample_reno(owner, code), S_SUM_MONEY)
        # บรรทัด 1510 = ค่ารีโนเวทของผู้ถือคนนั้นทุกชิ้น + ต้นทุนที่กรอกไว้ในบรรทัด 1510 เอง
        if code == RENO_LINE:
            posted = sample_cost(owner, code) + sample_reno_all(owner)
            s.fnum(row, "G", f"$E{row}+SUMIF({A},$A{row},{F})", posted, S_SUM_MONEY)
        else:
            posted = sample_cost(owner, code)
            s.fnum(row, "G", f"$E{row}", posted, S_SUM_MONEY)
        bs = SAMPLE_BS.get((owner, code))
        s.num(row, "H", bs, S_INPUT_MONEY)
        diff = (bs if bs is not None else 0) - posted if not (bs is None and posted == 0) else 0
        s.fnum(row, "I", f'IF(AND($H{row}="",$G{row}=0),0,$H{row}-$G{row})', diff, S_SUM_MONEY)
        s.fstr(row, "J", f'IF($I{row}=0,"ตรงกัน","ต่างกัน — ต้องหา")',
               "ตรงกัน" if diff == 0 else "ต่างกัน — ต้องหา", S_SUM_TEXT)
        total_cost_grid += sample_cost(owner, code)
        total_reno_grid += sample_reno(owner, code)
        mismatch += 0 if diff == 0 else 1

    GE = f"$E${grid_first}:$E${grid_last}"
    GF = f"$F${grid_first}:$F${grid_last}"
    GI = f"$I${grid_first}:$I${grid_last}"
    GJ = f"$J${grid_first}:$J${grid_last}"

    # ---- ช่องตรวจ (ทุกช่องต้องเป็น 0)
    s.text(chk_head, "A", "ช่องตรวจ — ทุกช่องต้องเป็น 0 ถ้าไม่ใช่ 0 แปลว่ามีอะไรไม่ตรง ห้ามข้าม", S_H2)
    detail_cost = sum(x[4] or 0 for x in SAMPLES)
    detail_reno = sum(x[5] or 0 for x in SAMPLES)
    checks = [
        ("มีต้นทุนแต่ยังไม่ระบุผู้ถือ (ยอดนี้จะไม่ถูกนับให้ใครเลย)",
         f'COUNTIFS({E},"<>",{A},"")', 0, S_CHK_COUNT),
        ("มีต้นทุนแต่ยังไม่ระบุบรรทัดในงบดุล",
         f'COUNTIFS({E},"<>",{D},"")', 0, S_CHK_COUNT),
        ("ผู้ถือที่พิมพ์ไม่ตรงกับรายชื่อผู้ถือ",
         f"COUNTA({A})-SUMPRODUCT(COUNTIF({A},{arr(OWNERS)}))", 0, S_CHK_COUNT),
        ("บรรทัดในงบดุลที่ไม่อยู่ในรหัสที่อนุญาต",
         f"COUNTA({D})-SUMPRODUCT(COUNTIF({D},{arr([c for c, _ in LINES])}))", 0, S_CHK_COUNT),
        (f"ค่ารีโนเวทที่กรอกไว้ในบรรทัด {RENO_LINE} (ต้องย้ายไปคอลัมน์ต้นทุน ไม่งั้นนับซ้ำ)",
         f'SUMIFS({F},{D},"{RENO_LINE}")', 0, S_CHK_MONEY),
        ("ต้นทุนในตารางบนที่ตารางสรุปจับไม่ได้",
         f"SUM({E})-SUM({GE})", detail_cost - total_cost_grid, S_CHK_MONEY),
        ("ค่ารีโนเวทในตารางบนที่ตารางสรุปจับไม่ได้",
         f"SUM({F})-SUM({GF})", detail_reno - total_reno_grid, S_CHK_MONEY),
        ("ผลต่างรวมระหว่างยอดที่กรอกในงบดุลกับยอดรวมที่คำนวณได้",
         f"SUM({GI})", 0, S_CHK_MONEY),
        ("จำนวนบรรทัดในตารางสรุปที่ยอดยังไม่ตรง",
         f'COUNTIF({GJ},"ต่างกัน*")', mismatch, S_CHK_COUNT),
    ]
    for i, (label, formula, cached, style) in enumerate(checks):
        r = chk_first + i
        s.text(r, "A", label, S_CHK_LABEL)
        for c in "BCD":
            s.blank(r, c, S_CHK_LABEL)
        s.fnum(r, "E", formula, cached, style)
        s.height(r, 24)

    return s


# ---------------------------------------------------------------- ประกอบไฟล์
def shared_strings_xml() -> str:
    items = sorted(_shared.items(), key=lambda kv: kv[1])
    si = "".join(f'<si><t xml:space="preserve">{esc(s)}</t></si>' for s, _ in items)
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
        f' count="{len(items)}" uniqueCount="{len(items)}">{si}</sst>'
    )


def main() -> None:
    sheets = [build_intro(), build_detail()]
    sheet_xml = [s.xml() for s in sheets]  # ต้องสร้างก่อน sharedStrings (ลงทะเบียนข้อความ)

    wb = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
        ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
        + "".join(
            f'<sheet name="{esc(s.name)}" sheetId="{i + 1}" r:id="rId{i + 1}"/>'
            for i, s in enumerate(sheets)
        )
        + "</sheets>"
        # คำนวณสูตรใหม่ทั้งเล่มตอนเปิดไฟล์ — ค่าที่ cache ไว้ในไฟล์ห้ามเป็นตัวที่ลูกพี่เชื่อ
        '<calcPr calcId="124519" fullCalcOnLoad="1"/></workbook>'
    )
    n = len(sheets)
    rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        + "".join(
            f'<Relationship Id="rId{i + 1}"'
            ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"'
            f' Target="worksheets/sheet{i + 1}.xml"/>'
            for i in range(n)
        )
        + f'<Relationship Id="rId{n + 1}"'
        ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"'
        ' Target="styles.xml"/>'
        f'<Relationship Id="rId{n + 2}"'
        ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"'
        ' Target="sharedStrings.xml"/></Relationships>'
    )
    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1"'
        ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"'
        ' Target="xl/workbook.xml"/></Relationships>'
    )
    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml"'
        ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        + "".join(
            f'<Override PartName="/xl/worksheets/sheet{i + 1}.xml"'
            ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
            for i in range(n)
        )
        + '<Override PartName="/xl/styles.xml"'
        ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml"'
        ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
        "</Types>"
    )

    parts = [
        ("[Content_Types].xml", content_types),
        ("_rels/.rels", root_rels),
        ("xl/workbook.xml", wb),
        ("xl/_rels/workbook.xml.rels", rels),
        ("xl/styles.xml", STYLES_XML),
        ("xl/sharedStrings.xml", shared_strings_xml()),
    ]
    for i, xml in enumerate(sheet_xml):
        parts.append((f"xl/worksheets/sheet{i + 1}.xml", xml))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in parts:
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 26, 0, 0, 0))  # ผลลัพธ์เหมือนกันทุกครั้งที่รัน
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o600 << 16
            z.writestr(info, data.encode("utf-8"))

    print(f"เขียนแล้ว: {OUT}  ({OUT.stat().st_size:,} bytes)")
    print(f"ชีท: {', '.join(s.name for s in sheets)}")


if __name__ == "__main__":
    main()
