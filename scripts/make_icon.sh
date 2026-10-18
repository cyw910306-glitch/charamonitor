#!/usr/bin/env bash
# Renders AppIcon.icns from a built DogMonitor binary (its --render-sprites icons), the same way build_app.sh does.
# Usage: scripts/make_icon.sh <binary> <out.icns>     (used by build_mas.sh and project.yml)
set -euo pipefail
BIN="$1"; OUT="$2"
TMP="$(mktemp -d "${TMPDIR:-/private/tmp}/charamonitor-icon.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
"$BIN" --render-sprites "$TMP/sprites" >/dev/null 2>&1 && [ -f "$TMP/sprites/icon-1024.png" ] || { echo "아이콘 렌더 실패" >&2; exit 1; }
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
# Up to 32 px the three characters turn to specks: those slots get Jelly alone.
pick() { if [ "$1" -le 32 ] && [ -f "$TMP/sprites/icon-small-1024.png" ]; then echo "$TMP/sprites/icon-small-1024.png"; else echo "$TMP/sprites/icon-1024.png"; fi; }
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$(pick "$s")" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$(pick "$d")" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$OUT"
