#!/bin/bash
# Quit TabType, launch dist/TabType.app with verbose logging, and wait for model warm-up.
# Usage: relaunch.sh [marker]   (run from the repo root)
# Prints the launch line for this run. Exits 1 if ax=false or warm-up does not finish in 60 s.
set -u
LOG="$HOME/Library/Logs/TabType/tabtype.log"
MARK="=== ${1:-RUN} $(date '+%Y-%m-%d %H:%M:%S')"
run_log() { sed -n "/^$MARK\$/,\$p" "$LOG"; }

[ -d dist/TabType.app ] || { echo "dist/TabType.app missing; run ./Scripts/build.sh app"; exit 1; }
defaults write app.tabtype.TabType verboseLog -bool true

pkill -x TabType
for _ in $(seq 1 20); do pgrep -x TabType >/dev/null || break; sleep 0.5; done
echo "$MARK" >> "$LOG"
open dist/TabType.app

for _ in $(seq 1 60); do
  run_log | grep -q "model warm-up finished" && break
  sleep 1
done
RUN=$(run_log)
echo "marker: $MARK"
echo "$RUN" | grep -E "TabType launched|warm-up finished|self-test" | cut -c1-200
echo "running from: $(ps -o command= -p "$(pgrep -x TabType | head -1)" 2>/dev/null)"
echo "$RUN" | grep -q "ax=true" || { echo "FAIL: ax is not true (ad-hoc signature or grant missing; relaunch after the user re-grants)"; exit 1; }
echo "$RUN" | grep -q "model warm-up finished" || { echo "FAIL: warm-up not finished after 60 s"; exit 1; }
