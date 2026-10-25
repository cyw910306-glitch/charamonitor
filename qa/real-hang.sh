#!/usr/bin/env bash
# 창에 매달기 on the real window server (qa/real-lib.sh): two copies pair over Bonjour + TLS (--qa-pair-only, as
# qa/social-e2e.sh but no other steps), so copy A shows B in 친구 상주 on the right edge. The script drags that friend
# onto the helper window's top edge (it hangs by a rubber band), moves the window (the friend follows), then closes it
# (the friend falls back to its place).
# Usage: qa/real-hang.sh <DogMonitor.app>   (SHOTS=<dir> for the captures)
set -u
APP="${1:?사용법: qa/real-hang.sh <DogMonitor.app>}"
source "$(dirname "$0")/real-lib.sh"
real_preflight
SB=qa.dogmonitor.real.hangb
EXTRA_SUITES="$SB"

prefs() {   # $1 file, $2 nickname, $3 edge
    python3 - "$1" "$2" "$3" <<'PY'
import plistlib, sys
plistlib.dump({"social.nickname": sys.argv[2], "social.room": True, "social.room.hang": True, "social.room.edge": sys.argv[3],
               "autoUpdate": False, "friendSounds": False, "tourSeen": True}, open(sys.argv[1], "wb"))
PY
}
prefs "$WORK/a.plist" QA맥A right
prefs "$WORK/b.plist" QA맥B left
real_app "$APP" qa.dogmonitor.real.hanga "$WORK/a.plist" --qa-host "$WORK/code" --qa-pair-only
defaults delete "$SB" >/dev/null 2>&1; defaults import "$SB" "$WORK/b.plist"
mkdir -p "$WORK/homeb"
CFFIXED_USER_HOME="$WORK/homeb" "$APP/Contents/MacOS/DogMonitor" --qa-defaults "$SB" --qa-join "$WORK/code" --qa-pair-only </dev/null >/dev/null 2>"$WORK/b.log" &
EXTRA_PIDS=$!
echo "B PID $EXTRA_PIDS"
for _ in $(seq 1 160); do grep -q "^QA PASS 페어링" "$WORK/app.log" && break; sleep 1; done
grep -q "^QA PASS 페어링" "$WORK/app.log" && pass "두 사본 페어링" || { fail "페어링 실패"; tail -5 "$WORK/app.log"; exit 1; }

# B's seat on A's screen: A's small never-shared window (its hotspot) on the right edge.
seat() { qwin | awk '$7 == 0 && $5 < 200 && $6 < 200' | sort -k3 -n | tail -1; }
for _ in $(seq 1 20); do [ -n "$(seat)" ] && break; sleep 0.5; done
read -r _ _ SX SY SW SH _ <<< "$(seat)"
[ -n "${SW:-}" ] || { fail "친구 상주 자리 핫스팟이 없음"; qwin; exit 1; }
echo "친구 $SX,$SY ${SW}x$SH"

# The helper: a normal window left of the friend, and a plain one behind both so the drag path stays on the helper.
HW=420; HH=260; HX=$((SX - HW - 180)); HY=$((SY + SH + 220))
BX=$((HX - 40)); BY=$(( (SY < HY - SH ? SY : HY - SH) - 40 )); (( BY < 34 )) && BY=34
real_helper "$HX" "$HY" "$HW" "$HH" 0 "$BX" "$BY" $((SX + SW + 20 - BX)) $((HY + HH + 40 - BY))
REGION="$BX,$BY,$((SX + SW + 20 - BX)),$((HY + HH + 40 - BY))"
echo keep >> "$WORK/helper.cmd"   # in front for the whole test: a window over the friend hides it (by design)
sleep 0.5
shot hang-0-start "$REGION"

# Grab its lower middle, carry it so its feet land just over the window's top edge, hold, let go.
GX=$((SX + SW / 2)); GY=$((SY + SH * 2 / 3))
TX=$((HX + HW / 2)); TY=$((HY - SH / 3 + 4))
q drag "$GX" "$GY" "$TX" "$TY" 30 16 700 || fail "끌기를 보낼 수 없음"
sleep 1.5
shot hang-1-hung "$REGION"
read -r _ _ X1 Y1 _ <<< "$(seat)"
echo "놓은 뒤 친구 $X1,$Y1 (창 윗변 y=$HY)"
if (( X1 < HX + HW && X1 + SW > HX && Y1 + SH >= HY - 30 && Y1 + SH <= HY + 30 )); then pass "창 윗변에 매달림"; else fail "창에 안 매달림 ($X1,$Y1)"; fi

echo "move $((HX - 200)) $((HY + 120))" >> "$WORK/helper.cmd"
sleep 2
shot hang-2-moved "$((BX - 220)),$BY,$((SX + SW + 240 - BX)),$((HY + HH + 200 - BY))"
read -r _ _ X2 Y2 _ <<< "$(seat)"
echo "창 이동 뒤 친구 $X2,$Y2"
if (( X2 < X1 - 120 && Y2 > Y1 + 60 )); then pass "창을 옮기면 따라감 ($X1,$Y1 -> $X2,$Y2)"; else fail "창을 따라가지 않음 ($X1,$Y1 -> $X2,$Y2)"; fi

echo close >> "$WORK/helper.cmd"
sleep 3
read -r _ _ X3 Y3 _ <<< "$(seat)"
shot hang-3-closed "$REGION"
echo "창 닫은 뒤 친구 $X3,$Y3 (처음 자리 $SX,$SY)"
if (( X3 >= SX - 40 && X3 <= SX + 40 )); then pass "창을 닫으면 떨어져 제자리(오른쪽 가장자리)로"; else fail "창을 닫아도 안 떨어짐 ($X3,$Y3)"; fi

[ "$FAILS" = 0 ] && echo "DONE PASS" || echo "DONE FAIL $FAILS"
exit "$FAILS"
