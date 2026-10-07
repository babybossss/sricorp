#!/usr/bin/env bash
# ============================================================
# SRI OS · เทสต์เคสสอง session ขนาน (เทสต์ psql เดียวทำไม่ได้)
#
# ทำอะไร: ซ้อมการโจมตีของผู้ตรวจรอบสาม — "ลงหัวรายการกับบรรทัดต่าง db transaction"
#   V1  B commit หัวรายการ status='void' 0 บรรทัด ที่ปั่น created_at = now() ของ A
#       → A (ซึ่งจอง xid ไว้ก่อน) ใส่บรรทัด + flip เป็น posted
#       เดิมสำเร็จ: dr = 777,777 ในสมุด
#   V2  เหมือน V1 แต่ B ลงหัวรายการ**พร้อมบรรทัดครบคู่** แล้ว commit (หัวรายการถูกต้อง)
#       → A ยัดบรรทัดเพิ่มทีหลัง = แก้ยอดรายการที่ commit แล้ว
#       เคสนี้คือตัววัดว่ากลไก "ธุรกรรมเดียวกัน" แน่นจริง ไม่ได้แน่นเพราะ 0 บรรทัดถูกบล็อก
#
# ทั้งสองเคสต้องล้ม และสมุดต้องไม่มีตัวเลขของผู้โจมตีเหลืออยู่
#
# ใช้: bash scripts/test-two-session-local.sh [ชื่อ DB]
#   เรียกจาก scripts/test-rls-local.sh (ต้องมี DB ที่ migrate แล้ว)
# ============================================================
set -uo pipefail

DB=${1:-${DB:-srios_test}}
WORK=$(mktemp -d)
chmod 777 "$WORK"   # psql \copy เขียนฝั่ง client ซึ่งรันในฐานะ postgres
trap 'rm -rf "$WORK"' EXIT

if [ "$(id -u)" = "0" ] && id postgres >/dev/null 2>&1; then
  pg() { su postgres -c "psql -q -d $DB $*"; }
else
  pg() { eval "psql -q -d $DB $*"; }
fi

fail=0
note() { echo "   $*"; }
bad()  { echo "   FAIL: $*"; fail=1; }

# ผู้ใช้ management (role ที่ผู้ตรวจใช้) + owner ฝั่งบุคคลเพื่อให้กติกาเอกสารไม่ใช่ตัวบล็อก
MGMT='00000000-0000-0000-0000-00000000f2a2'
pg <<SQL >/dev/null 2>&1
insert into auth.users(id) values ('$MGMT') on conflict do nothing;
insert into sri_os.app_users(id, email, display_name, role, is_active)
values ('$MGMT', 'twosession@test', 'TwoSession MGMT', 'management', true)
on conflict (id) do update set role = 'management', is_active = true;
insert into sri_os.user_owner_access(user_id, owner_id)
select '$MGMT', id from sri_os.owners on conflict do nothing;
SQL

run_case() {
  local tag=$1 txn=$2 plant_lines=$3
  local t0file="$WORK/t0_$tag"

  # ---------- session A: จอง xid ก่อน (นี่คือกลไกที่ทำให้ age(xmin) ผ่าน) ----------
  cat > "$WORK/a_$tag.sql" <<SQL
begin;
set local role authenticated;
set local "test.uid" = '$MGMT';
select pg_current_xact_id();
\\copy (select to_char(now(),'YYYY-MM-DD HH24:MI:SS.US OF')) to '$t0file'
select pg_sleep(6);
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '$txn', c.id, case when c.rn=1 then 777777 else 0 end, case when c.rn=2 then 777777 else 0 end
  from (select id, row_number() over (order by code) rn
          from sri_os.chart_of_accounts where code not like '11%' order by code limit 2) c;
update sri_os.transactions set status='posted' where id='$txn';
commit;
SQL
  pg < "$WORK/a_$tag.sql" > "$WORK/outA_$tag" 2>&1 &
  local apid=$!

  local i
  for i in $(seq 1 40); do [ -s "$t0file" ] && break; sleep 0.5; done
  local T0
  T0=$(cat "$t0file" 2>/dev/null)
  [ -n "$T0" ] || { bad "$tag · อ่าน now() ของ session A ไม่ได้"; kill $apid 2>/dev/null; return; }

  # ---------- session B: ปั่น created_at = now() ของ A แล้ว commit ----------
  {
    echo "begin;"
    echo "set local role authenticated;"
    echo "set local \"test.uid\" = '$MGMT';"
    echo "insert into sri_os.transactions(id,owner_id,txn_type_code,doc_date,attachments,status,created_at)"
    echo "values ('$txn',(select id from sri_os.owners where code='SUTEE'),'inc.other',current_date,array['e.pdf'],'void','$T0'::timestamptz);"
    if [ "$plant_lines" = "yes" ]; then
      echo "insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)"
      echo "select '$txn', c.id, case when c.rn=1 then 100 else 0 end, case when c.rn=2 then 100 else 0 end"
      echo "  from (select id, row_number() over (order by code) rn"
      echo "          from sri_os.chart_of_accounts where code not like '11%' order by code limit 2) c;"
    fi
    echo "commit;"
  } > "$WORK/b_$tag.sql"
  pg < "$WORK/b_$tag.sql" > "$WORK/outB_$tag" 2>&1
  wait $apid

  # ---------- ตรวจผล ----------
  local planted
  planted=$(pg -tAc "\"select coalesce((select 1 from sri_os.transactions where id='$txn'),0)\"" 2>/dev/null | tr -d ' ')
  local st dr n
  st=$(pg -tAc "\"select coalesce((select status::text from sri_os.transactions where id='$txn'),'(ไม่มีแถว)')\"" | tr -d ' ')
  dr=$(pg -tAc "\"select coalesce((select sum(debit) from sri_os.transaction_lines where transaction_id='$txn'),0)\"" | tr -d ' ')
  n=$(pg  -tAc "\"select count(*) from sri_os.transaction_lines where transaction_id='$txn'\"" | tr -d ' ')

  if [ "$st" = "posted" ]; then
    bad "$tag · หัวรายการกลายเป็น posted ข้าม db transaction (dr=$dr)"
  fi
  if [ "$dr" != "0" ] && [ "${dr%.*}" = "777777" ]; then
    bad "$tag · บรรทัดของ session A เข้าไปอยู่ในสมุด (dr=$dr)"
  fi
  if [ "$plant_lines" = "no" ] && [ "$planted" != "0" ]; then
    bad "$tag · หัวรายการ void 0 บรรทัด commit ผ่าน"
  fi
  if [ "$plant_lines" = "yes" ] && [ "$n" != "2" ]; then
    bad "$tag · รายการที่ B ลงถูกต้องเสียรูป (เหลือ $n บรรทัด ต้อง 2)"
  fi
  if ! grep -qi "error" "$WORK/outA_$tag"; then
    bad "$tag · session A ไม่ถูกปฏิเสธ (ไม่มี ERROR ใน output)"
  fi
  note "$tag · status=$st บรรทัด=$n dr=$dr · A: $(grep -im1 error "$WORK/outA_$tag" | cut -c1-110)"
}

echo "== two-session V1 · หัวรายการ void 0 บรรทัด + บรรทัดจากอีกธุรกรรม"
run_case V1 '00000000-0000-0000-0000-00000000f2e1' no

echo "== two-session V2 · หัวรายการที่ commit ถูกต้องแล้ว ถูกยัดบรรทัดเพิ่มจากธุรกรรมที่จอง xid ไว้ก่อน"
run_case V2 '00000000-0000-0000-0000-00000000f2e2' yes

# ---------- ขาบวก: ลงหัวรายการ + บรรทัดในธุรกรรมเดียว (คนละ session) ต้องยังทำได้ ----------
# กันแน่นเกินจนใช้งานจริงไม่ได้ (บทเรียนข้อ 7) — ถ้าเคสนี้ล้ม การ post ปกติตายทั้งระบบ
OKTXN='00000000-0000-0000-0000-00000000f2e9'
pg <<SQL > "$WORK/outOK" 2>&1
\set ON_ERROR_STOP 1
begin;
set local role authenticated;
set local "test.uid" = '$MGMT';
insert into sri_os.transactions(id,owner_id,txn_type_code,doc_date,attachments)
values ('$OKTXN',(select id from sri_os.owners where code='SUTEE'),'inc.other',current_date,array['e.pdf']);
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '$OKTXN', c.id, case when c.rn=1 then 321 else 0 end, case when c.rn=2 then 321 else 0 end
  from (select id, row_number() over (order by code) rn
          from sri_os.chart_of_accounts where code not like '11%' order by code limit 2) c;
commit;
SQL
okdr=$(pg -tAc "\"select coalesce((select sum(debit) from sri_os.transaction_lines where transaction_id='$OKTXN'),0)\"" | tr -d ' ')
if [ "${okdr%.*}" != "321" ]; then
  bad "ขาบวก · post ปกติในฐานะ authenticated ไม่ผ่าน (dr=$okdr) · $(tail -3 "$WORK/outOK")"
else
  note "ok ขาบวก · post ปกติ (หัวรายการ + บรรทัดในธุรกรรมเดียว) ยังทำได้ dr=321"
fi

[ $fail -eq 0 ] && echo "=== two-session: การโจมตีล้มทุกตัว และการ post ปกติยังทำได้ ==="
exit $fail
