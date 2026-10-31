#!/bin/zsh
# Luoto — a fork of Atoll (DynamicIsland)
# Copyright (C) 2026 amidamaru940 and Luoto contributors
# Licensed under the GNU General Public License v3.0 or later; see LICENSE.
#
# Screenshots of the whole interface for design review: the closed island,
# every tab of the open island, every page of Settings. Quits the running
# Luoto, starts the given build with -LuotoGallery (GalleryMode.swift),
# captures each step it logs, and leaves that build running.
#
# Usage: scripts/design/gallery.sh [path/to/Luoto.app] [output folder]
#   defaults: /Applications/Luoto.app, build/gallery/<date-time>
# Needs Screen Recording for the terminal app running it. Takes ~1 minute;
# the island opens and Settings appears on screen while it runs.

set -uo pipefail
cd "$(dirname "$0")/../.."
APP="${1:-/Applications/Luoto.app}"
APP="$(cd "$APP" && pwd -P)" || { echo "No app at ${1:-/Applications/Luoto.app}" >&2; exit 1; }
OUT="${2:-build/gallery/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
LOG="$OUT/gallery.jsonl"

pkill -x Luoto; sleep 2
open "$APP" --args -LuotoGallery "$OUT"
echo "Gallery → $OUT"

seen=0
for _ in $(seq 1 900); do                     # 90 s at most
  [[ -f "$LOG" ]] || { sleep 0.1; continue; }
  lines=$(wc -l < "$LOG" | tr -d ' ')
  while (( seen < lines )); do
    seen=$(( seen + 1 ))
    line=$(sed -n "${seen}p" "$LOG")
    step=$(print -r -- "$line" | sed -E 's/.*"step":"([^"]+)".*/\1/')
    [[ "$step" == done ]] && { echo "done: $(find "$OUT" -name "*.png" | wc -l | tr -d ' ') screenshots"; exit 0; }
    rect=$(print -r -- "$line" | python3 -c 'import json,sys; e=json.load(sys.stdin); print("%d,%d,%d,%d" % (e["x"], e["y"], e["w"], e["h"]))')
    if [[ "$rect" == *",0,0" ]]; then echo "  $step: no window"; continue; fi
    screencapture -x -R "$rect" "$OUT/$step.png" && echo "  $step"
  done
  sleep 0.1
done
echo "timed out after 90 s; got $(find "$OUT" -name "*.png" | wc -l | tr -d ' ') screenshots" >&2
exit 1
