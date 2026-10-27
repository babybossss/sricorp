import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { deflateRawSync } from "node:zlib";
import { MAX_XLSX_BYTES, readWorkbook, XlsxError, cellAt } from "../xlsx";
import { FIXTURE, loadRawFixture as loadFixture, sheetOf } from "./helpers";

describe("อ่าน xlsx", () => {
  it("อ่านไฟล์เทมเพลตจริง: ครบ 9 ชีท ตามลำดับ", () => {
    const wb = loadFixture();
    expect(wb.sheets.map((s) => s.name)).toEqual([
      "อ่านก่อน",
      "BS-SRI Corporation",
      "BS-สุธี",
      "BS-ธนากร",
      "BS-ธนวินท์",
      "BS-เบ็ญจพร",
      "BS-สุดจิตต์",
      "รวมทุกผู้ถือ",
      "พอร์ตลงทุน (รายล็อต)",
    ]);
  });

  it("ตัวเลข/ข้อความ/วันที่ มาตามชนิด และช่องสูตรถูกทำเครื่องหมาย", () => {
    const tk = sheetOf(loadFixture(), "BS-ธนากร");
    expect(cellAt(tk, 6, "A")?.value).toBe("1100");
    expect(cellAt(tk, 6, "E")).toEqual({ value: 1000000, formula: false });
    expect(cellAt(tk, 38, "B")?.value).toBe("ธนากร - BBL 888");
    expect(cellAt(tk, 28, "E")?.formula).toBe(true); // รวมสินทรัพย์ = สูตร
    const lots = sheetOf(loadFixture(), "พอร์ตลงทุน (รายล็อต)");
    expect(typeof cellAt(lots, 6, "D")?.value).toBe("number"); // วันที่ = serial
    expect(cellAt(lots, 6, "H")?.formula).toBe(true);
  });

  it("ไฟล์ที่ไม่ใช่ zip / ว่าง / ใหญ่เกิน ถูกปฏิเสธด้วยข้อความอ่านออก", () => {
    expect(() => readWorkbook(Buffer.from("hello world, not a zip"))).toThrow(XlsxError);
    expect(() => readWorkbook(Buffer.alloc(0))).toThrow(XlsxError);
    expect(() => readWorkbook(Buffer.alloc(MAX_XLSX_BYTES + 1))).toThrow(/ใหญ่เกิน/);
  });

  it("ไฟล์ที่ถูกตัดท้าย (zip เสีย) ถูกปฏิเสธ ไม่คืนชีทว่างเงียบๆ", () => {
    const buf = readFileSync(FIXTURE);
    expect(() => readWorkbook(buf.subarray(0, buf.length - 200))).toThrow(XlsxError);
  });

  it("zip bomb (ขยายแล้วใหญ่เกินเพดาน) ถูกปฏิเสธ", () => {
    // สร้าง zip ที่ไฟล์เดียวขยายได้ ~100MB จากข้อมูลเล็กจิ๋ว
    const big = deflateRawSync(Buffer.alloc(100 * 1024 * 1024, 0x41));
    const name = Buffer.from("xl/workbook.xml");
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(8, 8);
    local.writeUInt32LE(big.length, 18);
    local.writeUInt32LE(100 * 1024 * 1024, 22);
    local.writeUInt16LE(name.length, 26);
    const cd = Buffer.alloc(46);
    cd.writeUInt32LE(0x02014b50, 0);
    cd.writeUInt16LE(8, 10);
    cd.writeUInt32LE(big.length, 20);
    cd.writeUInt32LE(100 * 1024 * 1024, 24);
    cd.writeUInt16LE(name.length, 28);
    const cdOffset = local.length + name.length + big.length;
    const eocd = Buffer.alloc(22);
    eocd.writeUInt32LE(0x06054b50, 0);
    eocd.writeUInt16LE(1, 8);
    eocd.writeUInt16LE(1, 10);
    eocd.writeUInt32LE(cd.length + name.length, 12);
    eocd.writeUInt32LE(cdOffset, 16);
    const zip = Buffer.concat([local, name, big, cd, name, eocd]);
    expect(() => readWorkbook(zip)).toThrow(/ขยายแล้วใหญ่/);
  });
});
