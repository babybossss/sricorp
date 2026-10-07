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
-- ของจำลองฝั่ง Supabase: usage บนสคีมา auth เป็นสิ่งที่ Supabase ให้มาเอง
-- ** สิทธิ์ของ sri_os ไม่ตั้งที่นี่ ** — มาจาก supabase/migrations/20261007000001_grants.sql
-- เดิมไฟล์นี้ `grant all on tables` (รวม TRUNCATE) ซึ่ง **หลวมกว่า** project จริง
-- → ผู้ตรวจรายงานว่า authenticated ล้างสมุดด้วย TRUNCATE ได้ ทั้งที่เป็นข้อบกพร่องของ harness
-- แล้วตอนตรวจของจริงพบว่าของจริง **ไม่มี ACL เลย** (แอปอ่าน/เขียน sri_os ไม่ได้)
-- = harness เดาผิดทั้งสองทิศ · แก้ที่ต้นเหตุ: สิทธิ์เป็น migration ทั้งสองฝั่งใช้ไฟล์เดียวกัน
grant usage on schema auth to anon, authenticated, service_role;
SQL

# migration ที่กำลังทดสอบ — กันไว้รันทีหลัง เพื่อให้แทรกสถานะจริงของ project
# (policy ที่ใส่มือไว้ ไม่อยู่ในรีโป) ก่อน แล้วค่อยปล่อยของใหม่ทับ
UNDER_TEST=${UNDER_TEST:-"20261006190000_roles_permissions.sql 20261007000000_line_integrity_and_view_rls.sql 20261007000001_grants.sql 20261007000002_txn_type_rule_constraints.sql"}
in_under_test() { case " $UNDER_TEST " in *" $1 "*) return 0;; *) return 1;; esac; }
LOG=${TMPDIR:-/tmp}/srios-mig.log

fail=0
skipped=""
for f in "$REPO"/supabase/migrations/*.sql; do
  name=$(basename "$f")
  in_under_test "$name" && continue
  if psql_run < "$f" >"$LOG" 2>&1; then
    echo "  migration ok    $name"
  else
    # ไฟล์ที่ replay จาก DB เปล่าไม่ผ่าน (ลำดับ seed ของ DB จริงต่างจากลำดับไฟล์)
    # **ข้ามแบบเงียบๆ ไม่ได้** — schema ที่เทสต์รันอยู่จะไม่เหมือนของจริง
    # → เก็บไว้สรุปเด่นๆ ตอนท้าย (ดูบล็อก "สิ่งที่ harness ข้ามไป")
    echo "  migration SKIP  $name  ($(tail -1 "$LOG" | cut -c1-90))"
    skipped="$skipped$name|$(grep -m1 -i 'ERROR' "$LOG" | cut -c1-120)
"
  fi
done

# สถานะจริงที่รีโปไม่มี — ถ้าไม่ใส่ เทสต์จะผ่านทั้งที่ของจริงยังมีช่องโหว่
echo "  legacy state    _legacy_db_state.sql"
psql_run < "$REPO/supabase/tests/_legacy_db_state.sql"

for name in $UNDER_TEST; do
  [ -f "$REPO/supabase/migrations/$name" ] || continue
  psql_run < "$REPO/supabase/migrations/$name"
  echo "  migration ok    $name  (รันหลังสถานะจริง)"
done

for t in "$REPO"/supabase/tests/*_test.sql; do
  echo "== test $(basename "$t")"
  if psql_run < "$t"; then :; else fail=1; fi
done

# เคสสอง session ขนาน — พิสูจน์ด้วย psql เดียวไม่ได้ (ต้องมีสองธุรกรรมคาบเกี่ยวกันจริง)
echo "== test two-session (ลงหัวรายการกับบรรทัดต่าง db transaction)"
if DB="$DB" bash "$REPO/scripts/test-two-session-local.sh" "$DB"; then :; else fail=1; fi

admin "dropdb --if-exists $DB" >/dev/null

# ---------- สรุปสิ่งที่ harness ข้ามไป (ต้องเด่น ไม่หายไปกลางบรรทัดอื่น) ----------
if [ -n "$skipped" ]; then
  echo
  echo "############################################################"
  echo "# คำเตือน · harness ข้าม migration ไปบางไฟล์"
  echo "# แปลว่า schema ที่เทสต์ชุดนี้รันอยู่ **ไม่เหมือน project จริง**"
  echo "# ผลเทสต์จึงเชื่อได้เท่าที่ส่วนที่ขาดไปไม่เกี่ยวกับสิ่งที่ทดสอบ"
  echo "#"
  printf '%s' "$skipped" | while IFS='|' read -r n e; do
    [ -n "$n" ] || continue
    echo "#   - $n"
    echo "#     $e"
  done
  echo "#"
  echo "# ไฟล์ที่ apply แล้วแก้ไม่ได้ → ถ้าของที่ขาดเป็นกฎที่ต้องมี ให้กู้ด้วย migration ใหม่"
  echo "# (ตัวอย่าง: 20261007000002_txn_type_rule_constraints.sql กู้ constraint ของ"
  echo "#  20260918000003 ที่หายเพราะ add constraint ล้มตอน replay จาก DB เปล่า)"
  echo "############################################################"
fi

exit $fail
