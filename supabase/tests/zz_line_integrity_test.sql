-- ============================================================
-- SRI OS · เทสต์ความสมบูรณ์ของบรรทัดบัญชี (trigger ไม่ใช่ RLS)
--
-- **ไฟล์นี้ commit ข้อมูลจริง** ต่างจาก roles_permissions_test.sql ที่ rollback
-- เพราะกฎที่ทดสอบคือ "หัวรายการต้องถูกสร้างในธุรกรรมเดียวกับบรรทัด"
-- ซึ่งพิสูจน์ไม่ได้เลยถ้าทุกอย่างอยู่ในธุรกรรมเดียว (xmin จะตรงกันหมด)
-- → รันกับ DB ที่ทิ้งได้เท่านั้น (scripts/test-rls-local.sh ลบ DB ให้ทุกครั้ง)
--
-- รันในฐานะ superuser ของ cluster = ข้าม RLS แต่ **trigger ยังทำงานทุกเส้นทาง**
-- นั่นคือประเด็น: RLS เป็นชั้นที่ policy ในอนาคตเขียนทับได้ trigger ไม่ได้
--
-- **คู่บัญชีของ fixture (10/10 · D-107)**: ใช้ `exp.other` · Dr 5900 ค่าใช้จ่ายอื่น /
--   Cr 2100 เจ้าหนี้ค้างจ่าย = ใบ "ตั้งค้างจ่าย" ที่ **ไม่มีขาเงินสด** (เลี่ยงกติกา
--   cash_date/bank ซึ่งไม่ใช่เรื่องที่ไฟล์นี้วัด) และเป็นหมวดที่ `can_accrue = true`
--   ของเดิมใช้ `inc.other` · Dr 1220 / Cr 4900 ซึ่ง **ตารางกฎไม่เคยอนุญาต**
--   (หมวดนั้นตั้งค้างไม่ได้) · 20261010000003 ปิดช่องนั้นแล้ว → fixture ต้องเป็น
--   ใบที่ลงได้จริง ไม่ใช่ใบที่ผ่านได้เพราะด่านยังไม่อ่านธง `can_accrue`
-- ============================================================

\set ON_ERROR_STOP 1

-- ---------- fixture: ผู้ใช้สำหรับ voided_by (D-098 · 20261020000001) ----------
-- ตั้งแต่ D-098 การ void ต้องบันทึก voided_at + voided_by + void_reason ครบ
-- (void_reason บังคับทุกผู้ถือ) และ voided_by เป็น FK ไป app_users = ต้องเป็นคนจริง
-- ไฟล์นี้เดิมไม่มี app_users เลยจนถึง L17 → เคส void ก่อนหน้านั้นต้องมีคนให้อ้าง
-- **ไม่ใช่การลดความเข้ม** แค่ทำให้ fixture เป็นข้อมูลที่ลงได้จริงตามกฎใหม่
insert into auth.users(id) values ('00000000-0000-0000-0000-0000000f0a01')
on conflict do nothing;
insert into sri_os.app_users(id, email, display_name, role, is_active) values
  ('00000000-0000-0000-0000-0000000f0a01', 'li-void@zz', 'ZZ ผู้ยกเลิก (line integrity)',
   'management', true)
on conflict (id) do update set is_active = true;

-- ---------- fixture: รายการที่ post แล้ว 500/500 (ธุรกรรมแยก จบด้วย commit) ----------
begin;
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
values ('00000000-0000-0000-0000-0000000f0001',
        (select id from sri_os.owners where code = 'SRI_HOLDING'),
        'exp.other', current_date, array['evidence.pdf']);

insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '00000000-0000-0000-0000-0000000f0001', c.id,
       case when c.rn = 1 then 500 else 0 end,
       case when c.rn = 2 then 500 else 0 end
  from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('5900', 1), ('2100', 2)) as v(code, rn) on v.code = c2.code) c;
commit;

do $$
declare v numeric;
begin
  select sum(debit) into v from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-0000000f0001';
  if v <> 500 then raise exception 'FAIL: fixture ควรมีเดบิต 500 แต่ได้ %', v; end if;
  raise notice 'ok L0 · ลงหัวรายการ + บรรทัดในธุรกรรมเดียวกัน = ผ่าน (เดบิต 500)';
end $$;

-- ---------- L1 · ยัดบรรทัดเพิ่มเข้ารายการที่ post แล้ว ----------
do $$
declare v numeric; v_err text;
begin
  begin
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
    select '00000000-0000-0000-0000-0000000f0001', c.id,
           case when c.rn = 1 then 300 else 0 end,
           case when c.rn = 2 then 300 else 0 end
      from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('5900', 1), ('2100', 2)) as v(code, rn) on v.code = c2.code) c;
    raise exception 'FAIL: ยัดบรรทัดเพิ่มเข้ารายการที่ post แล้วได้';
  exception when raise_exception then
    v_err := sqlerrm;
    if v_err like 'FAIL:%' then raise; end if;
    if v_err not like '%reverse%' then
      raise exception 'FAIL: ข้อความ error ต้องบอกให้ reverse แล้วลงใหม่ แต่ได้: %', v_err;
    end if;
  end;

  select sum(debit) into v from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-0000000f0001';
  if v <> 500 then raise exception 'FAIL: ยอดเปลี่ยนเป็น % (ต้องยัง 500)', v; end if;
  raise notice 'ok L1 · ยัดบรรทัดเข้ารายการที่ post แล้วไม่ได้ · ยอดยังเป็น 500';
end $$;

-- ---------- L2 · แก้ยอดบรรทัดเดิม ----------
do $$
declare v numeric;
begin
  begin
    update sri_os.transaction_lines set debit = 999
     where transaction_id = '00000000-0000-0000-0000-0000000f0001' and debit > 0;
    raise exception 'FAIL: แก้ยอดบรรทัดของรายการที่ post แล้วได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  select sum(debit) into v from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-0000000f0001';
  if v <> 500 then raise exception 'FAIL: ยอดเปลี่ยนเป็น %', v; end if;
  raise notice 'ok L2 · แก้ยอดบรรทัดไม่ได้ · ยอดยังเป็น 500';
end $$;

-- ---------- L3 · ลบบรรทัดทิ้งทั้งคู่ (เคสที่เหลือหัวรายการ posted ไม่มียอด) ----------
do $$
declare n int;
begin
  begin
    delete from sri_os.transaction_lines
     where transaction_id = '00000000-0000-0000-0000-0000000f0001';
    raise exception 'FAIL: ลบบรรทัดของรายการที่ post แล้วได้ = เหลือหัวรายการไม่มียอด';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  select count(*) into n from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-0000000f0001';
  if n <> 2 then raise exception 'FAIL: เหลือ % บรรทัด (ต้อง 2)', n; end if;
  raise notice 'ok L3 · ลบบรรทัดไม่ได้ · ยังมี 2 บรรทัด';
end $$;

-- ---------- L4 · void ก่อนแล้วแก้บรรทัด = ทางอ้อมที่ต้องปิดด้วย ----------
do $$
declare n int;
begin
  update sri_os.transactions set status = 'void', voided_at = now(), voided_by = coalesce(auth.uid(), (select id from sri_os.app_users order by created_at limit 1)), void_reason = $vr$เทสต์ D-098 · ยกเลิกรายการ$vr$
   where id = '00000000-0000-0000-0000-0000000f0001';
  begin
    delete from sri_os.transaction_lines
     where transaction_id = '00000000-0000-0000-0000-0000000f0001';
    raise exception 'FAIL: void แล้วลบบรรทัดได้ = ได้ทางอ้อมรอบกฎเหล็กข้อ 1';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  select count(*) into n from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-0000000f0001';
  if n <> 2 then raise exception 'FAIL: เหลือ % บรรทัด', n; end if;
  raise notice 'ok L4 · void แล้วก็ยังแก้บรรทัดไม่ได้';
end $$;

-- ---------- L5 · หัวรายการ posted ที่ไม่มีบรรทัดเลย ต้อง commit ไม่ผ่าน ----------
\set ON_ERROR_STOP 0
begin;
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
values ('00000000-0000-0000-0000-0000000f0002',
        (select id from sri_os.owners where code = 'SRI_HOLDING'),
        'exp.other', current_date, array['evidence.pdf']);
commit;
\set ON_ERROR_STOP 1

do $$
begin
  if exists (select 1 from sri_os.transactions
              where id = '00000000-0000-0000-0000-0000000f0002') then
    raise exception 'FAIL: หัวรายการ posted ที่ไม่มีบรรทัดเลย commit ผ่าน (เดิม 0 = 0 ถือว่าสมดุล)';
  end if;
  raise notice 'ok L5 · หัวรายการที่บันทึกแล้วแต่ไม่มีบรรทัด commit ไม่ผ่าน';
end $$;

-- ---------- L6 · หัวรายการที่มีบรรทัดเดียว (ไม่ใช่คู่) ก็ต้องไม่ผ่าน ----------
\set ON_ERROR_STOP 0
begin;
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
values ('00000000-0000-0000-0000-0000000f0003',
        (select id from sri_os.owners where code = 'SRI_HOLDING'),
        'exp.other', current_date, array['evidence.pdf']);
insert into sri_os.transaction_lines(transaction_id, coa_id, debit)
select '00000000-0000-0000-0000-0000000f0003', id, 100
  from sri_os.chart_of_accounts where code = '5900';
commit;
\set ON_ERROR_STOP 1

do $$
begin
  if exists (select 1 from sri_os.transactions
              where id = '00000000-0000-0000-0000-0000000f0003') then
    raise exception 'FAIL: รายการที่มีบรรทัดเดียว (เดบิตลอย) commit ผ่าน';
  end if;
  raise notice 'ok L6 · รายการที่มีบรรทัดเดียวไม่ผ่าน (ทั้งไม่สมดุลและ < 2 บรรทัด)';
end $$;

-- ---------- L8 · ย้ายบรรทัดข้ามหัวรายการ (ขาเดียว) ----------
-- รูที่ผู้ตรวจรันได้จริง: UPDATE ตรวจแค่หัวรายการปลายทาง ต้นทางเหลือ dr 2000 / cr 0
do $$
declare v_dr numeric; v_cr numeric; n int;
begin
  begin
    -- หัวรายการปลายทางสร้างใน xact นี้ (เงื่อนไข "ลงพร้อมกัน" เป็นจริงสำหรับปลายทาง)
    insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
    values ('00000000-0000-0000-0000-0000000f0004',
            (select id from sri_os.owners where code = 'SRI_HOLDING'),
            'exp.other', current_date, array['e.pdf']);

    update sri_os.transaction_lines
       set transaction_id = '00000000-0000-0000-0000-0000000f0004'
     where transaction_id = '00000000-0000-0000-0000-0000000f0001' and credit > 0;
    raise exception 'FAIL: ย้ายขาเครดิตออกจากรายการที่ post แล้วได้ → ต้นทางเหลือ dr/cr ไม่เท่ากัน';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  select coalesce(sum(debit), 0), coalesce(sum(credit), 0), count(*) into v_dr, v_cr, n
    from sri_os.transaction_lines where transaction_id = '00000000-0000-0000-0000-0000000f0001';
  if v_dr <> 500 or v_cr <> 500 or n <> 2 then
    raise exception 'FAIL: รายการต้นทางเพี้ยน (dr % cr % % บรรทัด)', v_dr, v_cr, n;
  end if;
  raise notice 'ok L8 · ย้ายบรรทัดขาเดียวข้ามหัวรายการไม่ได้ · ต้นทางยัง 500/500 ครบ 2 บรรทัด';
end $$;

-- ---------- L9 · ย้ายทั้งสองบรรทัด (เคสที่ทำให้ posted เหลือ 0 บรรทัด) ----------
do $$
declare n int;
begin
  begin
    insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
    values ('00000000-0000-0000-0000-0000000f0005',
            (select id from sri_os.owners where code = 'SRI_HOLDING'),
            'exp.other', current_date, array['e.pdf']);

    update sri_os.transaction_lines
       set transaction_id = '00000000-0000-0000-0000-0000000f0005'
     where transaction_id = '00000000-0000-0000-0000-0000000f0001';
    raise exception 'FAIL: ย้ายทั้งสองบรรทัดได้ → รายการ posted เหลือ 0 บรรทัด';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  select count(*) into n from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-0000000f0001';
  if n <> 2 then raise exception 'FAIL: ต้นทางเหลือ % บรรทัด', n; end if;
  raise notice 'ok L9 · ย้ายทั้งสองบรรทัดไม่ได้ · ต้นทางยังครบ 2 บรรทัด';
end $$;

-- ---------- L10 · ย้าย owner ของรายการที่ post แล้ว (บุคคล → นิติบุคคล) ----------
-- fn_corporate_immutable อ่าน old.owner_id จึงกันได้แค่รายการที่เป็นนิติบุคคลอยู่แล้ว
-- และ fn_corporate_requires_evidence เดิมเป็น BEFORE INSERT → เส้นทางนี้หลุดทั้งสองตัว
begin;
-- ใส่ไฟล์แนบไว้ด้วย เพื่อให้ **เฉพาะ** กฎ owner เป็นตัวบล็อก ไม่ใช่กติกาหลักฐาน
-- (ถ้าไม่ใส่ trg_corporate_evidence จะบล็อกก่อน แล้วเทสต์นี้จะผ่านทั้งที่ยังไม่มีกฎ owner)
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
values ('00000000-0000-0000-0000-0000000f0006',
        (select id from sri_os.owners where code = 'SUTEE'), 'exp.other', current_date,
        array['personal.pdf']);
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '00000000-0000-0000-0000-0000000f0006', c.id,
       case when c.rn = 1 then 2000 else 0 end,
       case when c.rn = 2 then 2000 else 0 end
  from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('5900', 1), ('2100', 2)) as v(code, rn) on v.code = c2.code) c;
commit;

do $$
declare v_code text;
begin
  begin
    update sri_os.transactions
       set owner_id = (select id from sri_os.owners where code = 'SRI_CORP')
     where id = '00000000-0000-0000-0000-0000000f0006';
    raise exception 'FAIL: ย้ายรายการของบุคคลเข้าสมุดนิติบุคคลด้วย UPDATE ได้ (ไม่มีไฟล์แนบ/คู่ค้า)';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  select o.code into v_code from sri_os.transactions t
    join sri_os.owners o on o.id = t.owner_id
   where t.id = '00000000-0000-0000-0000-0000000f0006';
  if v_code <> 'SUTEE' then raise exception 'FAIL: ผู้ถือเปลี่ยนเป็น %', v_code; end if;
  raise notice 'ok L10 · ย้ายผู้ถือของรายการที่บันทึกแล้วไม่ได้ · ยังเป็น SUTEE';
end $$;

-- ---------- L11 · ล้างไฟล์แนบของรายการนิติบุคคลด้วย UPDATE ----------
do $$
declare v text[];
begin
  begin
    -- f0001 ถูก void ไปแล้วที่ L4 · D-098 ห้ามแก้ร่องรอยการยกเลิกย้อนหลัง
    -- → UPDATE นี้คง voided_* เดิมไว้ (เคสนี้วัดกติกาหลักฐาน ไม่ใช่กติกาการ void)
    update sri_os.transactions set attachments = '{}', status = 'void'
     where id = '00000000-0000-0000-0000-0000000f0001';
    raise exception 'FAIL: ล้างไฟล์แนบของรายการนิติบุคคลด้วย UPDATE ได้ = กติกาหลักฐานไม่ถูกบังคับตอน UPDATE';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  select attachments into v from sri_os.transactions
   where id = '00000000-0000-0000-0000-0000000f0001';
  if cardinality(v) = 0 then raise exception 'FAIL: ไฟล์แนบถูกล้างไปแล้ว'; end if;

  -- ขาบวก: void ตามปกติ (ไม่แตะไฟล์แนบ) ต้องยังทำได้ ไม่งั้นเส้นทาง reverse ตาย
  -- void ซ้ำบนแถวที่ void แล้ว = ไม่แตะ voided_at/voided_by/void_reason (D-098 แช่แข็ง)
  update sri_os.transactions set status = 'void'
   where id = '00000000-0000-0000-0000-0000000f0001';
  raise notice 'ok L11 · ล้างไฟล์แนบตอน UPDATE ไม่ได้ · แต่ void ตามปกติยังทำได้';
end $$;

-- ---------- L12 · view ที่สร้างหลัง migrate ต้องได้ security_invoker อัตโนมัติ ----------
create view sri_os.v_zz_probe as select 1 as x;
do $$
declare v text;
begin
  select array_to_string(c.reloptions, ',') into v
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relname = 'v_zz_probe';
  if coalesce(v, '') not ilike '%security_invoker=true%' then
    raise exception 'FAIL: view ที่สร้างหลัง migrate ไม่ได้ security_invoker (reloptions: %) = ทางลัดข้าม RLS เปิดใหม่ได้เรื่อยๆ', coalesce(v, '(ว่าง)');
  end if;
  raise notice 'ok L12 · view ที่สร้างใหม่ได้ security_invoker อัตโนมัติจาก event trigger';
end $$;
drop view sri_os.v_zz_probe;

-- ---------- L13 · เส้นทาง post ที่มี savepoint / exception handler ต้องทำได้ ----------
-- แถวที่เขียนในบล็อกที่มี exception handler ได้ xid ของ subtransaction
-- ถ้า trigger เทียบ xmin = pg_current_xact_id() ตรงๆ การ post ที่ถูกต้องจะถูกปฏิเสธหมด
do $$
declare v_dr numeric;
begin
  begin
    insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
    values ('00000000-0000-0000-0000-0000000f0007',
            (select id from sri_os.owners where code = 'SRI_HOLDING'),
            'exp.other', current_date, array['e.pdf']);
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
    select '00000000-0000-0000-0000-0000000f0007', c.id,
           case when c.rn = 1 then 777 else 0 end,
           case when c.rn = 2 then 777 else 0 end
      from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('5900', 1), ('2100', 2)) as v(code, rn) on v.code = c2.code) c;
  exception when others then
    raise exception 'FAIL: post ในบล็อกที่มี exception handler (subtransaction) ถูกปฏิเสธ: %', sqlerrm;
  end;
  select sum(debit) into v_dr from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-0000000f0007';
  if v_dr <> 777 then raise exception 'FAIL: ลงบรรทัดไม่ครบ (ได้ %)', v_dr; end if;
  raise notice 'ok L13 · post ผ่าน savepoint/exception handler ได้ (777)';
end $$;

-- ============================================================
-- รอบสาม · รูที่ผู้ตรวจรันได้จริง (L14–L22 + P1/P2)
-- ============================================================

-- ---------- L14 · ปลอม created_at ตอน INSERT (ทั้งสองตาราง) ----------
-- นี่คือคานงัดของการโจมตีสอง session: เงื่อนไข "ลงในธุรกรรมเดียวกัน" เดิมอ่าน created_at
-- ซึ่งผู้เรียกเขียนได้ตอน INSERT (trigger เดิมเป็น BEFORE UPDATE เท่านั้น)
begin;
-- ใช้ owner ฝั่งบุคคล เพราะ L15 ต้อง UPDATE แถวนี้ และ corporate_strict ห้ามแก้รายการที่ post แล้ว
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments, created_at)
values ('00000000-0000-0000-0000-0000000f0014',
        (select id from sri_os.owners where code = 'SUTEE'),
        'exp.other', current_date, array['e.pdf'], '2001-01-01 00:00:00+00');
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, created_at)
select '00000000-0000-0000-0000-0000000f0014', c.id,
       case when c.rn = 1 then 140 else 0 end,
       case when c.rn = 2 then 140 else 0 end,
       '2001-01-01 00:00:00+00'
  from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('5900', 1), ('2100', 2)) as v(code, rn) on v.code = c2.code) c;
commit;

do $$
declare v_txn timestamptz; v_line timestamptz; v_w text;
begin
  select created_at, write_txn_id::text into v_txn, v_w from sri_os.transactions
   where id = '00000000-0000-0000-0000-0000000f0014';
  select min(created_at) into v_line from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-0000000f0014';

  if v_txn < now() - interval '1 day' then
    raise exception 'FAIL: created_at ของหัวรายการถูกผู้เรียกกำหนดได้ตอน INSERT (%)', v_txn;
  end if;
  if v_line is null or v_line < now() - interval '1 day' then
    raise exception 'FAIL: created_at ของบรรทัดบัญชีถูกผู้เรียกกำหนดได้ตอน INSERT (%)', v_line;
  end if;
  if v_w is null then
    raise exception 'FAIL: write_txn_id ไม่ถูกตั้ง = หลักฐาน "ธุรกรรมเดียวกัน" ไม่มีอยู่';
  end if;
  raise notice 'ok L14 · created_at ทั้งสองตารางถูกเขียนทับด้วย now() · write_txn_id ถูกตั้งให้ (%)', v_w;
end $$;

-- ---------- L15 · ปลอม created_at / write_txn_id ตอน UPDATE ----------
do $$
declare v_before timestamptz; v_after timestamptz; v_w text; v_w2 text;
begin
  select created_at, write_txn_id::text into v_before, v_w from sri_os.transactions
   where id = '00000000-0000-0000-0000-0000000f0014';
  update sri_os.transactions
     set created_at = '2001-01-01 00:00:00+00', write_txn_id = pg_current_xact_id()
   where id = '00000000-0000-0000-0000-0000000f0014';
  select created_at, write_txn_id::text into v_after, v_w2 from sri_os.transactions
   where id = '00000000-0000-0000-0000-0000000f0014';
  if v_after <> v_before then raise exception 'FAIL: created_at แก้ได้ตอน UPDATE (% → %)', v_before, v_after; end if;
  if v_w2 <> v_w then
    raise exception 'FAIL: write_txn_id แก้ได้ตอน UPDATE (% → %) = ทำให้หัวรายการเก่า "กลายเป็นของธุรกรรมนี้" แล้วยัดบรรทัดได้', v_w, v_w2;
  end if;
  raise notice 'ok L15 · created_at และ write_txn_id ถูก pin ตอน UPDATE';
end $$;

-- ---------- L16 · หัวรายการ void ที่ไม่มีบรรทัดเลย ต้อง commit ไม่ผ่าน ----------
-- เดิม trg_posted_needs_lines ข้าม status ที่ไม่ใช่ posted → แถวนี้ commit ผ่าน
-- แล้วกลายเป็น "ที่ว่าง" ให้ธุรกรรมอื่นมาวางบรรทัดแล้ว flip เป็น posted
\set ON_ERROR_STOP 0
begin;
-- ร่องรอยการยกเลิกต้องครบ (D-098) ไม่งั้นแถวนี้จะถูกปฏิเสธด้วยเหตุผลคนละเรื่อง
-- (transactions_void_fields_both_ways) แล้วเคสนี้จะ "เขียวเพราะกฎอื่น" ไม่ได้วัดกฎที่ตั้งใจ
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments, status,
                                voided_at, voided_by, void_reason)
values ('00000000-0000-0000-0000-0000000f0016',
        (select id from sri_os.owners where code = 'SRI_HOLDING'),
        'exp.other', current_date, array['e.pdf'], 'void',
        now(), '00000000-0000-0000-0000-0000000f0a01', 'เทสต์ L16 · หัวรายการ void 0 บรรทัด');
commit;
\set ON_ERROR_STOP 1

do $$
begin
  if exists (select 1 from sri_os.transactions where id = '00000000-0000-0000-0000-0000000f0016') then
    raise exception 'FAIL: หัวรายการ status=void ที่มี 0 บรรทัด commit ผ่าน = ที่วางบรรทัดข้ามธุรกรรม';
  end if;
  raise notice 'ok L16 · หัวรายการ void 0 บรรทัด commit ไม่ผ่าน (บังคับทุกสถานะ ไม่ใช่แค่ posted)';
end $$;

-- ---------- L17 · void → posted ย้อนไม่ได้ ทั้ง management และ super_admin ----------
-- รายได้นับซ้ำ: ขากลับรายการยังอยู่ แต่ต้นฉบับถูกปลุกกลับมา posted → debit 1,400 แทน 700
-- เป็น Money Invariant จึงต้องบังคับ **ทุก owner** ไม่ใช่แค่ corporate_strict
insert into auth.users(id) values
  ('00000000-0000-0000-0000-0000000f1a01'), ('00000000-0000-0000-0000-0000000f1a02')
on conflict do nothing;
insert into sri_os.app_users(id, email, display_name, role, is_active) values
  ('00000000-0000-0000-0000-0000000f1a01', 'sa@zz',  'ZZ SuperAdmin', 'super_admin', true),
  ('00000000-0000-0000-0000-0000000f1a02', 'mgmt@zz','ZZ Management', 'management',  true)
on conflict (id) do update set role = excluded.role, is_active = true;
insert into sri_os.user_owner_access(user_id, owner_id)
select u, o.id from (values
  ('00000000-0000-0000-0000-0000000f1a01'::uuid), ('00000000-0000-0000-0000-0000000f1a02'::uuid)
) as x(u) cross join sri_os.owners o
on conflict do nothing;

-- รายการของ **บุคคล** (SUTEE) ที่ posted แล้ว → void
-- ใช้ฝั่งบุคคลเพราะ fn_corporate_immutable ไม่แตะ owner ฝั่งนี้เลย
-- ถ้าเทสต์นี้ผ่านแปลว่ากฎ "void ปลายทาง" บังคับกับทุก owner จริง ไม่ได้ผ่านเพราะกติกานิติบุคคล
update sri_os.transactions set status = 'void', voided_at = now(), voided_by = coalesce(auth.uid(), (select id from sri_os.app_users order by created_at limit 1)), void_reason = $vr$เทสต์ D-098 · ยกเลิกรายการ$vr$
 where id = '00000000-0000-0000-0000-0000000f0006';

do $$
declare r record; v_status text; n int;
begin
  -- ชั้นที่ 1: superuser ของ cluster (ข้าม RLS ทุกอย่าง) ก็ยังทำไม่ได้
  -- = กฎอยู่ที่ trigger ไม่ได้อยู่ที่ RLS หรือตารางสิทธิ์
  begin
    update sri_os.transactions set status = 'posted'
     where id = '00000000-0000-0000-0000-0000000f0006';
    raise exception 'FAIL: superuser ปลุกรายการที่ void แล้วกลับเป็น posted ได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%void%' then
      raise exception 'FAIL: error ไม่ได้บอกเรื่อง void: %', sqlerrm;
    end if;
  end;

  -- ชั้นที่ 2: role จริงของแอป · ต้องล้มที่ trigger ไม่ใช่ล้มเพราะ RLS มองไม่เห็นแถว
  -- (ถ้าล้มเพราะ RLS เทสต์จะผ่านทั้งที่ยังไม่มีกฎ void — จึงแยกสองกรณีออกจากกัน)
  for r in select * from (values
      ('00000000-0000-0000-0000-0000000f1a02'::uuid, 'management'),
      ('00000000-0000-0000-0000-0000000f1a01'::uuid, 'super_admin')
    ) as x(uid, label)
  loop
    begin
      perform set_config('test.uid', r.uid::text, true);
      execute 'set local role authenticated';
      update sri_os.transactions set status = 'posted'
       where id = '00000000-0000-0000-0000-0000000f0006';
      get diagnostics n = row_count;
      execute 'reset role';
      if n > 0 then
        raise exception 'FAIL: % ปลุกรายการที่ void แล้วกลับเป็น posted ได้ = รายได้นับซ้ำ', r.label;
      end if;
      raise exception 'FAIL: RLS บล็อก % ก่อนถึง trigger (% แถว) — เทสต์นี้จึงไม่ได้พิสูจน์กฎ void', r.label, n;
    exception when raise_exception then
      if sqlerrm like 'FAIL:%' then raise; end if;
      if sqlerrm not like '%void%' then
        raise exception 'FAIL: error ของ % ไม่ได้บอกเรื่อง void: %', r.label, sqlerrm;
      end if;
    end;

    select status::text into v_status from sri_os.transactions
     where id = '00000000-0000-0000-0000-0000000f0006';
    if v_status <> 'void' then
      raise exception 'FAIL: สถานะกลายเป็น % หลัง % ลองปลุก', v_status, r.label;
    end if;
  end loop;
  raise notice 'ok L17 · void → posted ล้มทั้ง superuser · management · super_admin (owner ฝั่งบุคคล = บังคับทุก owner)';
end $$;

-- ---------- L18 · ขาบวก: void ของรายการที่ถูกต้องยังทำได้ (ไม่กันแน่นเกิน) ----------
begin;
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
values ('00000000-0000-0000-0000-0000000f0018',
        (select id from sri_os.owners where code = 'SRI_HOLDING'),
        'exp.other', current_date, array['e.pdf']);
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '00000000-0000-0000-0000-0000000f0018', c.id,
       case when c.rn = 1 then 700 else 0 end,
       case when c.rn = 2 then 700 else 0 end
  from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('5900', 1), ('2100', 2)) as v(code, rn) on v.code = c2.code) c;
commit;

do $$
declare v text;
begin
  update sri_os.transactions set status = 'void', voided_at = now(), voided_by = coalesce(auth.uid(), (select id from sri_os.app_users order by created_at limit 1)), void_reason = $vr$เทสต์ D-098 · ยกเลิกรายการ$vr$
   where id = '00000000-0000-0000-0000-0000000f0018';
  select status::text into v from sri_os.transactions
   where id = '00000000-0000-0000-0000-0000000f0018';
  if v <> 'void' then raise exception 'FAIL: void รายการปกติไม่ได้ (status %)', v; end if;
  raise notice 'ok L18 · void รายการที่ถูกต้องยังทำได้ (บรรทัดยังอยู่ครบ = void จริงๆ หน้าตาแบบนี้)';
end $$;

-- ---------- L19 · ขาบวก: reverse ที่ถูกต้องยังข้ามหลักฐานได้ ----------
-- ต้นฉบับ: corporate posted 700 พร้อมหลักฐาน · ขากลับ: source=reverse ชี้ต้นฉบับ ไม่มีไฟล์แนบ
begin;
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
values ('00000000-0000-0000-0000-0000000f0019',
        (select id from sri_os.owners where code = 'SRI_HOLDING'),
        'exp.other', current_date, array['invoice.pdf']);
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '00000000-0000-0000-0000-0000000f0019', c.id,
       case when c.rn = 1 then 700 else 0 end,
       case when c.rn = 2 then 700 else 0 end
  from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('5900', 1), ('2100', 2)) as v(code, rn) on v.code = c2.code) c;
commit;

begin;
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, source, reverses_id, attachments)
values ('00000000-0000-0000-0000-0000000f001a',
        (select id from sri_os.owners where code = 'SRI_HOLDING'),
        'exp.other', current_date, 'reverse', '00000000-0000-0000-0000-0000000f0019', '{}');
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '00000000-0000-0000-0000-0000000f001a', l.coa_id, l.credit, l.debit
  from sri_os.transaction_lines l where l.transaction_id = '00000000-0000-0000-0000-0000000f0019';
-- เดิมบรรทัดถัดไป void ต้นฉบับทิ้งด้วย · **ถอดออกแล้ว (09/10)** ตาม D-097:
--   void กับ reverse เป็นสองกลไกที่ใช้ต่างสถานการณ์ ห้ามปนกัน — ต้นฉบับที่ถูก
--   กลับรายการต้องยัง posted (นับต่อไป) ไม่งั้นสมุดผิดไป −ต้นฉบับ
--   ตอนนี้ trg_void_blocked_by_reverse ปฏิเสธคำสั่งนั้นแล้ว (ดู zz_reverse_integrity_test R12)
commit;

do $$
declare n int;
begin
  select count(*) into n from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-0000000f001a';
  if n <> 2 then
    raise exception 'FAIL: reverse ที่ถูกต้อง (ไม่มีไฟล์แนบ แต่ชี้ต้นฉบับจริง) ลงไม่ได้ · เหลือ % บรรทัด', n;
  end if;
  raise notice 'ok L19 · reverse ที่ถูกต้องยังข้ามกติกาหลักฐานได้ (หลักฐานคือต้นฉบับ)';
end $$;

-- ---------- L20 · source=reverse ที่ reverses_id เป็น null ----------
-- รูของผู้ตรวจ: posted 5,000,000 ในสมุดนิติบุคคล ไม่มีหลักฐาน ไม่มีคู่ค้า
do $$
begin
  begin
    insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, source, attachments)
    values ('00000000-0000-0000-0000-0000000f0020',
            (select id from sri_os.owners where code = 'SRI_CORP'),
            'exp.other', current_date, 'reverse', '{}');
    raise exception 'FAIL: source=reverse ที่ไม่ชี้รายการไหนเลย ลงได้ = ข้ามหลักฐานด้วยการอ้างคำว่า reverse';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  if exists (select 1 from sri_os.transactions where id = '00000000-0000-0000-0000-0000000f0020') then
    raise exception 'FAIL: แถวยังถูกสร้าง';
  end if;
  raise notice 'ok L20 · source=reverse ที่ reverses_id เป็น null ลงไม่ได้';
end $$;

-- ---------- L21 · reverse ที่ชี้ไปรายการของผู้ถืออื่น ----------
do $$
begin
  begin
    insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, source, reverses_id, attachments)
    values ('00000000-0000-0000-0000-0000000f0021',
            (select id from sri_os.owners where code = 'SRI_CORP'),
            'exp.other', current_date, 'reverse',
            '00000000-0000-0000-0000-0000000f0006',   -- รายการของ SUTEE
            '{}');
    raise exception 'FAIL: กลับรายการข้ามสมุดผู้ถือได้ = ยอดของอีกคนหายไปโดยไม่มีใครรู้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  raise notice 'ok L21 · reverse ที่ชี้ไปรายการของผู้ถืออื่นลงไม่ได้';
end $$;

-- ---------- L22 · reverse ตัวที่สองของรายการเดิม (กลับรายการซ้ำสองรอบ) ----------
do $$
begin
  begin
    insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, source, reverses_id, attachments)
    values ('00000000-0000-0000-0000-0000000f0022',
            (select id from sri_os.owners where code = 'SRI_HOLDING'),
            'exp.other', current_date, 'reverse',
            '00000000-0000-0000-0000-0000000f0019',   -- ถูกกลับรายการด้วย f001a แล้ว
            '{}');
    raise exception 'FAIL: กลับรายการเดิมได้สองรอบ = เครดิตซ้ำ';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  raise notice 'ok L22 · กลับรายการเดิมรอบที่สองลงไม่ได้';
end $$;

-- ---------- L23 · ลงรายการ + กลับรายการ ในฐานะ authenticated จริง ----------
-- เทสต์อื่นในไฟล์นี้รันเป็น superuser ของ cluster = ไม่เคยแตะชั้น GRANT เลย
-- ถ้ากฎใหม่ต้องการ execute บนฟังก์ชันที่ authenticated ไม่มี (เช่น fn_reverse_link_ok
-- ที่ trigger ซึ่งไม่ใช่ security definer เรียก) แอปจะล้มแต่เทสต์จะเขียว
-- เคสนี้จึงต้องเดินเส้นทางจริงด้วย role จริง
do $$
declare n int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000f1a02', true);  -- management
  execute 'set local role authenticated';

  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
  values ('00000000-0000-0000-0000-0000000f0023',
          (select id from sri_os.owners where code = 'SRI_HOLDING'),
          'exp.other', current_date, array['invoice.pdf']);
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
  select '00000000-0000-0000-0000-0000000f0023', c.id,
         case when c.rn = 1 then 230 else 0 end,
         case when c.rn = 2 then 230 else 0 end
    from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('5900', 1), ('2100', 2)) as v(code, rn) on v.code = c2.code) c;

  -- ขากลับรายการ: ไม่มีไฟล์แนบ · ผ่านได้เพราะชี้ต้นฉบับจริง (ต้องเรียก fn_reverse_link_ok ได้)
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, source, reverses_id, attachments)
  values ('00000000-0000-0000-0000-0000000f0024',
          (select id from sri_os.owners where code = 'SRI_HOLDING'),
          'exp.other', current_date, 'reverse', '00000000-0000-0000-0000-0000000f0023', '{}');
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
  select '00000000-0000-0000-0000-0000000f0024', l.coa_id, l.credit, l.debit
    from sri_os.transaction_lines l
   where l.transaction_id = '00000000-0000-0000-0000-0000000f0023';

  select count(*) into n from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-0000000f0024';
  execute 'reset role';
  if n <> 2 then raise exception 'FAIL: ขากลับรายการลงได้ % บรรทัด', n; end if;
  raise notice 'ok L23 · post + reverse ในฐานะ authenticated (ผ่านชั้น GRANT และ RLS) ทำได้';
exception when others then
  execute 'reset role';
  raise exception 'FAIL: เส้นทางจริงของ authenticated ล้ม (% ) — สิทธิ์ GRANT/execute ไม่พอ หรือกฎใหม่กันแน่นเกิน', sqlerrm;
end $$;

-- ---------- P1 · สิทธิ์ของ authenticated ต้องตรงกับที่ migration ให้ ----------
-- ที่มา: ผู้ตรวจรายงานว่า authenticated TRUNCATE ได้ — false positive จาก harness
-- (เดิม harness `grant all`) · แล้วตรวจของจริงพบว่า **ไม่มี ACL เลย** (แอปใช้งานไม่ได้)
-- → สิทธิ์ย้ายไปอยู่ใน supabase/migrations/20261007000001_grants.sql ทั้งสองฝั่งใช้ไฟล์เดียวกัน
-- เทสต์นี้ assert จากสิ่งที่ migration ให้ ไม่ใช่จากค่าที่ harness ตั้งเอง
do $$
declare v text; v2 text; n int;
begin
  -- 1) ต้องไม่มีสิทธิ์อันตราย
  select string_agg(table_name || '.' || privilege_type, ', '), count(*) into v, n
    from information_schema.role_table_grants
   where table_schema = 'sri_os'
     and grantee = 'authenticated'
     and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER');
  if n > 0 then
    raise exception 'FAIL: authenticated มีสิทธิ์ที่ migration ไม่ได้ให้ (% รายการ): % · TRUNCATE ล้างสมุดได้โดยไม่ยิง trigger และไม่เหลือ audit', n, v;
  end if;

  -- 2) ต้องมี DML ครบทุกตารางการเงิน ไม่งั้นข้อ 1 ผ่านฟรีๆ และแอปใช้งานไม่ได้ (สถานะของจริง)
  --    ข้อยกเว้นที่ **ตั้งใจ** และตรวจแยกต่อข้างล่าง ไม่ใช่ยกเว้นแล้วเลิกตรวจ:
  --      · `owners` ถูก revoke UPDATE ระดับตารางแล้ว grant เป็นระดับคอลัมน์ (20261007000005)
  --        → ข้อ 2b ตรวจว่า column grant ถูกต้องจริง
  --      · ตารางที่มีคอลัมน์ขึ้นทะเบียนเป็น `grant` ใน sri_os.column_exposure ถูก revoke
  --        SELECT ระดับตารางแล้ว grant เป็นระดับคอลัมน์ (20261020000000 · D-089)
  --        → ข้อ 2c ตรวจว่ายังเหลือ DML ที่จำเป็นและคอลัมน์ที่เปิดยังอ่านได้
  --        (รายการยกเว้นอ่านจากทะเบียนใน DB ไม่ใช่พิมพ์ชื่อตารางมือ → ตารางที่ติดด่าน
  --         เพิ่มขึ้นในอนาคตก็ยังถูกตรวจด้วยกฎเดียวกัน)
  select string_agg(t.c, ', '), count(*) into v, n from (
    select c.relname as c
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'sri_os' and c.relkind = 'r'
       and c.relname <> 'owners'
       and not exists (select 1 from sri_os.column_exposure ce
                        where ce.table_name = c.relname and ce.exposure = 'grant')
       and (select count(*) from information_schema.role_table_grants g
             where g.table_schema = 'sri_os' and g.grantee = 'authenticated'
               and g.table_name = c.relname
               and g.privilege_type in ('SELECT','INSERT','UPDATE','DELETE')) <> 4
  ) t;
  if n > 0 then
    raise exception 'FAIL: % ตารางที่ authenticated ไม่มี DML ครบสี่ตัว: % → แอปถูกปฏิเสธที่ชั้น GRANT ก่อนถึง RLS', n, v;
  end if;

  -- 2b) owners: INSERT/DELETE ระดับตารางต้องยังมี · UPDATE ต้องไม่มีระดับตาราง
  --     SELECT ของ owners ย้ายไปเป็นระดับคอลัมน์แล้ว (20261020000000 · D-089 ปิด
  --     tax_id_last4) → ความครบของ SELECT ถูกตรวจในข้อ 2c จากทะเบียน column_exposure
  foreach v in array array['INSERT', 'DELETE'] loop
    if not exists (
      select 1 from information_schema.role_table_grants
       where table_schema = 'sri_os' and table_name = 'owners'
         and grantee = 'authenticated' and privilege_type = v
    ) then
      raise exception 'FAIL: authenticated ไม่มี % บน owners → เพิ่ม/ดูผู้ถือไม่ได้', v;
    end if;
  end loop;
  if exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'sri_os' and table_name = 'owners'
       and grantee = 'authenticated' and privilege_type = 'UPDATE'
  ) then
    raise exception 'FAIL: owners มี UPDATE ระดับตาราง → column grant ของคอลัมน์กติกาไม่มีผล (ปลด corporate_strict ได้ด้วยคำสั่งเดียว)';
  end if;

  -- 2c) ตารางที่มีด่านคอลัมน์ (D-089): SELECT ระดับตารางต้องไม่มี · INSERT/UPDATE/DELETE
  --     ระดับตารางต้องยังมี · และคอลัมน์ที่ทะเบียนบอกว่าเปิดต้องอ่านได้จริงทุกตัว
  --     (ไม่งั้น "ยกเว้นจากข้อ 2" จะกลายเป็นช่องที่ตารางไม่มีสิทธิ์อะไรเลยแล้วไม่มีใครรู้)
  for v in select distinct ce.table_name from sri_os.column_exposure ce
            where ce.exposure = 'grant' order by 1
  loop
    if exists (
      select 1 from information_schema.role_table_grants
       where table_schema = 'sri_os' and table_name = v
         and grantee = 'authenticated' and privilege_type = 'SELECT'
    ) then
      raise exception 'FAIL: % มี SELECT ระดับตาราง → ด่านคอลัมน์ของ D-089 ไม่มีผลเลย', v;
    end if;
    select count(*) into n from information_schema.role_table_grants
     where table_schema = 'sri_os' and table_name = v and grantee = 'authenticated'
       and privilege_type in ('INSERT', 'UPDATE', 'DELETE');
    -- owners ถูก revoke UPDATE ระดับตารางไว้ด้วย (20261007000005) → คาด 2 ไม่ใช่ 3
    if n <> (case when v = 'owners' then 2 else 3 end) then
      raise exception 'FAIL: % มี INSERT/UPDATE/DELETE ระดับตารางแค่ % ตัว → แอปเขียนไม่ได้', v, n;
    end if;
    select string_agg(ce.column_name, ', '), count(*) into v2, n
      from sri_os.column_exposure ce
     where ce.table_name = v and ce.exposure in ('open', 'row')
       and not has_column_privilege('authenticated',
             ('sri_os.' || quote_ident(v))::regclass, ce.column_name, 'select');
    if n > 0 then
      raise exception 'FAIL: %: คอลัมน์ที่ทะเบียนบอกว่าเปิด อ่านไม่ได้ % คอลัมน์: % → หน้าจอที่ต้องใช้จะพัง', v, n, v2;
    end if;
  end loop;

  -- 3) anon ต้องไม่มีอะไรเลย (ระบบนี้ต้องล็อกอินทุกหน้า ไม่มีหน้า public)
  if has_schema_privilege('anon', 'sri_os', 'usage') then
    raise exception 'FAIL: anon มี usage บนสคีมา sri_os = อ่านได้ด้วย anon key ที่ฝังในหน้าเว็บ';
  end if;
  select count(*) into n from information_schema.role_table_grants
   where table_schema = 'sri_os' and grantee = 'anon';
  if n > 0 then raise exception 'FAIL: anon มีสิทธิ์บนตารางใน sri_os % รายการ', n; end if;

  -- 4) ฟังก์ชันภายใน (trigger function + fn_assert_*) ต้องเรียกจากข้างนอกไม่ได้
  select string_agg(p.proname, ', '), count(*) into v, n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and (p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype)
          or p.proname in ('fn_assert_line_writable', 'fn_assert_txn_balanced'))
     and has_function_privilege('authenticated', p.oid, 'execute');
  if n > 0 then
    raise exception 'FAIL: authenticated เรียกฟังก์ชันภายในได้ % ตัว: %', n, v;
  end if;

  -- 5) ฟังก์ชันที่ RLS/หน้าจอต้องใช้ ต้องเรียกได้ (ไม่งั้น select ล้มด้วย permission denied)
  foreach v in array array['fn_can(text)', 'fn_can_see_owner(uuid)', 'fn_can_see_asset(uuid)',
                           'fn_can_read_txn(uuid,uuid,uuid)', 'fn_can_read_contract(uuid,uuid)',
                           'fn_reverse_link_ok(uuid,uuid,uuid)'] loop
    if not has_function_privilege('authenticated', 'sri_os.' || v, 'execute') then
      raise exception 'FAIL: authenticated เรียก % ไม่ได้ = RLS/หน้าจอล้มทั้งระบบ', v;
    end if;
  end loop;

  raise notice 'ok P1 · สิทธิ์ตรงกับ migration: DML สี่ตัวครบทุกตาราง (owners = column grant) · ไม่มี TRUNCATE/REFERENCES/TRIGGER · anon ว่างเปล่า · ฟังก์ชันภายในปิด';
end $$;

-- ---------- P1b · RLS ต้องเปิดทุกตาราง และทุกตารางต้องมี policy ----------
-- ที่มา: P1 เดิมตรวจแต่ ACL จึง **มองไม่เห็น** ว่า asset_classes / asset_categories
--   ไม่เคยเปิด RLS เลย (relrowsecurity = false · policy 0 ตัว) · ตอนที่ยังไม่มีใคร
--   มีสิทธิ์ตารางก็ไม่มีผล แต่พอ 20261007000001_grants.sql ให้ DML ครบทุกตาราง
--   ตารางที่ RLS ปิด = **ไม่มีด่านอะไรเลย** → authenticated ที่ไม่มีแถวใน app_users
--   ลบ taxonomy ทิ้งได้ทั้งตาราง (ผู้ตรวจยิงผ่านจริง 07/10)
--   สองเงื่อนไขนี้ต้องคู่กันเสมอ: RLS เปิดแต่ไม่มี policy = ปฏิเสธ**เงียบๆ**
--   (0 แถว ไม่ใช่ error) ซึ่งเจอมาแล้วว่าทำให้หน้าจอว่างโดยไม่มีอะไรฟ้อง
do $$
declare v text; n int;
begin
  select string_agg(c.relname, ', ' order by c.relname), count(*) into v, n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r' and not c.relrowsecurity;
  if n > 0 then
    raise exception 'FAIL: % ตารางใน sri_os ที่ RLS ปิดอยู่: % · grants ให้ DML ทุกตาราง = RLS ปิดแปลว่าไม่มีด่านเลย', n, v;
  end if;

  select string_agg(c.relname, ', ' order by c.relname), count(*) into v, n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and not exists (select 1 from pg_policies p
                      where p.schemaname = 'sri_os' and p.tablename = c.relname);
  if n > 0 then
    raise exception 'FAIL: % ตารางที่เปิด RLS แต่ไม่มี policy เลย: % · จะปฏิเสธเงียบๆ (0 แถว ไม่ใช่ error) แล้วหน้าจอว่างโดยไม่มีอะไรบอกว่าทำไม', n, v;
  end if;

  -- กันเทสต์นี้กลายเป็นเทสต์เปล่า (ถ้าวันหนึ่งสคีมาว่าง ข้อบนจะผ่านฟรีๆ)
  select count(*) into n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r';
  if n < 24 then
    raise exception 'FAIL: นับตารางใน sri_os ได้แค่ % ตาราง — เทสต์นี้อาจไม่ได้ตรวจอะไรเลย', n;
  end if;
  raise notice 'ok P1b · ทั้ง % ตารางใน sri_os เปิด RLS และมี policy ครบ', n;
end $$;

-- ---------- P2 · TRUNCATE ถูกบล็อกที่ DB แม้สิทธิ์จะเปิด ----------
-- รันในฐานะ superuser ของ cluster = สิทธิ์เต็ม · ถ้ายังล้มแปลว่ากันที่ trigger จริง
-- ไม่ได้ขึ้นกับว่าใคร grant อะไร (หลักเดียวกับที่เลือก trigger แทน RLS)
do $$
declare r text; n int;
begin
  foreach r in array array['transactions', 'transaction_lines', 'audit_log'] loop
    begin
      execute format('truncate table sri_os.%I cascade', r);
      raise exception 'FAIL: TRUNCATE sri_os.% สำเร็จ = ล้างสมุดได้โดยไม่ยิง trigger ไม่เหลือ audit', r;
    exception when raise_exception then
      if sqlerrm like 'FAIL:%' then raise; end if;
    end;
  end loop;
  select count(*) into n from sri_os.transactions;
  if n = 0 then raise exception 'FAIL: ไม่มีรายการเหลือเลย = TRUNCATE ลงไปแล้ว'; end if;
  raise notice 'ok P2 · TRUNCATE ตารางการเงินล้มทุกตาราง (% รายการยังอยู่)', n;
end $$;

-- ---------- P3 · constraint ของตารางกฎที่หายไปจาก drift ต้องกลับมา ----------
-- 20260918000003 ล้มตอน add constraint เมื่อ replay จาก DB เปล่า (seed ยังไม่ได้รัน)
-- harness เคย SKIP เงียบๆ → เทสต์รันบน schema ที่ไม่เหมือนของจริง
-- 20261007000002 กู้ให้ · เทสต์นี้กันไม่ให้หายเงียบอีก
do $$
declare v text;
begin
  select string_agg(x.c, ', ') into v from (values
      ('txn_types_gain_loss_pair'), ('txn_types_interest_required')
    ) as x(c)
   where not exists (
     select 1 from pg_constraint
      where conrelid = 'sri_os.txn_types'::regclass and contype = 'c' and conname = x.c
   );
  if v is not null then
    raise exception 'FAIL: constraint ของตารางกฎหายไป (%) = DB ถือกฎไม่ครบเงียบๆ ทั้งที่ engine บังคับอยู่', v;
  end if;
  raise notice 'ok P3 · constraint ตารางกฎครบ (gain/loss pair · interest required)';
end $$;

-- ---------- L7 · การแก้บรรทัดต้องเหลือร่องรอยใน audit_log ----------
do $$
declare n int;
begin
  select count(*) into n from sri_os.audit_log where table_name = 'transaction_lines';
  if n < 2 then
    raise exception 'FAIL: audit_log มีบรรทัดบัญชีแค่ % แถว (ต้อง ≥ 2 จาก fixture) = แก้แล้วไม่เหลือร่องรอย', n;
  end if;
  raise notice 'ok L7 · audit_log บันทึกบรรทัดบัญชีแล้ว (% แถว)', n;
end $$;

do $$ begin raise notice '=== line integrity ผ่านทั้งหมด ==='; end $$;
