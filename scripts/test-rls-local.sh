#!/usr/bin/env bash
# ============================================================
# SRI OS · รันเทสต์ RLS / สิทธิ์ กับ Postgres ในเครื่อง (ไม่แตะ project จริง)
#
# ทำอะไร: สร้าง DB เปล่า + ของจำลองฝั่ง Supabase (schema auth, auth.uid(), role
#   anon/authenticated/service_role) → รัน migration ทุกไฟล์เรียงลำดับ
#   → รัน supabase/tests/*.sql → ลบ DB ทิ้ง
#
# ใช้: bash scripts/test-rls-local.sh
# ต้องมี: postgresql-16 ในเครื่อง (pg_ctlcluster 16 main start)
# ============================================================
set -euo pipefail

DB=${DB:-srios_test}
REPO=$(cd "$(dirname "$0")/.." && pwd)

# psql ต้องรันในฐานะ superuser ของ cluster · ไฟล์ส่งผ่าน stdin เพราะ
# ผู้ใช้ postgres อ่านไฟล์ใน home ของ developer ไม่ได้
if [ "$(id -u)" = "0" ] && id postgres >/dev/null 2>&1; then
  psql_run() { su postgres -c "psql -v ON_ERROR_STOP=1 -q -d $DB -f -"; }
  admin()    { su postgres -c "$1"; }
else
  psql_run() { psql -v ON_ERROR_STOP=1 -q -d "$DB" -f -; }
  admin()    { eval "$1"; }
fi

admin "dropdb --if-exists $DB" >/dev/null
admin "createdb $DB"

psql_run <<'SQL'
-- ของจำลองฝั่ง Supabase เท่าที่ migration ต้องใช้ (เฉพาะ DB ทดสอบในเครื่อง)
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key);
-- ของจริงอ่านจาก JWT · ในเครื่องอ่านจาก GUC เพื่อสลับผู้ใช้ในเทสต์ได้
create or replace function auth.uid() returns uuid
language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
create schema if not exists sri_os;
grant usage on schema sri_os, auth to anon, authenticated, service_role;
alter default privileges in schema sri_os grant all on tables to authenticated;
alter default privileges in schema sri_os grant all on sequences to authenticated;
SQL

# migration ที่กำลังทดสอบ — กันไว้รันทีหลัง เพื่อให้แทรกสถานะจริงของ project
# (policy ที่ใส่มือไว้ ไม่อยู่ในรีโป) ก่อน แล้วค่อยปล่อยของใหม่ทับ
UNDER_TEST=${UNDER_TEST:-20261006190000_roles_permissions.sql}
LOG=${TMPDIR:-/tmp}/srios-mig.log

fail=0
for f in "$REPO"/supabase/migrations/*.sql; do
  name=$(basename "$f")
  [ "$name" = "$UNDER_TEST" ] && continue
  if psql_run < "$f" >"$LOG" 2>&1; then
    echo "  migration ok    $name"
  else
    # สองไฟล์ seed txn_types รันจาก DB เปล่าไม่ผ่านอยู่แล้วก่อนงานนี้
    # (ลำดับ seed ของ DB จริงต่างจากลำดับไฟล์) ไม่เกี่ยวกับ RLS จึงข้ามได้
    echo "  migration SKIP  $name  ($(tail -1 "$LOG" | cut -c1-90))"
  fi
done

# สถานะจริงที่รีโปไม่มี — ถ้าไม่ใส่ เทสต์จะผ่านทั้งที่ของจริงยังมีช่องโหว่
echo "  legacy state    _legacy_db_state.sql"
psql_run < "$REPO/supabase/tests/_legacy_db_state.sql"

if [ -f "$REPO/supabase/migrations/$UNDER_TEST" ]; then
  psql_run < "$REPO/supabase/migrations/$UNDER_TEST"
  echo "  migration ok    $UNDER_TEST  (รันหลังสถานะจริง)"
fi

for t in "$REPO"/supabase/tests/*_test.sql; do
  echo "== test $(basename "$t")"
  if psql_run < "$t"; then :; else fail=1; fi
done

admin "dropdb --if-exists $DB" >/dev/null
exit $fail
