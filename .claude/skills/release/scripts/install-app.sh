#!/bin/bash
# Replace the installed S1S with dist/S1S.app.
# Usage: install-app.sh [--open]   (run from the repo root)
# Quits S1S, moves every installed copy (/Applications, ~/Applications) to the
# Trash, copies dist/S1S.app to /Applications, and checks the version and
# signature of the copy. --open launches it afterwards.
# INSTALL_DIR overrides /Applications (for testing); then ~/Applications is left alone.
set -euo pipefail
SRC="dist/S1S.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/S1S.app"
OLD_COPIES=("$DEST")
[ "$INSTALL_DIR" = /Applications ] && OLD_COPIES+=("$HOME/Applications/S1S.app")
[ -d "$SRC" ] || { echo "$SRC missing; build it first" >&2; exit 1; }
if codesign -dvv "$SRC" 2>&1 | grep -q "Signature=adhoc"; then
  echo "$SRC is ad-hoc signed; installing it would reset the Accessibility grant." >&2; exit 1
fi

if pgrep -x S1S >/dev/null; then
  pkill -x S1S
  for _ in $(seq 1 20); do pgrep -x S1S >/dev/null || break; sleep 0.5; done
  pgrep -x S1S >/dev/null && { echo "S1S did not quit" >&2; exit 1; }
  echo "Quit running S1S."
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
    for _ in $(seq 1 10); do pgrep -x S1S >/dev/null && break; sleep 0.5; done
    pgrep -x S1S >/dev/null && break
  done
  pgrep -x S1S >/dev/null || { echo "S1S did not start" >&2; exit 1; }
  echo "Launched $DEST."
fi
