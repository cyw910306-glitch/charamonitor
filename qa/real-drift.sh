#!/usr/bin/env bash
# 딴짓 지킴이's cat on the real window server (qa/real-lib.sh): the helper app is on the 딴짓 list and in front, blocks
# are 10 s (--qa-drift-block) with one drift block needed, and 발로 닫기 is on. Run 1: the cat runs to the helper window
# and lifts its paw; a click on the cat keeps the app (the "아직 딴짓 중이에요?" card). Run 2: nobody clicks; the paw comes
# down and the helper app alone is asked to quit (NSRunningApplication.terminate: the helper prints "quit").
# Usage: qa/real-drift.sh <DogMonitor.app>   (SHOTS=<dir> for the captures)
set -u
APP="${1:?사용법: qa/real-drift.sh <DogMonitor.app>}"
source "$(dirname "$0")/real-lib.sh"
real_preflight
HX=520; HY=330; HW=440; HH=260
REGION="$((HX - 140)),$((HY - 170)),$((HW + 280)),$((HH + 230))"

prefs() {   # $1 = 잡을 시간 (seconds)
    python3 - "$WORK/prefs.plist" "$1" <<'PY'
import json, plistlib, sys
lists = {"focus": [], "drift": ["qa.charamonitor.drifthelper"], "corrections": []}
# 근무 시간 all day, every day (off would mean "only with a 집중 타이머").
hours = {"start": 0, "end": 0, "weekdaysOnly": False}
plistlib.dump({"drift.on": True, "drift.hoursOn": True, "drift.hours": json.dumps(hours).encode(), "drift.needed": 1, "drift.cat": True, "drift.paw": True,
               "drift.catPlays": False, "drift.pawSeconds": float(sys.argv[2]), "drift.lists": json.dumps(lists).encode(),
               "autoUpdate": False, "friendSounds": False, "tourSeen": True}, open(sys.argv[1], "wb"))
PY
}

# Waits up to $2 s for an app log line matching $1, keeping the helper in front (its look is what is judged).
wait_log() {
    local t=0
    while (( t < $2 * 2 )); do
        grep -q "$1" "$WORK/app.log" && return 0
        (( t % 2 == 0 )) && echo front >> "$WORK/helper.cmd"   # the paw only closes the app in front
        sleep 0.5; t=$((t + 1))
    done
    return 1
}
# The cat's hotspot: a small never-shared window (the card is one too, but wider than 200).
cat_hot() { qwin | awk '$7 == 0 && $5 < 200 && $6 < 200' | head -1; }

start_run() {   # $1 = suite, $2 = paw seconds
    prefs "$2"
    : > "$WORK/helper.log"
    real_app "$APP" "$1" "$WORK/prefs.plist" --qa-drift-block 10
    sleep 2
    real_helper "$HX" "$HY" "$HW" "$HH" 0 $((HX - 120)) $((HY - 150)) $((HW + 240)) $((HH + 200))
}
stop_run() {
    kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""
    [ -n "$HPID" ] && kill -0 "$HPID" 2>/dev/null && kill "$HPID"
    HPID=""
    defaults delete "$SUITE" >/dev/null 2>&1
}

echo "== 1: 고양이를 잡으면 앱은 그대로"
# The paw comes only for the app in front when drift is confirmed; someone switching apps right then gets the card
# alone (by design). Up to 3 tries.
for try in 1 2 3; do
    start_run qa.dogmonitor.real.drift1 6
    wait_log "^QA drift card nudge" 60
    sleep 0.5
    grep -q "^QA drift pawUp true" "$WORK/app.log" && break
    echo "시도 $try: 카드만 뜨고 발은 없음 (그때 맨 앞 앱이 도우미가 아니었음), 다시"
    stop_run
done
if grep -q "^QA drift pawUp true" "$WORK/app.log"; then pass "딴짓 확정, 고양이 출동 (발로 닫기)"; else fail "딴짓 확정 후 고양이가 안 옴"; grep "^QA drift" "$WORK/app.log"; fi
grep -q "^QA drift card nudge" "$WORK/app.log" && pass "딴짓 카드가 뜸" || fail "딴짓 카드 없음"
sleep 1.2   # the run in
shot drift-1-paw-up "$REGION"
read -r _ _ CX0 CY0 CW CH _ <<< "$(cat_hot)"
if [ -n "${CW:-}" ]; then
    echo "고양이 $CX0,$CY0 ${CW}x$CH, 도우미 창 윗변 y=$HY"
    if (( CX0 + CW > HX && CX0 < HX + HW && CY0 + CH >= HY - 10 && CY0 <= HY + 20 )); then pass "고양이가 도우미 창 윗변으로 옴"; else fail "고양이가 도우미 창에 안 옴"; fi
    q click $((CX0 + CW / 2)) $((CY0 + CH * 2 / 3))
    sleep 1
    shot drift-2-caught "$REGION"
    if grep -q "^QA drift card still" "$WORK/app.log"; then pass "고양이 클릭: 취소 카드(아직 딴짓 중이에요?)"; else fail "고양이 클릭이 안 먹힘"; fi
    sleep 7   # past the 6 s paw
    if kill -0 "$HPID" 2>/dev/null && ! grep -q quit "$WORK/helper.log"; then pass "잡은 뒤 도우미 앱은 그대로"; else fail "잡았는데도 도우미 앱이 닫힘"; fi
else
    fail "고양이 핫스팟 창을 못 찾음"; qwin
fi
grep "^QA drift" "$WORK/app.log"
stop_run

echo "== 2: 안 잡으면 도우미 앱만 정상 종료"
start_run qa.dogmonitor.real.drift2 2
if wait_log "^QA drift pawUp true" 60; then pass "딴짓 확정, 고양이 출동"; else fail "60초 안에 딴짓 확정이 안 됨"; fi
sleep 1.5
shot drift-3-paw-up "$REGION"
if wait_log "^QA drift card closed" 10; then pass "발이 내려옴: 닫힘 카드"; else fail "닫힘 카드 없음"; grep "^QA drift" "$WORK/app.log"; fi
sleep 0.5
shot drift-4-closed "$REGION"
grep -q quit "$WORK/helper.log" && pass "도우미가 정상 종료 요청(terminate)을 받음" || fail "도우미가 종료 요청을 못 받음"
sleep 0.5
if kill -0 "$HPID" 2>/dev/null; then fail "도우미가 아직 실행 중"; else pass "도우미 앱 종료됨"; HPID=""; fi
kill -0 "$QPID" 2>/dev/null && pass "캐릭모니터(QA)는 그대로 실행 중" || fail "QA 앱이 같이 꺼짐"
grep "^QA drift" "$WORK/app.log"
stop_run

[ "$FAILS" = 0 ] && echo "DONE PASS" || echo "DONE FAIL $FAILS"
exit "$FAILS"
