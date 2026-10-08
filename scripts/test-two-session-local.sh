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
#   V3  **ขาข้ามผู้ถือเดียวใน session ใหม่ ที่อ้างคู่ซึ่ง commit ไปแล้ว**
#       S1 ลงคู่ครบ (1310 ฝ่ายจ่าย ↔ 2310 ฝ่ายรับ) แล้ว commit → S2 (ธุรกรรมใหม่)
#       ลง 1310 ขาเดียวด้วยวันที่/ลักษณะ/ยอดเดียวกัน เพื่อ "ยืมคู่เก่า" มานับเป็นคู่ของตัวเอง
#       ต้องล้ม · เคสนี้พิสูจน์ในไฟล์เทสต์ไม่ได้ เพราะทั้งไฟล์อยู่ในธุรกรรมเดียว
#       → ทุกขาจะมี write_txn_id เท่ากันหมด แล้วเงื่อนไข "ธุรกรรมเดียวกัน" จะเป็นจริงฟรีๆ
#   V4  **B ปลูก write_txn_id = xid ของ A** แล้ว A ยัดบรรทัดเข้าใบที่ commit แล้ว
#       (V1/V2 ปั่นแต่ created_at จึงไม่เคยแตะคำถามว่าผู้เรียกตั้ง write_txn_id เองได้ไหม)
#
# ทุกเคสต้องล้ม และสมุดต้องไม่มีตัวเลขของผู้โจมตีเหลืออยู่
#
# fixture ของไฟล์นี้ใช้ **คู่บัญชีจริงจากตารางกฎ** (inc.other = Dr 1220 ลูกหนี้อื่น /
#   Cr 4900 รายได้อื่น · ข้ามผู้ถือ = 1310/2310 จาก intercompany.ts)
#   ของเดิมหยิบ "สองรหัสแรกที่ไม่ใช่ 11xx" มาเป็นคู่บัญชี ซึ่งของจริงเป็นไปไม่ได้
#   และทำให้ยกด่านคู่บัญชีขึ้นเป็น trigger ไม่ได้ (20261008000012)
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

# ไม่มีฐานข้อมูล = ยังไม่ได้รันอะไรเลย ไม่ใช่เจอรู
#
# เดิมสคริปต์นี้ตั้งชื่อ DB ไว้คงที่ แต่ harness หลักเปลี่ยนไปใช้ชื่อต่อรอบ
# (`srios_test_$$`) เพื่อให้รันขนานกันได้ · รันเดี่ยวๆ จึงหา DB ไม่เจอ
# แล้วทุกเคสล้มพร้อมกันเป็น "FAIL: กันแน่นเกิน" ซึ่ง **อ่านเหมือนเจอรูจริง**
# ทั้งที่ไม่มีอะไรถูกทดสอบเลย — ผลลวงแบบนั้นแย่กว่าไม่รัน
if ! pg "-c 'select 1'" >/dev/null 2>&1; then
  echo "   ข้ามไม่ได้: ไม่มีฐานข้อมูล '$DB' ที่ migrate แล้ว"
  echo "   สคริปต์นี้ต้องมี DB ที่พร้อมอยู่ก่อน — รันผ่าน harness หลักซึ่งส่งชื่อ DB มาให้:"
  echo "     bash scripts/test-rls-local.sh"
  echo "   หรือระบุ DB ที่มีอยู่แล้วเอง:  bash scripts/test-two-session-local.sh <ชื่อ-db>"
  exit 2
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

# $4 = ข้อความที่ **ต้องเจอ** ใน error ของ session A
#   ที่มา (08/10): ถ้าเช็คแค่ "มี ERROR" เคสนี้ผ่านได้ด้วยด่านอื่น — พิสูจน์แล้วด้วย
#   mutation ที่ถอดการเทียบ write_txn_id ออกจาก fn_assert_line_writable:
#   V2 ยัง "ล้ม" แต่ล้มเพราะ void คือสถานะปลายทาง ไม่ใช่เพราะกฎ "ธุรกรรมเดียวกัน"
#   = เทสต์เขียวทั้งที่กฎที่มันตั้งใจวัดหายไปแล้ว
run_case() {
  local tag=$1 txn=$2 plant_lines=$3 needle=$4
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
  from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('1220', 1), ('4900', 2)) as v(code, rn) on v.code = c2.code) c;
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
      echo "  from (select c2.id, v.rn from sri_os.chart_of_accounts c2"
      echo "          join (values ('1220', 1), ('4900', 2)) as v(code, rn) on v.code = c2.code) c;"
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
  elif ! grep -q "$needle" "$WORK/outA_$tag"; then
    bad "$tag · ปฏิเสธถูกแต่ข้อความไม่ใช่กฎที่เคสนี้วัด (ต้องมี \"$needle\") · ได้: $(grep -im1 error "$WORK/outA_$tag" | cut -c1-140)"
  fi
  note "$tag · status=$st บรรทัด=$n dr=$dr · A: $(grep -im1 error "$WORK/outA_$tag" | cut -c1-110)"
}

echo "== two-session V1 · หัวรายการ void 0 บรรทัด + บรรทัดจากอีกธุรกรรม"
run_case V1 '00000000-0000-0000-0000-00000000f2e1' no 'มีอยู่จริง'

echo "== two-session V2 · หัวรายการที่ commit ถูกต้องแล้ว ถูกยัดบรรทัดเพิ่มจากธุรกรรมที่จอง xid ไว้ก่อน"
run_case V2 '00000000-0000-0000-0000-00000000f2e2' yes 'กฎเหล็กข้อ 1'

# ---------- V3 · ขาข้ามผู้ถือเดียวในธุรกรรมใหม่ ที่อ้างคู่ที่ commit แล้ว ----------
# ต้นเหตุที่ต้องมีเคสนี้: trg_intercompany_pair เทียบ write_txn_id ของขาทั้งสอง
#   ถ้าเอาเงื่อนไขนั้นออก เทสต์ในไฟล์เดียว **ยังเขียวทั้งชุด** เพราะทุกแถวในไฟล์
#   มี write_txn_id เดียวกัน · พิสูจน์ได้ต่อเมื่อขาที่สองอยู่ใน db transaction อื่นจริงๆ
IC_T='00000000-0000-0000-0000-00000000f2c1'   # ขาฝ่ายจ่าย (ธนากร) ของคู่ที่ถูกต้อง
IC_S='00000000-0000-0000-0000-00000000f2c2'   # ขาฝ่ายรับ (สุธี) ของคู่ที่ถูกต้อง
IC_X='00000000-0000-0000-0000-00000000f2c3'   # ขาเดี่ยวที่ยิงจากธุรกรรมใหม่
BANK_T='00000000-0000-0000-0000-00000000f2b1'
BANK_S='00000000-0000-0000-0000-00000000f2b2'

echo "== two-session V3 · ขาข้ามผู้ถือเดียวในธุรกรรมใหม่ อ้างคู่ที่ commit ไปแล้ว"
pg <<SQL > "$WORK/outIC0" 2>&1
insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select '$BANK_T', id, 'BBL', 'ธนากร (two-session)', 'ธนากร - BBL two-session'
  from sri_os.owners where code = 'THANAKORN' on conflict do nothing;
insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select '$BANK_S', id, 'KBANK', 'สุธี (two-session)', 'สุธี - KBANK two-session'
  from sri_os.owners where code = 'SUTEE' on conflict do nothing;
SQL

# S1: คู่ครบในธุรกรรมเดียว → ต้อง commit ผ่าน (ขาบวกของเคสนี้)
pg <<SQL > "$WORK/outIC1" 2>&1
\set ON_ERROR_STOP 1
begin;
set local role authenticated;
set local "test.uid" = '$MGMT';
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, attachments,
                                is_intercompany, counter_owner_id, intercompany_nature)
select '$IC_T', o.id, 'trf.internal', current_date, current_date, array['e.pdf'], true,
       (select id from sri_os.owners where code = 'SUTEE'), 'loan'
  from sri_os.owners o where o.code = 'THANAKORN';
insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
values ('$IC_T', (select id from sri_os.chart_of_accounts where code = '1310'), null, 500, 0),
       ('$IC_T', (select id from sri_os.chart_of_accounts where code = '1100'), '$BANK_T', 0, 500);
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, attachments,
                                is_intercompany, counter_owner_id, intercompany_nature)
select '$IC_S', o.id, 'trf.internal', current_date, current_date, array['e.pdf'], true,
       (select id from sri_os.owners where code = 'THANAKORN'), 'loan'
  from sri_os.owners o where o.code = 'SUTEE';
insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
values ('$IC_S', (select id from sri_os.chart_of_accounts where code = '1100'), '$BANK_S', 500, 0),
       ('$IC_S', (select id from sri_os.chart_of_accounts where code = '2310'), null, 0, 500);
commit;
SQL
icpair=$(pg -tAc "\"select count(*) from sri_os.transactions where id in ('$IC_T','$IC_S')\"" | tr -d ' ')
if [ "$icpair" != "2" ]; then
  bad "V3 · คู่ข้ามผู้ถือที่ถูกต้อง (สองขาในธุรกรรมเดียว) ลงไม่ได้ — กันแน่นเกิน · $(grep -im1 error "$WORK/outIC1" | cut -c1-140)"
else
  note "V3 ขาบวก · คู่ข้ามผู้ถือครบสองขาในธุรกรรมเดียว commit ผ่าน"
fi

# S2: ธุรกรรมใหม่ ลง 1310 ขาเดียว โดยหวังจะจับคู่กับขา 2310 ที่ commit ไว้แล้ว
pg <<SQL > "$WORK/outIC2" 2>&1
begin;
set local role authenticated;
set local "test.uid" = '$MGMT';
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, attachments,
                                is_intercompany, counter_owner_id, intercompany_nature)
select '$IC_X', o.id, 'trf.internal', current_date, current_date, array['e.pdf'], true,
       (select id from sri_os.owners where code = 'SUTEE'), 'loan'
  from sri_os.owners o where o.code = 'THANAKORN';
insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
values ('$IC_X', (select id from sri_os.chart_of_accounts where code = '1310'), null, 500, 0),
       ('$IC_X', (select id from sri_os.chart_of_accounts where code = '1100'), '$BANK_T', 0, 500);
commit;
SQL
iclone=$(pg -tAc "\"select count(*) from sri_os.transactions where id = '$IC_X'\"" | tr -d ' ')
if [ "$iclone" != "0" ]; then
  bad "V3 · ขาข้ามผู้ถือเดียวในธุรกรรมใหม่ commit ผ่าน (อ้างคู่เก่าได้) = 1310 ค้างข้างเดียว งบรวมตัดรายการระหว่างกันไม่ลง"
elif ! grep -qi "error" "$WORK/outIC2"; then
  bad "V3 · ขาเดียวไม่ถูกปฏิเสธ (ไม่มี ERROR ใน output)"
elif ! grep -q "ครบคู่" "$WORK/outIC2"; then
  bad "V3 · ปฏิเสธถูกแต่ข้อความไม่ใช่เรื่องคู่ข้ามผู้ถือ · $(grep -im1 error "$WORK/outIC2" | cut -c1-140)"
else
  note "V3 · ขาเดียวในธุรกรรมใหม่ถูกปฏิเสธ · $(grep -im1 error "$WORK/outIC2" | cut -c1-110)"
fi
# คู่ที่ถูกต้องของ S1 ต้องไม่เสียรูปจากการที่ S2 ล้ม
icdr=$(pg -tAc "\"select coalesce(sum(l.debit),0) from sri_os.transaction_lines l where l.transaction_id in ('$IC_T','$IC_S')\"" | tr -d ' ')
if [ "${icdr%.*}" != "1000" ]; then
  bad "V3 · คู่ที่ commit ถูกต้องเสียรูปหลัง S2 ล้ม (dr=$icdr ต้อง 1000)"
fi

# ---------- V4 · ปลอม write_txn_id ให้เท่ากับ xid ของอีก session ----------
# ที่มา (08/10): กลไก "หัวรายการกับบรรทัดต้องลงในธุรกรรมเดียวกัน" อ่านจาก
#   transactions.write_txn_id · V1/V2 ปั่นแต่ created_at จึง **ไม่เคยแตะ** คำถามว่า
#   ผู้เรียกตั้ง write_txn_id เองได้ไหม · พิสูจน์ด้วย mutation: ถ้า fn_txn_system_columns
#   เปลี่ยนเป็น coalesce(new.write_txn_id, pg_current_xact_id()) ชุดเทสต์ทั้งหมด
#   **ยังเขียว** ทั้งที่ผู้โจมตีที่อ่าน xid ของอีก session ได้ (pg_stat_activity.backend_xid
#   มองเห็นได้เมื่อทุกคนใช้ DB role เดียวกันอย่าง authenticated) จะยัดบรรทัดเข้าใบที่
#   commit แล้วได้ · เคสนี้จึงปลูก write_txn_id ของ A ลงในหัวรายการของ B ตรงๆ
V4TXN='00000000-0000-0000-0000-00000000f2e4'
xidfile="$WORK/xid_V4"
echo "== two-session V4 · B ปลูก write_txn_id = xid ของ A แล้ว A ยัดบรรทัดเข้าใบที่ commit แล้ว"
cat > "$WORK/a_V4.sql" <<SQL
begin;
set local role authenticated;
set local "test.uid" = '$MGMT';
\\copy (select pg_current_xact_id()::text) to '$xidfile'
select pg_sleep(6);
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '$V4TXN', c.id, case when c.rn=1 then 777777 else 0 end, case when c.rn=2 then 777777 else 0 end
  from (select c2.id, v.rn from sri_os.chart_of_accounts c2
          join (values ('1220', 1), ('4900', 2)) as v(code, rn) on v.code = c2.code) c;
commit;
SQL
pg < "$WORK/a_V4.sql" > "$WORK/outA_V4" 2>&1 &
apid4=$!
for i in $(seq 1 40); do [ -s "$xidfile" ] && break; sleep 0.5; done
AXID=$(cat "$xidfile" 2>/dev/null | tr -d ' ')
if [ -z "$AXID" ]; then
  bad "V4 · อ่าน xid ของ session A ไม่ได้"
  kill $apid4 2>/dev/null
else
  # B ลงใบที่ถูกต้อง (สมดุลครบคู่) แต่ตั้ง write_txn_id เป็นของ A
  pg <<SQL > "$WORK/outB_V4" 2>&1
begin;
set local role authenticated;
set local "test.uid" = '$MGMT';
insert into sri_os.transactions(id,owner_id,txn_type_code,doc_date,attachments,write_txn_id)
values ('$V4TXN',(select id from sri_os.owners where code='SUTEE'),'inc.other',current_date,
        array['e.pdf'], '$AXID'::xid8);
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '$V4TXN', c.id, case when c.rn=1 then 100 else 0 end, case when c.rn=2 then 100 else 0 end
  from (select c2.id, v.rn from sri_os.chart_of_accounts c2
          join (values ('1220', 1), ('4900', 2)) as v(code, rn) on v.code = c2.code) c;
commit;
SQL
  wait $apid4
  v4dr=$(pg -tAc "\"select coalesce((select sum(debit) from sri_os.transaction_lines where transaction_id='$V4TXN'),0)\"" | tr -d ' ')
  v4n=$(pg  -tAc "\"select count(*) from sri_os.transaction_lines where transaction_id='$V4TXN'\"" | tr -d ' ')
  if [ "${v4dr%.*}" != "100" ] || [ "$v4n" != "2" ]; then
    bad "V4 · ใบของ B ไม่อยู่ในรูปที่ควรเป็น (dr=$v4dr · $v4n บรรทัด · ต้อง 100 / 2) = การปลูก write_txn_id มีผลต่อสมุด ไม่ว่าจะทางยัดบรรทัดของ A เข้าไป หรือทำให้ใบที่ถูกต้องของ B ลงไม่ได้"
  elif ! grep -q "กฎเหล็กข้อ 1" "$WORK/outA_V4"; then
    bad "V4 · session A ไม่ถูกปฏิเสธด้วยกฎ \"ธุรกรรมเดียวกัน\" · ได้: $(grep -im1 error "$WORK/outA_V4" | cut -c1-140)"
  else
    note "V4 · ปลูก write_txn_id ของอีก session ไม่ได้ (ระบบทับค่าเอง) · A ถูกปฏิเสธ dr ยังเป็น $v4dr"
  fi
fi

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
  from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('1220', 1), ('4900', 2)) as v(code, rn) on v.code = c2.code) c;
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
