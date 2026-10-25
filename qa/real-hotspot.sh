#!/usr/bin/env bash
# 데스크톱 친구 on the real window server: one 대롱대롱 친구 over a helper window (qa/real-lib.sh). A click on its drawing
# goes to the friend (its hotspot logs the press, the helper gets nothing), a click on a clear pixel of its box goes on
# to the helper window, a 3 pt wiggle stays a click, a drag past 5 pt grows the hotspot and a put-down rehangs the
# friend there, a throw swings it, and ⌃⌥⇧D (단축키 on) hides and shows the friends.
# Usage: qa/real-hotspot.sh <DogMonitor.app>   (SHOTS=<dir> for the captures)
set -u
APP="${1:?사용법: qa/real-hotspot.sh <DogMonitor.app>}"
source "$(dirname "$0")/real-lib.sh"
real_preflight

python3 - "$WORK/prefs.plist" <<'PY'
import json, plistlib, sys
hang = {"on": True, "count": 1, "onTop": True, "wind": "calm", "sound": False, "pokeOnHover": False, "fromTop": True,
        "slots": [{"charm": "none", "rope": "thread", "x": 0.5, "length": 150, "grip": False}]}
plistlib.dump({"hangingFriends": json.dumps(hang).encode(), "autoUpdate": False, "friendSounds": False, "tourSeen": True,
               "hotkeys.on": True, "social.room": False}, open(sys.argv[1], "wb"))
PY
real_app "$APP" qa.dogmonitor.real.hot "$WORK/prefs.plist"
sleep 4

# The friend's hotspot: the QA app's small window in the floating layer, told apart by its size afterwards (a 단축키
# bubble is another small window in that layer).
HOT="$(qwin | awk '$2 >= 3 && $5 < 400 && $6 < 400' | head -1)"
[ -n "$HOT" ] || { fail "대롱대롱 친구 핫스팟 창이 없음"; qwin; exit 1; }
read -r _ _ HX HY HW HH _ <<< "$HOT"
echo "핫스팟 $HX,$HY ${HW}x$HH"
hot() { qwin | awk -v w="$HW" -v h="$HH" '$5 == w && $6 == h' | head -1; }
# Waits (up to 12 s) until the friend stops swinging; then HX HY, and CX CY a point on its body (its lower middle).
settle() {
    local a b
    a="$(hot)"
    for _ in $(seq 1 40); do sleep 0.3; b="$(hot)"; [ "$a" = "$b" ] && break; a="$b"; done
    read -r _ _ HX HY _ <<< "$b"
    CX=$((HX + HW / 2)); CY=$((HY + HH * 2 / 3))
}
since() { tail -n +$(($1 + 1)) "$WORK/app.log"; }
REGION="$((HX - 260)),$((HY - 60)),$((HW + 520)),$((HH + 260))"
real_helper $((HX - 250)) $((HY - 40)) $((HW + 500)) $((HH + 200)) 2
shot hot-0-start "$REGION"

settle
L0=$(wc -l < "$WORK/app.log"); H0=$(helperlog | wc -l)
q click "$CX" "$CY" || fail "그림 위 클릭을 보낼 수 없음"
sleep 0.5
shot hot-1-click-drawn "$REGION"
if since "$L0" | grep -q "^QA hot down"; then pass "그림 위 클릭은 친구가 받음"; else fail "그림 위 클릭을 친구가 못 받음"; fi
if [ "$(helperlog | wc -l)" -gt "$H0" ]; then fail "그림 위 클릭이 아래 창으로 샘"; else pass "그림 위 클릭은 아래 창에 안 감"; fi

settle
L0=$(wc -l < "$WORK/app.log"); H0=$(helperlog | wc -l)
q click $((HX + 2)) $((HY + 2)) || fail "모서리 클릭을 보낼 수 없음"
sleep 0.5
if helperlog | tail -n +$((H0 + 1)) | grep -q "^click"; then pass "투명 모서리 클릭은 아래 도우미 창이 받음"; else fail "투명 모서리 클릭이 아래 창에 안 감"; fi
if since "$L0" | grep -q "^QA hot down"; then fail "투명 부분 클릭을 핫스팟이 가로챔"; else pass "투명 부분은 핫스팟이 안 받음"; fi

settle
L0=$(wc -l < "$WORK/app.log")
q drag "$CX" "$CY" $((CX + 3)) "$CY" 3 20 100
sleep 0.4
if since "$L0" | grep -q "^QA hot up .* grown false"; then pass "3pt 움직임은 클릭 (핫스팟 안 커짐)"; else fail "3pt 움직임: 핫스팟이 커졌거나 못 받음"; since "$L0" | grep "^QA hot"; fi

settle
OX=$HX
L0=$(wc -l < "$WORK/app.log"); H0=$(helperlog | wc -l)
q drag "$CX" "$CY" $((CX + 150)) $((CY + 30)) 25 16 700
shot hot-2-dragged "$REGION"
if since "$L0" | grep -q "^QA hot up .* grown true"; then pass "5pt 넘는 끌기에 핫스팟이 화면 크기로 커짐"; else fail "끌기 중 핫스팟이 안 커짐"; fi
if [ "$(helperlog | wc -l)" -gt "$H0" ]; then fail "끌기가 아래 창으로 샘"; else pass "끌기 중 아래 창은 클릭을 안 받음"; fi
settle
if [ "$HX" -gt $((OX + 60)) ]; then pass "끌어 놓은(0.7초 멈춤) 자리에 다시 매달림 (x $OX -> $HX)"; else fail "끌어 놓은 뒤 원래 자리로 (x $OX -> $HX)"; fi

q throw "$CX" "$CY" $((CX - 140)) "$CY" 6 8
P1="$(hot | awk '{print $3}')"
sleep 0.25
P2="$(hot | awk '{print $3}')"
shot hot-3-thrown "$REGION"
if [ -n "$P1" ] && [ "$P1" != "$P2" ]; then pass "던지면 놓은 뒤에도 흔들림 (x $P1 -> $P2)"; else fail "던진 뒤 움직임 없음 ($P1 / $P2)"; fi

# 단축키: ⌃⌥⇧D (kVK_ANSI_D = 2) hides the 데스크톱 친구, again shows them.
settle
q key 2 ctrl,alt,shift
sleep 1.2
shot hot-4-hidden "$REGION"
if [ -z "$(hot)" ]; then pass "⌃⌥⇧D 로 친구 숨김"; else fail "⌃⌥⇧D 뒤에도 핫스팟 남음: $(hot)"; fi
q key 2 ctrl,alt,shift
sleep 1.5
shot hot-5-shown "$REGION"
if [ -n "$(hot)" ]; then pass "⌃⌥⇧D 다시 누르면 친구 보임"; else fail "다시 눌러도 친구 안 보임"; fi

grep "^QA hot" "$WORK/app.log" | tail -12
[ "$FAILS" = 0 ] && echo "DONE PASS" || echo "DONE FAIL $FAILS"
exit "$FAILS"
