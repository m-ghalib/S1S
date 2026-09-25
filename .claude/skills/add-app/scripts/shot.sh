#!/bin/bash
# Capture a region that INCLUDES the TabType ghost overlay.
# Computer-use screenshots filter the overlay out, so ghost checks must use this.
# Usage:
#   shot.sh <out.png> window <process-name>      # front window of that process
#   shot.sh <out.png> rect <x> <y> <w> <h>       # global screen points
#   shot.sh <out.png> rect "(x, y, w, h)"        # fieldRect tuple pasted from a placement log line
# Output wider than 1400 px is downscaled for Read. Works across displays (-R uses global points).
set -eu
OUT="$1"; MODE="$2"; shift 2
case "$MODE" in
  window)
    read -r X Y W H < <(osascript -e "tell application \"System Events\" to tell process \"$1\" to get {position, size} of front window" | tr -d ',')
    ;;
  rect)
    # Accepts four numbers or a logged tuple such as "(2700.0, 536.0, 586.0, 346.0)".
    read -r X Y W H < <(echo "$*" | tr -d '(),')
    [ -n "${H:-}" ] || { echo "rect needs x y w h"; exit 2; }
    ;;
  *) echo "mode must be window or rect"; exit 2 ;;
esac
X=${X%.*} Y=${Y%.*} W=${W%.*} H=${H%.*}
screencapture -x -R"$X,$Y,$W,$H" "$OUT"
PX=$(sips -g pixelWidth "$OUT" | awk '/pixelWidth/ {print $2}')
[ "$PX" -gt 1400 ] && sips -Z 1400 "$OUT" --out "$OUT" >/dev/null
echo "$OUT (rect $X,$Y ${W}x$H)"
