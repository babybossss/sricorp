"""แทรก screenshot เป็น data URI ลงหน้าสรุป — ไม่ผ่าน context จึงไม่กินโทเคน"""
import base64, re, sys, pathlib

SHOTS = pathlib.Path("/tmp/claude-0/-home-user-sricorp/83c9a6c5-463e-50cd-b7bc-9ceb1f8a3287/scratchpad/shots")
src = pathlib.Path("scratch/review-template.html")
out = pathlib.Path("scratch/review.html")

html = src.read_text()
missing = []

def repl(m):
    name = m.group(1)
    f = SHOTS / f"{name}.jpg"
    if not f.exists():
        missing.append(name)
        return ""
    b64 = base64.b64encode(f.read_bytes()).decode()
    return f"data:image/jpeg;base64,{b64}"

html = re.sub(r"\{\{IMG:([a-z0-9-]+)\}\}", repl, html)
out.write_text(html)

if missing:
    print("MISSING:", ", ".join(missing), file=sys.stderr)
    sys.exit(1)

kb = out.stat().st_size / 1024
print(f"wrote {out} · {kb:.0f} KB · {html.count('data:image/jpeg')} ภาพ")
