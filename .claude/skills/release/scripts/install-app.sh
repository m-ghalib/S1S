#!/bin/bash
# Replace the installed TabType with dist/TabType.app.
# Usage: install-app.sh [--open]   (run from the repo root)
# Quits TabType, moves every installed copy (/Applications, ~/Applications) to the
# Trash, copies dist/TabType.app to /Applications, and checks the version and
# signature of the copy. --open launches it afterwards.
# INSTALL_DIR overrides /Applications (for testing); then ~/Applications is left alone.
set -euo pipefail
SRC="dist/TabType.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/TabType.app"
OLD_COPIES=("$DEST")
[ "$INSTALL_DIR" = /Applications ] && OLD_COPIES+=("$HOME/Applications/TabType.app")
[ -d "$SRC" ] || { echo "$SRC missing; build it first" >&2; exit 1; }
if codesign -dvv "$SRC" 2>&1 | grep -q "Signature=adhoc"; then
  echo "$SRC is ad-hoc signed; installing it would reset the Accessibility grant." >&2; exit 1
fi

if pgrep -x TabType >/dev/null; then
  pkill -x TabType
  for _ in $(seq 1 20); do pgrep -x TabType >/dev/null || break; sleep 0.5; done
  pgrep -x TabType >/dev/null && { echo "TabType did not quit" >&2; exit 1; }
  echo "Quit running TabType."
fi

for OLD in "${OLD_COPIES[@]}"; do
  [ -d "$OLD" ] || continue
  V="$(plutil -extract CFBundleShortVersionString raw "$OLD/Contents/Info.plist" 2>/dev/null || echo '?')"
  trash "$OLD"
  echo "Moved $OLD ($V) to the Trash."
done

ditto "$SRC" "$DEST"
V="$(plutil -extract CFBundleShortVersionString raw "$DEST/Contents/Info.plist")"
B="$(plutil -extract CFBundleVersion raw "$DEST/Contents/Info.plist")"
AUTH="$(codesign -dvv "$DEST" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
codesign --verify --deep --strict "$DEST"
echo "Installed $DEST: version $V (build $B), signed by ${AUTH:-unknown}."

if [ "${1:-}" = "--open" ]; then
  # An open right after a quit can be swallowed by the exiting instance; retry once.
  for _ in 1 2; do
    open "$DEST"
    for _ in $(seq 1 10); do pgrep -x TabType >/dev/null && break; sleep 0.5; done
    pgrep -x TabType >/dev/null && break
  done
  pgrep -x TabType >/dev/null || { echo "TabType did not start" >&2; exit 1; }
  echo "Launched $DEST."
fi
