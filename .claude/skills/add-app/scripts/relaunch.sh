#!/bin/bash
# Quit S1S, launch dist/S1S.app with verbose logging, and wait for model warm-up.
# Usage: relaunch.sh [marker]   (run from the repo root)
# Prints the launch line for this run. Exits 1 if ax=false or warm-up does not finish in 60 s.
set -u
LOG="$HOME/Library/Logs/S1S/s1s.log"
MARK="=== ${1:-RUN} $(date '+%Y-%m-%d %H:%M:%S')"
run_log() { sed -n "/^$MARK\$/,\$p" "$LOG"; }

[ -d dist/S1S.app ] || { echo "dist/S1S.app missing; run ./Scripts/build.sh app"; exit 1; }
defaults write app.s1s.S1S verboseLog -bool true

pkill -x S1S
for _ in $(seq 1 20); do pgrep -x S1S >/dev/null || break; sleep 0.5; done
echo "$MARK" >> "$LOG"
open dist/S1S.app

for _ in $(seq 1 60); do
  run_log | grep -q "model warm-up finished" && break
  sleep 1
done
RUN=$(run_log)
echo "marker: $MARK"
echo "$RUN" | grep -E "S1S launched|warm-up finished|self-test" | cut -c1-200
echo "running from: $(ps -o command= -p "$(pgrep -x S1S | head -1)" 2>/dev/null)"
echo "$RUN" | grep -q "ax=true" || { echo "FAIL: ax is not true (ad-hoc signature or grant missing; relaunch after the user re-grants)"; exit 1; }
echo "$RUN" | grep -q "model warm-up finished" || { echo "FAIL: warm-up not finished after 60 s"; exit 1; }
