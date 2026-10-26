-- ============================================================
-- SRI OS · `fn_can_many()` ต้องตอบเหมือน `fn_can()` **ทุกบทบาท × ทุกสิทธิ์**
--            (20261025000022_fn_can_many.sql)
--
-- ทำไมมีฟังก์ชันนี้: หน้าจอหนึ่งหน้าเช็คสิทธิ์ 16 ตัว · DB อยู่สิงคโปร์ เว็บรัน
-- อเมริกา → 16 round trip = 3-4 วินาที · รวมเป็นคำถามเดียวจบ
-- **แต่ห้ามแลกด้วยการเขียนเกณฑ์สิทธิ์ซ้ำ** (ฝั่ง TypeScript หรือที่ไหนก็ตาม)
--
-- **ทุกเคสรันเป็น role `authenticated`** ไม่ใช่ superuser
--
--   C1 · ทั้ง 4 บทบาท × ทุกสิทธิ์ → `fn_can_many` = `fn_can` = ตารางสิทธิ์
--   C2 · ผู้ใช้ที่ถูกปิดใช้งาน → false ทุกตัว
--   C3 · ผู้ใช้ที่ไม่มีแถวใน `app_users` → false ทุกตัว · C3b · ไม่ล็อกอิน → false ทุกตัว
--   C4 · สิทธิ์ที่ไม่มีอยู่จริง → false **ไม่ใช่ error** (สะกดผิดตัวเดียวต้องไม่ทำให้หน้าล่ม)
--   C5 · อาร์เรย์ว่าง / null → ไม่พัง · ส่งซ้ำได้แถวซ้ำ (ฝั่งแอป map ชื่อ → boolean ได้ตรง)
--   **CM1 · MUTATION** — ถอดสิทธิ์ออกจากบทบาท → **ทั้งสองตัวเปลี่ยนพร้อมกัน**
--   **CM2 · MUTATION** — แก้ `fn_can` ให้ตอบ true หมด → `fn_can_many` ตอบ true ตาม
--        = พิสูจน์ว่ามัน **ถาม fn_can จริง** ไม่ใช่สำเนาเกณฑ์ที่เผอิญตรงกัน
-- ============================================================

\set ON_ERROR_STOP 1

begin;

create temporary table p_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into p_uid(label) values
  ('su'), ('mgmt'), ('mgr'), ('staff'), ('off'), ('ghost');

insert into auth.users(id) select id from p_uid;
-- `ghost` **ไม่มีแถวใน app_users** โดยตั้งใจ (เคส "ผู้ใช้ที่ยังไม่ถูกตั้งตำแหน่ง")
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@canmany.local', u.label, x.role, x.active
  from p_uid u
  join (values ('su', 'super_admin', true), ('mgmt', 'management', true),
               ('mgr', 'manager', true), ('staff', 'staff', true),
               ('off', 'management', false)) x(label, role, active) on x.label = u.label;

create or replace function pg_temp.login(p text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from p_uid where label = p), ''), true);
$fn$;

/** ผลของ fn_can_many ทั้งชุด → ข้อความเรียงชื่อสิทธิ์ที่ได้ true */
create or replace function pg_temp.many_true() returns text
language sql stable as $fn$
  select coalesce(string_agg(m.permission, ',' order by m.permission), '(ไม่มี)')
    from sri_os.fn_can_many((select array_agg(key order by key) from sri_os.permissions)) m
   where m.allowed;
$fn$;

/** ผลของ fn_can ทีละตัว → ข้อความรูปแบบเดียวกัน (เทียบกันได้ตรงๆ) */
create or replace function pg_temp.one_true() returns text
language sql stable as $fn$
  select coalesce(string_agg(p.key, ',' order by p.key), '(ไม่มี)')
    from sri_os.permissions p
   where sri_os.fn_can(p.key);
$fn$;

/** ความจริงจากตารางสิทธิ์โดยตรง (แหล่งที่สาม — กัน "ผิดเหมือนกันทั้งสองตัว") */
create or replace function pg_temp.table_true(p_role text) returns text
language sql stable as $fn$
  select coalesce(string_agg(rp.permission_key, ',' order by rp.permission_key), '(ไม่มี)')
    from sri_os.role_permissions rp where rp.role_key = p_role;
$fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.p_uid to authenticated', s);
end $$;

-- ============================================================
-- C1 · ทั้ง 4 บทบาท × ทุกสิทธิ์ — สามแหล่งต้องตรงกัน
-- ============================================================
do $$
declare
  r record; v_many text; v_one text; v_tbl text; n_perm int; n_rows int;
begin
  set local role authenticated;
  select count(*) into n_perm from sri_os.permissions;
  if n_perm = 0 then
    raise exception 'FAIL: C1 — ตาราง permissions ว่าง เทสต์นี้จะผ่านฟรีๆ';
  end if;

  for r in select * from (values ('su', 'super_admin'), ('mgmt', 'management'),
                                 ('mgr', 'manager'), ('staff', 'staff')) v(label, role)
  loop
    perform pg_temp.login(r.label);
    v_many := pg_temp.many_true();
    v_one  := pg_temp.one_true();
    v_tbl  := pg_temp.table_true(r.role);
    if v_many <> v_one then
      raise exception 'FAIL: C1 — บทบาท % : fn_can_many (%) ไม่ตรงกับ fn_can (%)',
        r.role, v_many, v_one;
    end if;
    if v_many <> v_tbl then
      raise exception 'FAIL: C1 — บทบาท % : ทั้งสองฟังก์ชันตอบ (%) แต่ตารางสิทธิ์บอก (%) — ผิดเหมือนกันทั้งสองตัว',
        r.role, v_many, v_tbl;
    end if;
  end loop;

  -- และต้องคืน **หนึ่งแถวต่อหนึ่งสิทธิ์ที่ส่งมา** ในคำถามเดียว (นี่คือจุดประสงค์)
  perform pg_temp.login('mgr');
  select count(*) into n_rows
    from sri_os.fn_can_many((select array_agg(key order by key) from sri_os.permissions));
  if n_rows <> n_perm then
    raise exception 'FAIL: C1 — ถาม % สิทธิ์ ต้องได้ % แถวในครั้งเดียว แต่ได้ % แถว',
      n_perm, n_perm, n_rows;
  end if;

  reset role;
  raise notice 'ok C1 · ทั้ง 4 บทบาท × % สิทธิ์: fn_can_many = fn_can = ตารางสิทธิ์ ตรงกันทุกช่อง · และได้ครบ % แถวในคำถามเดียว (แทน % round trip)',
    n_perm, n_perm, n_perm;
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- C2 + C3 · fail closed — ปิดใช้งาน / ไม่มีแถว / ไม่ล็อกอิน
-- ============================================================
do $$
declare v text;
begin
  set local role authenticated;

  perform pg_temp.login('off');
  v := pg_temp.many_true();
  if v <> '(ไม่มี)' then
    raise exception 'FAIL: C2 — ผู้ใช้ที่ถูกปิดใช้งานต้องได้ false ทุกตัว แต่ได้: %', v;
  end if;
  if pg_temp.one_true() <> v then
    raise exception 'FAIL: C2 — สองฟังก์ชันตอบไม่ตรงกันในเคสผู้ใช้ปิดใช้งาน';
  end if;

  perform pg_temp.login('ghost');
  v := pg_temp.many_true();
  if v <> '(ไม่มี)' then
    raise exception 'FAIL: C3 — ผู้ใช้ที่ไม่มีแถวใน app_users ต้องได้ false ทุกตัว แต่ได้: %', v;
  end if;

  -- C3b · ไม่ล็อกอินเลย
  perform set_config('test.uid', '', true);
  v := pg_temp.many_true();
  if v <> '(ไม่มี)' then
    raise exception 'FAIL: C3b — ไม่ล็อกอินต้องได้ false ทุกตัว แต่ได้: %', v;
  end if;

  reset role;
  raise notice 'ok C2-C3 · ปิดใช้งาน / ไม่มีแถวใน app_users / ไม่ล็อกอิน → false ทุกตัว (fail closed) และตรงกับ fn_can';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- C4 + C5 · เคสขอบที่ต้องไม่ทำให้หน้าจอล่ม
-- ============================================================
do $$
declare v_allowed boolean; n int;
begin
  set local role authenticated;
  perform pg_temp.login('su');

  -- C4 · สิทธิ์ที่ไม่มีอยู่จริง → false (ไม่ใช่ error · ไม่ใช่ true แม้เป็น super_admin)
  select m.allowed into v_allowed
    from sri_os.fn_can_many(array['settings.manage', 'สิทธิ์ที่ไม่มีอยู่จริง']) m
   where m.permission = 'สิทธิ์ที่ไม่มีอยู่จริง';
  if v_allowed is not false then
    raise exception 'FAIL: C4 — สิทธิ์ที่ไม่มีอยู่จริงต้องได้ false แต่ได้ %',
      coalesce(v_allowed::text, 'null');
  end if;
  -- และสิทธิ์จริงในคำถามเดียวกันต้องยังตอบถูก (ตัวปลอมไม่ลากตัวจริงลงไปด้วย)
  if (select m.allowed from sri_os.fn_can_many(array['settings.manage', 'สิทธิ์ที่ไม่มีอยู่จริง']) m
       where m.permission = 'settings.manage') is not true then
    raise exception 'FAIL: C4 — สิทธิ์จริงในคำถามเดียวกันต้องยังเป็น true';
  end if;

  -- C5 · อาร์เรย์ว่าง / null / ค่าซ้ำ / null ในอาร์เรย์
  if (select count(*) from sri_os.fn_can_many(array[]::text[])) <> 0 then
    raise exception 'FAIL: C5 — อาร์เรย์ว่างต้องคืน 0 แถว';
  end if;
  if (select count(*) from sri_os.fn_can_many(null)) <> 0 then
    raise exception 'FAIL: C5 — null ต้องคืน 0 แถว ไม่ใช่ error';
  end if;
  select count(*) into n from sri_os.fn_can_many(array['ledger.read', 'ledger.read']);
  if n <> 2 then
    raise exception 'FAIL: C5 — ส่งซ้ำ 2 ครั้งต้องได้ 2 แถว (ฝั่งแอป map ตามที่ส่ง) แต่ได้ %', n;
  end if;
  if (select m.allowed from sri_os.fn_can_many(array[null]::text[]) m) is not false then
    raise exception 'FAIL: C5 — null ในอาร์เรย์ต้องได้ false (fail closed)';
  end if;

  reset role;
  raise notice 'ok C4-C5 · สิทธิ์ที่สะกดผิด/ไม่มีจริง = false ไม่ใช่ error (และไม่ลากสิทธิ์จริงลงไปด้วย) · อาร์เรย์ว่าง/null/ค่าซ้ำ/null ในอาร์เรย์ ไม่พัง';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- CM1 · **MUTATION** — ถอดสิทธิ์ออกจากบทบาท แล้วทั้งสองตัวต้องเปลี่ยนพร้อมกัน
-- ============================================================
do $$
declare v_before text; v_after text; v_one text;
begin
  set local role authenticated;
  perform pg_temp.login('mgr');
  v_before := pg_temp.many_true();
  if position('ledger.approve' in v_before) = 0 then
    raise exception 'FAIL: CM1 — fixture ผิด: manager ควรมี ledger.approve อยู่ก่อน';
  end if;
  reset role;

  delete from sri_os.role_permissions
   where role_key = 'manager' and permission_key = 'ledger.approve';

  set local role authenticated;
  perform pg_temp.login('mgr');
  v_after := pg_temp.many_true();
  v_one   := pg_temp.one_true();
  reset role;

  if position('ledger.approve' in v_after) <> 0 then
    raise exception 'FAIL: CM1 — ถอดสิทธิ์ออกจากตารางแล้ว fn_can_many ยังตอบว่าทำได้ → มันไม่ได้อ่านตารางสิทธิ์จริง';
  end if;
  if v_after <> v_one then
    raise exception 'FAIL: CM1 — หลังถอดสิทธิ์ สองฟังก์ชันตอบไม่ตรงกัน (many: % · one: %)', v_after, v_one;
  end if;

  raise notice 'ok CM1 (MUTATION) · ถอด ledger.approve จาก manager → **ทั้งสองฟังก์ชันเปลี่ยนพร้อมกัน** (ก่อน: % · หลัง: %) = สิทธิ์มาจากตาราง ไม่ได้ hard-code',
    v_before, v_after;
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- CM2 · **MUTATION** — แก้ `fn_can` ให้ตอบ true หมด
--       ถ้า `fn_can_many` เป็นสำเนาเกณฑ์ มันจะยังตอบเดิม → เคสนี้จะแดง
--       (นี่คือข้อพิสูจน์ว่า "กฎอยู่ที่เดียว" จริง ไม่ใช่สองที่ที่เผอิญตรงกัน)
-- ============================================================
do $$
declare v text; n_perm int;
begin
  select count(*) into n_perm from sri_os.permissions;

  create or replace function sri_os.fn_can(p_permission text) returns boolean
  language sql stable security definer set search_path = '' as $stub$
    select true;   -- สตับของ mutation เท่านั้น
  $stub$;

  set local role authenticated;
  perform pg_temp.login('staff');   -- staff ปกติมีสิทธิ์น้อยสุด
  select count(*) into n_perm
    from sri_os.fn_can_many((select array_agg(key) from sri_os.permissions)) m
   where m.allowed;
  v := pg_temp.many_true();
  reset role;

  if n_perm <> (select count(*) from sri_os.permissions) then
    raise exception 'FAIL: CM2 — แก้ fn_can ให้ตอบ true หมดแล้ว fn_can_many ยังตอบไม่ครบ (% จาก %) → มันมีเกณฑ์ของตัวเอง = กฎสองที่',
      n_perm, (select count(*) from sri_os.permissions);
  end if;

  raise notice 'ok CM2 (MUTATION) · แก้ `fn_can` ตัวเดียว แล้ว `fn_can_many` เปลี่ยนตามทั้งหมด (% สิทธิ์เป็น true) → ยืนยันว่ามันถาม fn_can จริง ไม่ใช่สำเนาเกณฑ์',
    n_perm;
exception when others then
  reset role; raise;
end $$;

rollback;

-- ============================================================
-- CMb · สภาพหลัง mutation ต้องกลับมาครบ
-- ============================================================
do $$
declare v text;
begin
  select regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'gs'), '--[^\n]*', ' ', 'g')
    into v
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'sri_os' and p.proname = 'fn_can';
  if v is null or v !~ 'role_permissions' or v !~ 'is_active' then
    raise exception 'FAIL: CMb — fn_can ตัวจริงไม่กลับมาหลัง rollback (ยังเป็นสตับที่ตอบ true หมด?)';
  end if;
  if not exists (select 1 from sri_os.role_permissions
                  where role_key = 'manager' and permission_key = 'ledger.approve') then
    raise exception 'FAIL: CMb — สิทธิ์ที่ถอดไปใน CM1 ไม่กลับมาหลัง rollback';
  end if;
  raise notice 'ok CMb · fn_can ตัวจริงและตารางสิทธิ์กลับมาครบหลัง rollback';
end $$;

\echo 'zz_fn_can_many_test: ผ่านทุกข้อ'
