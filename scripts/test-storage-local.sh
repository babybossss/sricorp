#!/usr/bin/env bash
# ============================================================
# SRI OS · เทสต์ policy ของ Supabase Storage (bucket attachments) กับ Postgres ในเครื่อง
#
# ทำไมไม่ใช้ scripts/test-rls-local.sh: harness นั้นไม่มีสคีมา storage จึงรัน
#   20261008000009_storage_policies.sql ไม่ได้ (ขึ้น SKIP) · ไฟล์นี้จำลอง storage เท่าที่
#   policy ต้องใช้ แล้วรัน migration ชุดเดียวกัน (ลำดับ UNDER_TEST อ่านจาก harness นั้นตรงๆ
#   ไม่คัดลอก) ตามด้วยเทสต์ใน supabase/tests-storage/
#
# ข้อจำกัดที่ต้องรู้: จำลอง *ตาราง* storage.objects/buckets + storage.foldername() ตามนิยามจริง
#   **ไม่ได้จำลอง Storage API** (การตรวจ mime/ขนาดของ bucket, RETURNING ของ DELETE)
#   ดังนั้นสิ่งที่พิสูจน์ที่นี่คือ "ชั้น DB" เท่านั้น ชั้น API ต้องลองกับ project จริงหลัง apply
#
# ใช้: bash scripts/test-storage-local.sh   (DB=<ชื่อ> เพื่อเก็บ DB ไว้ส่อง)
# ============================================================
set -euo pipefail

DB=${DB:-srios_storage_$$}
REPO=$(cd "$(dirname "$0")/.." && pwd)
HARNESS="$REPO/scripts/test-rls-local.sh"

if [ "$(id -u)" = "0" ] && id postgres >/dev/null 2>&1; then
  psql_run() { su postgres -c "psql -v ON_ERROR_STOP=1 -q -d $DB -f -"; }
  admin()    { su postgres -c "$1"; }
else
  psql_run() { psql -v ON_ERROR_STOP=1 -q -d "$DB" -f -; }
  admin()    { eval "$1"; }
fi
trap 'admin "dropdb --if-exists $DB" >/dev/null 2>&1 || true' EXIT

admin "dropdb --if-exists $DB" >/dev/null
admin "createdb $DB"

# --- bootstrap เดียวกับ harness หลัก (ดึงบล็อก heredoc ออกมาตรงๆ ไม่คัดลอก) ---
awk "/^psql_run <<'SQL'/{f=1;next} /^SQL\$/{f=0} f" "$HARNESS" | psql_run

# --- จำลองสคีมา storage ตามของ Supabase (เฉพาะส่วนที่ policy ใช้) ---
psql_run <<'SQL'
create schema storage;
create table storage.buckets (
  id text primary key, name text not null, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid, owner_id text,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  metadata jsonb,
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
-- นิยามจริงของ Supabase
create or replace function storage.foldername(name text) returns text[]
language plpgsql as $fn$
declare _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts, 1) - 1];
end $fn$;
-- Supabase ให้สิทธิ์ตารางกว้าง แล้วพึ่ง RLS ล้วน → จำลองให้กว้างเท่ากัน (ไม่หลวมกว่า ไม่แน่นกว่า)
grant usage on schema storage to anon, authenticated, service_role;
grant all on storage.objects, storage.buckets to anon, authenticated, service_role;
grant execute on function storage.foldername(text) to anon, authenticated, service_role;
SQL

UNDER_TEST=$(sed -n 's/^UNDER_TEST=\${UNDER_TEST:-"\(.*\)"}$/\1/p' "$HARNESS")
[ -n "$UNDER_TEST" ] || { echo "อ่าน UNDER_TEST จาก harness ไม่ได้"; exit 2; }
in_under_test() { case " $UNDER_TEST " in *" $1 "*) return 0;; *) return 1;; esac; }
LOG=${TMPDIR:-/tmp}/srios-storage-mig.log
MINE=20261008000009_storage_policies.sql
# STORAGE_MIGRATION=<ไฟล์> ใช้ทดลอง mutation (ถอดการแก้ออกแล้วเทสต์ต้องแดง) แทนไฟล์จริง
MIG_FILE=${STORAGE_MIGRATION:-$REPO/supabase/migrations/$MINE}

for f in "$REPO"/supabase/migrations/*.sql; do
  name=$(basename "$f")
  in_under_test "$name" && continue
  [ "$name" = "$MINE" ] && continue
  if psql_run < "$f" >"$LOG" 2>&1; then :; else echo "  migration SKIP  $name (เหมือน harness หลัก)"; fi
done
for name in $UNDER_TEST; do
  [ -f "$REPO/supabase/migrations/$name" ] && psql_run < "$REPO/supabase/migrations/$name" >/dev/null
done
# ของเรา: ต้องผ่านจริง ถ้าล้มให้ดังและหยุด
psql_run < "$MIG_FILE"
psql_run < "$MIG_FILE"   # ซ้ำรอบสอง = ต้อง idempotent
echo "  migration ok    $MINE"

fail=0
for t in "$REPO"/supabase/tests-storage/*_test.sql; do
  echo "== test $(basename "$t")"
  if psql_run < "$t"; then :; else fail=1; fi
done
exit $fail
