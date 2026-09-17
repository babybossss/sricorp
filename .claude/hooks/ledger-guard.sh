#!/usr/bin/env bash
# แตะโค้ดที่เกี่ยวกับเงินเมื่อไร ให้ตรวจทันที ไม่ต้องรอ CI
# อ่าน path ของไฟล์ที่เพิ่งแก้จาก stdin (payload ของ PostToolUse hook)
set -uo pipefail

payload="$(cat)"
file="$(printf '%s' "$payload" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null || true)"

case "$file" in
  *src/lib/rules/*|*lib/ledger/*|*supabase/migrations/*) ;;
  *) exit 0 ;;
esac

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

out="$(npx tsc --noEmit 2>&1)"
if [ -n "$out" ]; then
  echo "ไฟล์ที่แตะเงินมี type error — แก้ก่อนไปต่อ:" >&2
  printf '%s\n' "$out" | head -20 >&2
  exit 2
fi

if [ -f package.json ] && grep -q '"test"' package.json; then
  tout="$(npm test --silent 2>&1)" || {
    echo "test ของ ledger ไม่ผ่าน:" >&2
    printf '%s\n' "$tout" | tail -30 >&2
    exit 2
  }
fi

echo "ledger-guard: typecheck ผ่าน ($file)"
exit 0
