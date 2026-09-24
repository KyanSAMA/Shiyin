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

# Runs the app on one script; the outer alarm guards against the in-app watchdog never firing. Exit: as documented above.
run() {
  mkdir -p "$2"
  perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 600 \
    build/LocalMusic.app/Contents/MacOS/LocalMusic \
    --selftest "$1" --out "$2" --data-dir "$OUT/data" --fixtures .build/fixtures \
    -ApplePersistenceIgnoreState YES > "$2/app.log" 2>&1
  local code=$?
  [ $code -gt 2 ] && code=2
  [ -f "$2/report.json" ] || code=2
  echo "== $(basename "$1" .json)$([ "$2" = "$OUT" ] || echo " (relaunched)") exit=$code"
  if [ -f "$2/report.json" ]; then
    python3 - "$2/report.json" <<'PY'
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
    echo "no report.json; see $2/app.log"
  fi
  return $code
}

run "$SCRIPT" "$OUT"
CODE=$?
# "relaunch": a second script (path relative to the first) run against the same data directory, e.g. to check what
# survives a restart. Its @out is <out>/relaunch.
RELAUNCH=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("relaunch") or "")' "$SCRIPT")
if [ $CODE -eq 0 ] && [ -n "$RELAUNCH" ]; then
  run "$(dirname "$SCRIPT")/$RELAUNCH" "$OUT/relaunch"
  CODE=$?
fi
exit $CODE
