-- ============================================================
-- SRI OS · ด่านของ **บัญชีรองรับ** (1900 · 1950 · 2500 · 2600)
--
-- ลูกพี่สั่ง 26/10 ให้เพิ่มบัญชีรองรับของที่ไม่เข้าพวกบัญชีเฉพาะ
-- บัญชีกลุ่มนี้อันตรายกว่าบัญชีทั่วไปสองทาง และไฟล์นี้กันไว้ทั้งสอง
--
-- ------------------------------------------------------------
-- ทำไมต้องมีไฟล์นี้ ทั้งที่มีเทสต์ฝั่ง TypeScript อยู่แล้ว
-- ------------------------------------------------------------
-- เทสต์ฝั่ง TS พิสูจน์ว่า **ตารางกฎในโค้ด** ถูก · ไฟล์นี้พิสูจน์ว่า
-- **สำเนาใน DB** ถูก ซึ่งเป็นคนละอย่างกัน: seed อาจลงไม่ครบ ลงรุ่นเก่าทับ
-- หรือมีคนแก้ตรงใน DB · กฎของโปรเจกต์คือ "กฎใน DB ต้องมีประวัติใน git เสมอ"
-- ด่านนี้เคยมีอยู่แต่อยู่ใน migration ที่ยิงเข้า DB ตรงๆ ไม่ได้อยู่ในรีโป
-- (ผู้ตรวจจับได้ 26/10) ถ้าสร้าง DB ใหม่จากรีโป ด่านจะหายไปเงียบๆ
--
-- ------------------------------------------------------------
-- สองอย่างที่กัน
-- ------------------------------------------------------------
-- 1 · **ลงได้ต้องล้างได้** — ทุกบัญชีรองรับต้องมีครบสามทาง:
--     ทางลง (บัญชีเพิ่ม) · ทางล้าง (บัญชีลด) · หมวดยอดยกมา
--     บัญชีที่ตั้งยอดได้แต่เอาออกไม่ได้ = ทรัพย์หรือหนี้ผีค้างในงบดุลตลอดไป
--     (บทเรียนข้อ 7: เปิดฟีเจอร์ครึ่งเดียวอันตรายกว่าไม่เปิด)
--
-- 2 · **ห้ามกระทบงบกำไรขาดทุน** — จ่ายเงินแลกสิทธิไม่ใช่ค่าใช้จ่าย
--     และรับเงินที่ต้องคืนไม่ใช่รายได้ · ถ้าหมวดไหนของบัญชีรองรับกระทบ P&L
--     กำไรจะเพี้ยนทันทีที่ลงผิด โดย **งบดุลยังดุลปกติ** จึงไม่มีอะไรสะดุด
--
-- ลำดับ: ต้องรันหลัง seed ตารางกฎ (ชื่อไฟล์เรียงให้แล้ว)
-- idempotent: อ่านอย่างเดียว ไม่เขียนอะไร → รันซ้ำได้ไม่จำกัด
-- ย้อนกลับ: ไม่มีอะไรต้องย้อน · ถ้าจะเลิกใช้บัญชีรองรับ ให้ลบรายชื่อใน
--   CATCH_ALL_COA (src/lib/rules/coa.ts) แล้ว sync ใหม่ ไม่ใช่ลบไฟล์นี้
-- ============================================================

set search_path = sri_os, public;

do $$
declare
  -- **ต้องตรงกับ CATCH_ALL_COA ใน src/lib/rules/coa.ts**
  -- ที่นั่นคือแหล่งความจริง ที่นี่คือสำเนาฝั่ง DB เหมือนตารางกฎอื่นๆ
  c_catch_all constant text[] := array['1900', '1950', '2500', '2600'];
  v_missing   text;
  v_bad_pl    text;
  n           int;
begin
  -- ---------- ของต้องมาก่อน ----------
  select string_agg(x.code, ', ' order by x.code) into v_missing
    from unnest(c_catch_all) x(code)
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v_missing is not null then
    raise exception 'ไม่มีบัญชีรองรับ % ในผังบัญชี → seed ตารางกฎยังไม่ได้ลง หรือลง seed รุ่นเก่าทับ (sync ด้วย npm run sync:rules)', v_missing;
  end if;

  select count(*) into n from sri_os.txn_types;
  if n = 0 then
    raise exception 'ตาราง txn_types ว่างเปล่า — ด่านทั้งไฟล์จะผ่านฟรีๆ ไม่ยอม';
  end if;

  /**
   * ---------- 1 · ลงได้ต้องล้างได้ ----------
   *
   * ตรวจสามทางแยกกันเพื่อให้ข้อความบอกได้ว่าขาดทางไหน
   * ไม่นับหมวดยอดยกมาเป็น "ทางลง" เพราะยอดยกมาใช้ได้ครั้งเดียวตอนตั้งระบบ
   * บัญชีที่มีแต่ยอดยกมา = ตั้งยอดแล้วแตะอะไรไม่ได้อีกเลย
   */
  select string_agg(x.code || ' (' || x.gap || ')', ' · ' order by x.code) into v_missing
    from (
      select c.code,
             case
               when not exists (select 1 from sri_os.txn_types t
                                 where t.dr_coa_code = c.code and t.group_code <> 'opening'
                                   and c.code in (select code from sri_os.chart_of_accounts where type = 'asset'))
                and not exists (select 1 from sri_os.txn_types t
                                 where t.cr_coa_code = c.code and t.group_code <> 'opening'
                                   and c.code in (select code from sri_os.chart_of_accounts where type = 'liability'))
               then 'ไม่มีทางลง'
               when not exists (select 1 from sri_os.txn_types t
                                 where t.cr_coa_code = c.code and t.group_code <> 'opening'
                                   and c.code in (select code from sri_os.chart_of_accounts where type = 'asset'))
                and not exists (select 1 from sri_os.txn_types t
                                 where t.dr_coa_code = c.code and t.group_code <> 'opening'
                                   and c.code in (select code from sri_os.chart_of_accounts where type = 'liability'))
               then 'ไม่มีทางล้าง'
               when not exists (select 1 from sri_os.txn_types t
                                 where t.group_code = 'opening'
                                   and c.code in (t.dr_coa_code, t.cr_coa_code))
               then 'ไม่มีหมวดยอดยกมา'
             end as gap
        from unnest(c_catch_all) u(code)
        join sri_os.chart_of_accounts c on c.code = u.code
    ) x
   where x.gap is not null;
  if v_missing is not null then
    raise exception 'บัญชีรองรับที่ยังไม่ครบวงจร: % — บัญชีที่ตั้งยอดได้แต่เอาออกไม่ได้คือทรัพย์หรือหนี้ผีที่ค้างในงบดุลตลอดไป', v_missing;
  end if;

  /**
   * ---------- 2 · ห้ามกระทบงบกำไรขาดทุน ----------
   *
   * ตรวจทั้งธง `affects_pl` และบัญชีกำไร/ขาดทุน เพราะมีสองทางที่กำไรจะโผล่:
   * ธงบอกให้เครื่องยนต์เติมบรรทัด P&L · หรือมีบัญชีกำไร/ขาดทุนให้มันใช้
   * ปิดทางเดียวไม่พอ
   */
  select string_agg(t.code, ', ' order by t.code) into v_bad_pl
    from sri_os.txn_types t
   where (t.dr_coa_code = any (c_catch_all) or t.cr_coa_code = any (c_catch_all))
     and (coalesce(t.affects_pl, false)
          or t.gain_coa_code is not null
          or t.loss_coa_code is not null
          or t.pl_line is not null);
  if v_bad_pl is not null then
    raise exception 'หมวดของบัญชีรองรับกระทบงบกำไรขาดทุน: % — จ่ายเงินแลกสิทธิไม่ใช่ค่าใช้จ่าย และรับเงินที่ต้องคืนไม่ใช่รายได้ · ลงผิดแล้วกำไรเพี้ยนทันทีโดยงบดุลยังดุล', v_bad_pl;
  end if;

  /**
   * ---------- 3 · ตั้งค้างได้ต้องล้างค้างได้ ----------
   *
   * หมวดที่ `can_accrue` ตั้งลูกหนี้/เจ้าหนี้ไว้ ต้องมีหมวดอื่นที่ล้างบัญชีค้างนั้น
   * ไม่งั้นยอดค้างจะโตตลอดไปและรายได้/ค่าใช้จ่ายถูกนับซ้ำตอนเงินเข้าจริง
   */
  select string_agg(t.code || ' → ' || t.accrual_coa_code, ' · ' order by t.code) into v_missing
    from sri_os.txn_types t
   where (t.dr_coa_code = any (c_catch_all) or t.cr_coa_code = any (c_catch_all))
     and coalesce(t.can_accrue, false)
     and t.accrual_coa_code is not null
     and not exists (
       select 1 from sri_os.txn_types q
        where q.group_code <> 'opening'
          and t.accrual_coa_code in (q.dr_coa_code, q.cr_coa_code)
          and q.code <> t.code);
  if v_missing is not null then
    raise exception 'หมวดของบัญชีรองรับที่ตั้งค้างได้แต่ไม่มีทางล้างบัญชีค้าง: % — ยอดค้างจะโตตลอดไปและตัวเลขถูกนับซ้ำตอนเงินเข้าจริง', v_missing;
  end if;

  select count(*) into n
    from sri_os.txn_types t
   where t.dr_coa_code = any (c_catch_all) or t.cr_coa_code = any (c_catch_all);
  raise notice 'ok · บัญชีรองรับ % ตัว ครบวงจรทุกตัว (ลงได้ ล้างได้ มียอดยกมา) · % หมวดที่แตะบัญชีกลุ่มนี้ ไม่มีหมวดไหนกระทบงบกำไรขาดทุน',
    cardinality(c_catch_all), n;
end $$;
