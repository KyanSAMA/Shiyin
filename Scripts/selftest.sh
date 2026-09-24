#!/bin/bash
# Run one self-test script against a fresh debug bundle.
# Usage: Scripts/selftest.sh SelfTests/01-shell.json   (SKIP_BUNDLE=1 to reuse build/LocalMusic.app)
# Exit: 0 pass, 1 assertion/script failure, 2 timeout or crash.
set -uo pipefail
SCRIPT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
cd "$(dirname "$0")/.."

NAME=$(basename "$SCRIPT" .json)
OUT=.build/selftest/$NAME

Scripts/make-fixtures.sh || exit 2
[ "${SKIP_BUNDLE:-0}" = 1 ] || Scripts/bundle.sh debug >/dev/null || exit 2
rm -rf "$OUT"
mkdir -p "$OUT"

# Outer guard in case the in-app watchdog never fires.
perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 600 \
  build/LocalMusic.app/Contents/MacOS/LocalMusic \
  --selftest "$SCRIPT" --out "$OUT" --data-dir "$OUT/data" --fixtures .build/fixtures \
  -ApplePersistenceIgnoreState YES > "$OUT/app.log" 2>&1
CODE=$?
[ $CODE -gt 2 ] && CODE=2
[ -f "$OUT/report.json" ] || CODE=2

echo "== $NAME exit=$CODE"
if [ -f "$OUT/report.json" ]; then
  python3 - "$OUT/report.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("status:", r.get("status"), "| duration: %.1fs" % r.get("durationSec", 0))
if r.get("error"): print("error:", r["error"])
snaps = r.get("snapshots", {})
for name, s in sorted(snaps.items()):
    print(f"  {name}: {s.get('file')} {s.get('method')} blank={s.get('isLikelyBlank')} colors={s.get('uniqueColors')}")
rendered = [n for n, s in snaps.items() if s.get("method") == "render"]
if rendered:
    print(f"  WARNING: {len(rendered)} snapshot(s) fell back to in-app render (display asleep/locked or no Screen Recording grant); system materials are missing")
PY
else
  echo "no report.json; see $OUT/app.log"
fi
exit $CODE
