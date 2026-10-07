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
-- ============================================================

\set ON_ERROR_STOP 1

-- ---------- fixture: รายการที่ post แล้ว 500/500 (ธุรกรรมแยก จบด้วย commit) ----------
begin;
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
values ('00000000-0000-0000-0000-0000000f0001',
        (select id from sri_os.owners where code = 'SRI_HOLDING'),
        'inc.other', current_date, array['evidence.pdf']);

insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '00000000-0000-0000-0000-0000000f0001', c.id,
       case when c.rn = 1 then 500 else 0 end,
       case when c.rn = 2 then 500 else 0 end
  from (select id, row_number() over (order by code) rn
          from sri_os.chart_of_accounts where code not like '11%' order by code limit 2) c;
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
      from (select id, row_number() over (order by code) rn
              from sri_os.chart_of_accounts where code not like '11%' order by code limit 2) c;
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
  update sri_os.transactions set status = 'void'
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
        'inc.other', current_date, array['evidence.pdf']);
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
        'inc.other', current_date, array['evidence.pdf']);
insert into sri_os.transaction_lines(transaction_id, coa_id, debit)
select '00000000-0000-0000-0000-0000000f0003', id, 100
  from sri_os.chart_of_accounts where code not like '11%' order by code limit 1;
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
            'inc.other', current_date, array['e.pdf']);

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
            'inc.other', current_date, array['e.pdf']);

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
        (select id from sri_os.owners where code = 'SUTEE'), 'inc.other', current_date,
        array['personal.pdf']);
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '00000000-0000-0000-0000-0000000f0006', c.id,
       case when c.rn = 1 then 2000 else 0 end,
       case when c.rn = 2 then 2000 else 0 end
  from (select id, row_number() over (order by code) rn
          from sri_os.chart_of_accounts where code not like '11%' order by code limit 2) c;
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
            'inc.other', current_date, array['e.pdf']);
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
    select '00000000-0000-0000-0000-0000000f0007', c.id,
           case when c.rn = 1 then 777 else 0 end,
           case when c.rn = 2 then 777 else 0 end
      from (select id, row_number() over (order by code) rn
              from sri_os.chart_of_accounts where code not like '11%' order by code limit 2) c;
  exception when others then
    raise exception 'FAIL: post ในบล็อกที่มี exception handler (subtransaction) ถูกปฏิเสธ: %', sqlerrm;
  end;
  select sum(debit) into v_dr from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-0000000f0007';
  if v_dr <> 777 then raise exception 'FAIL: ลงบรรทัดไม่ครบ (ได้ %)', v_dr; end if;
  raise notice 'ok L13 · post ผ่าน savepoint/exception handler ได้ (777)';
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
