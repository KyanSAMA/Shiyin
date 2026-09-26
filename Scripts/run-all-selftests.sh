#!/bin/bash
# Run every SelfTests/*.json against one fresh bundle, then prove nothing under ~/Music was written and no tag write left
# a temp file behind.
set -uo pipefail
cd "$(dirname "$0")/.."
Scripts/bundle.sh debug >/dev/null || exit 2
STAMP=$(mktemp) || exit 2
failed=0
for script in SelfTests/*.json; do
  SKIP_BUNDLE=1 Scripts/selftest.sh "$script" || failed=1
done
# -cnewer also catches metadata-only writes (xattrs, permissions, restored mtimes).
changed=$(find "$HOME/Music" -path "$HOME/Music/Music" -prune -o -cnewer "$STAMP" -not -name .DS_Store -print) || { echo "!! find failed"; failed=1; }
rm -f "$STAMP"
leftovers=$(find .build/selftest -name '.*.localmusic-tmp-*')
if [ -n "$leftovers" ]; then
  echo "!! tag write temp files left behind:"
  echo "$leftovers" | head -5
  failed=1
fi
if [ -n "$changed" ]; then
  echo "!! ~/Music changed during the self-tests:"
  echo "$changed" | head -5
  failed=1
fi
exit $failed
