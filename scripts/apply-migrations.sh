#!/usr/bin/env bash
# ============================================================
# SRI OS · apply migration ที่ยังค้าง ขึ้น Supabase ของจริง
#
# ทำไมต้องมีไฟล์นี้: เครื่องมือ MCP `apply_migration` **timeout ~40% ของครั้งที่เรียก**
#   แบบสุ่ม ไม่เกี่ยวกับขนาดไฟล์ (วัดแล้ว — คำสั่ง `drop function` บรรทัดเดียวก็ timeout)
#   ทุกครั้งที่ timeout มันโรลแบ็กสะอาด แต่ 19 ไฟล์ที่ค้างจะใช้เวลาเป็นชั่วโมงและลุ้นทุกไฟล์
#   → ต่อตรงด้วย psql ทีเดียวจบ
#
# ความปลอดภัยของรหัสผ่าน (ข้อนี้ห้ามลดหย่อน):
#   รับ connection string จาก **ตัวแปรสภาพแวดล้อม `SRI_DB_URL` เท่านั้น**
#   ห้ามรับเป็น argument เพราะ argument ไปอยู่ใน `ps` และใน history ของ shell
#   ตั้งค่าที่เมนู environment → Edit (Network secrets หรือ env var)
#   **ห้ามพิมพ์ลงแชทหรือ commit ลงรีโปทุกกรณี**
#   สคริปต์นี้ไม่ echo ค่าตัวแปรนี้ออกที่ไหนเลย
#
# ใช้:
#   bash scripts/apply-migrations.sh              # ดูว่าจะ apply อะไร (ไม่เขียนอะไรเลย)
#   bash scripts/apply-migrations.sh --apply      # apply จริง หยุดทันทีถ้าไฟล์ไหนพัง
#   bash scripts/apply-migrations.sh --apply --only 20261009000000_reverse_integrity.sql
#   bash scripts/apply-migrations.sh --apply --keep-going   # ไม่หยุด (ใช้เมื่อเข้าใจแล้วว่าทำไมพัง)
#
# ทำไม default เป็น dry-run: ไฟล์พวกนี้สร้าง trigger ที่บังคับกฎเงิน
#   ของที่ apply แล้วบางอย่างแก้ไม่ได้ ต้องกู้ด้วย migration ใหม่
#
# ------------------------------------------------------------
# ข้อจำกัดที่ทดสอบแล้วและต้องรู้ก่อนใช้ (09/10)
#
# ทดสอบกับ Postgres ในเครื่องแล้ว (DB เปล่า) → **9 ไฟล์พัง** คือ
#   20260918000003_txn_type_rule_columns · 3 ไฟล์ seed_txn_types ·
#   20261006000003_txn_types_can_accrue · 20261007000002_txn_type_rule_constraints ·
#   20261008000009_storage_policies · 20261008000012 · 20261008000013
#
# ต้นตอ: `20260918000003` เพิ่มคอลัมน์ **พร้อม check constraint** ในไฟล์เดียว
#   แต่แถว seed ที่มีอยู่ตอนนั้นยังละเมิด constraint (ไฟล์ seed ที่มาทีหลังถึงแก้ให้ถูก)
#   → ไฟล์พัง → `gain_coa_code` ไม่เกิด → พังต่อเป็นทอดๆ อีก 8 ไฟล์
#   (`storage_policies` พังเพราะไม่มีสคีมา storage ในเครื่อง — ปกติ ของจริงมี)
#
# **อาการนี้เป็นของการ replay จาก DB เปล่า ไม่ใช่ของ project จริง**
#   `scripts/test-rls-local.sh` จดเรื่องนี้ไว้ที่หัวไฟล์มานานแล้ว
#   ของจริงมีคอลัมน์พวกนั้นอยู่แล้ว (18 ไฟล์แรก apply ไปแล้ว) ลำดับจึงต่างกัน
#
# **ยังยืนยันกับของจริงไม่ได้จากที่นี่** — ต้องมี SRI_DB_URL ก่อน
#   เพราะงั้น default ถึงหยุดที่ไฟล์แรกที่พัง: ให้คนอ่าน error จริงทีละอัน
#   ไม่ใช่ปล่อยให้พังต่อเป็นทอดๆ แล้วเดาว่าเกิดอะไรขึ้น
# ============================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
MIG_DIR="$REPO/supabase/migrations"
APPLY=0
KEEP_GOING=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --keep-going) KEEP_GOING=1 ;;
    # apply ไฟล์เดียว — ใช้ตอนไล่แก้ไฟล์ที่พังทีละอัน
    --only) shift; ONLY=${1:-}; [ -n "$ONLY" ] || { echo "--only ต้องตามด้วยชื่อไฟล์" >&2; exit 2; } ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    *) echo "ไม่รู้จักตัวเลือก: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "${SRI_DB_URL:-}" ]; then
  cat >&2 <<'MSG'
ไม่มี SRI_DB_URL

  ตั้งที่เมนู environment → Edit → Network secrets (หรือเป็น env var ของ environment)
  **ห้ามส่งค่านี้มาในแชท** และห้าม commit ลงรีโป

  หาค่าได้ที่: Supabase dashboard → Project Settings → Database → Connection string (URI)
  ใช้ของ **pooler** พอร์ต 6543 หรือ direct 5432 ก็ได้

ยังตรวจของในเครื่องได้โดยไม่ต้องมีค่านี้:  bash scripts/test-rls-local.sh
MSG
  exit 3
fi

# -v ON_ERROR_STOP=1 → ไฟล์ที่มี error หยุดกลางไฟล์ แล้ว transaction โรลแบ็ก
# --single-transaction → ทั้งไฟล์สำเร็จหรือไม่สำเร็จเลย ไม่มีครึ่งๆ
pg() { psql "$SRI_DB_URL" -v ON_ERROR_STOP=1 -q -t -A "$@"; }

echo "== ต่อฐานข้อมูล"
if ! pg -c 'select 1' >/dev/null 2>&1; then
  echo "   ต่อไม่ได้ · ตรวจว่า SRI_DB_URL ถูกต้องและ IP นี้ผ่าน network restriction ของ Supabase" >&2
  exit 4
fi
echo "   ต่อได้ · server: $(pg -c 'select current_setting($$server_version$$)')"

echo
echo "== สภาพตอนนี้ (นับจาก catalog ของฐานข้อมูลจริง ไม่ใช่เดาจากไฟล์)"
pg -c "select
  (select count(*) from pg_tables  where schemaname='sri_os')                       || ' ตาราง · ' ||
  (select count(*) from pg_policies where schemaname='sri_os')                      || ' policy · ' ||
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='sri_os')                                                      || ' ฟังก์ชัน · ' ||
  (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
     join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='sri_os' and not t.tgisinternal)                               || ' trigger'
" | sed 's/^/   /'

# จำนวนรายการเงินที่มีอยู่ — ตัวเลขนี้ตัดสินว่าความเสี่ยงของการ apply คือเท่าไหร่
TXN=$(pg -c "select count(*) from sri_os.transactions" 2>/dev/null || echo "?")
echo "   รายการเงินในสมุด: $TXN"
if [ "$TXN" != "0" ] && [ "$TXN" != "?" ]; then
  echo
  echo "   ⚠  มีข้อมูลเงินอยู่แล้ว $TXN รายการ — อ่าน header ของแต่ละไฟล์ก่อน apply"
  echo "      (ของที่ apply แล้วบางอย่างแก้ไม่ได้ ต้องกู้ด้วย migration ใหม่)"
fi

# ---------- ตารางบันทึกว่า apply อะไรไปแล้ว ----------
# ใช้ของมาตรฐาน Supabase CLI เพื่อให้ `supabase db push` ในอนาคตเห็นตรงกัน
pg -c "create schema if not exists supabase_migrations;
       create table if not exists supabase_migrations.schema_migrations (version text primary key);" >/dev/null

echo
echo "== เทียบไฟล์ในรีโปกับที่ฐานข้อมูลบันทึกว่า apply แล้ว"
DONE_LIST=$(pg -c "select version from supabase_migrations.schema_migrations order by 1")
echo "   ฐานข้อมูลบันทึกไว้ $(printf '%s' "$DONE_LIST" | grep -c . || true) รายการ"

# ---------- ลำดับ ----------
# **ห้ามเรียงตามชื่อไฟล์ล้วน** — ดูเหตุผลใน supabase/migration-order.txt
# ลำดับนี้คือลำดับเดียวกับที่ scripts/test-rls-local.sh ใช้ทดสอบ
# ถ้าสองที่ใช้ลำดับต่างกัน สิ่งที่เราทดสอบกับสิ่งที่เรา apply จะเป็นคนละอย่าง
ORDER_FILE=${ORDER_FILE:-"$REPO/supabase/migration-order.txt"}
if [ ! -f "$ORDER_FILE" ]; then
  echo "ไม่พบ $ORDER_FILE — ลำดับการ apply ต้องมาจากไฟล์นั้น ไม่ใช่เรียงตามชื่อ" >&2
  exit 5
fi

deferred=()
while read -r n; do
  case "$n" in ''|'#'*) continue ;; esac
  # ไฟล์ที่ list ไว้แต่ไม่มีจริง = ลำดับล้าสมัย (เช่นเปลี่ยนชื่อไฟล์แล้วลืมแก้)
  # **ห้ามข้ามเงียบๆ** เพราะจะมี migration ที่ไม่ถูก apply โดยไม่มีใครเห็น
  if [ ! -f "$MIG_DIR/$n" ]; then
    echo "   ลำดับอ้างไฟล์ที่ไม่มีจริง: $n" >&2
    echo "   แก้ $ORDER_FILE ให้ตรงกับไฟล์ในโฟลเดอร์ก่อน" >&2
    exit 6
  fi
  deferred+=("$n")
done < "$ORDER_FILE"
echo "   ลำดับท้ายสุดจาก migration-order.txt: ${#deferred[@]} ไฟล์"

is_deferred() { local x; for x in "${deferred[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

pending_early=()
pending_late=()
for f in "$MIG_DIR"/*.sql; do
  name=$(basename "$f")
  ver=${name%%_*}
  # เช็คลำดับก่อนเช็คว่า apply แล้ว ไม่งั้นไฟล์ที่เข้าทั้งสองเงื่อนไขจะถูกพิมพ์สองรอบ
  if is_deferred "$name"; then
    :   # เก็บไปเรียงตามลำดับของ migration-order.txt ด้านล่าง
  elif printf '%s\n' "$DONE_LIST" | grep -qx "$ver"; then
    echo "   ข้าม (apply แล้ว)  $name"
  else
    pending_early+=("$f")
  fi
done
# ไฟล์ที่เลื่อนไว้ ต่อท้ายตามลำดับใน migration-order.txt (ไม่ใช่ตามชื่อ)
for n in "${deferred[@]}"; do
  ver=${n%%_*}
  printf '%s\n' "$DONE_LIST" | grep -qx "$ver" && { echo "   ข้าม (apply แล้ว)  $n"; continue; }
  pending_late+=("$MIG_DIR/$n")
done
pending=("${pending_early[@]}" "${pending_late[@]}")

if [ -n "$ONLY" ]; then
  [ -f "$MIG_DIR/$ONLY" ] || { echo "ไม่มีไฟล์ $ONLY ใน supabase/migrations" >&2; exit 7; }
  # --only ข้ามการเช็คว่า apply แล้วหรือยัง โดยตั้งใจ (ไฟล์ทุกไฟล์ออกแบบให้ idempotent)
  pending=("$MIG_DIR/$ONLY")
  echo "   --only: apply เฉพาะ $ONLY"
fi

echo
if [ ${#pending[@]} -eq 0 ]; then
  echo "== ไม่มีไฟล์ค้าง · จบ"
  exit 0
fi

echo "== ค้างอยู่ ${#pending[@]} ไฟล์"
for f in "${pending[@]}"; do echo "   $(basename "$f")"; done

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "== dry-run · ยังไม่เขียนอะไรลงฐานข้อมูล"
  echo "   สั่งจริงด้วย: bash scripts/apply-migrations.sh --apply"
  exit 0
fi

echo
echo "== apply จริง (ไฟล์ละหนึ่ง transaction)"
ok=0
failed=""
for f in "${pending[@]}"; do
  name=$(basename "$f")
  ver=${name%%_*}
  LOG=$(mktemp)
  # --single-transaction ครอบทั้งไฟล์ รวมบรรทัดที่บันทึก version
  # → ถ้าไฟล์พังกลางทาง version จะไม่ถูกบันทึก และ DB กลับสภาพเดิม
  if psql "$SRI_DB_URL" -v ON_ERROR_STOP=1 -q --single-transaction \
       -f "$f" \
       -c "insert into supabase_migrations.schema_migrations(version) values ('$ver')
             on conflict (version) do nothing" >"$LOG" 2>&1; then
    echo "   ok    $name"
    ok=$((ok+1))
  else
    echo "   พัง   $name"
    # พิมพ์ error จริงเสมอ — เคยเดาสาเหตุแล้วผิด 6 รอบ ทั้งที่ error บอกไว้ตั้งแต่แรก
    sed 's/^/         /' "$LOG" | head -20
    failed="$failed $name"
    rm -f "$LOG"
    if [ "$KEEP_GOING" -ne 1 ]; then
      echo
      echo "   หยุดที่ไฟล์นี้ · ไฟล์ถัดไปอาจพึ่งของในไฟล์นี้"
      echo "   อ่าน error ข้างบนก่อน แล้วแก้ที่ต้นเหตุ · ถ้าตั้งใจจะข้ามจริงใช้ --keep-going"
      break
    fi
    continue
  fi
  rm -f "$LOG"
done

echo
echo "== สรุป"
echo "   apply สำเร็จ $ok / ${#pending[@]} ไฟล์"
if [ -n "$failed" ]; then
  echo "   ไม่ผ่าน:$failed"
fi

echo
echo "== สภาพหลัง apply"
pg -c "select
  (select count(*) from pg_tables  where schemaname='sri_os')                       || ' ตาราง · ' ||
  (select count(*) from pg_policies where schemaname='sri_os')                      || ' policy · ' ||
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='sri_os')                                                      || ' ฟังก์ชัน · ' ||
  (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
     join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='sri_os' and not t.tgisinternal)                               || ' trigger'
" | sed 's/^/   /'

# ของที่รู้ว่าค้างอยู่ในฐานข้อมูลจริงและควรหายไป
if pg -c "select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='sri_os' and p.proname='zz_probe'" | grep -q 1; then
  echo
  echo "   พบ sri_os.zz_probe() ค้างอยู่ (ฟังก์ชันที่เคยใช้ทดลองตอน debug)"
  echo "   ลบด้วย: psql \"\$SRI_DB_URL\" -c 'drop function if exists sri_os.zz_probe()'"
fi

[ -z "$failed" ] || exit 1
