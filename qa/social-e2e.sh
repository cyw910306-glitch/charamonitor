#!/usr/bin/env bash
# 근처 친구 end to end on one Mac: two copies of the built app, each on its own throwaway preferences suite, pair over
# the real Bonjour + TLS path and go through chat, status, 가상 오피스, 친구 상주, 다같이 이모트 (뽀뽀, 똥, 던지기 and the
# receiver's 3 in 10 s limit), 모임 정원, 오늘 한마디, 퇴근한 척, 운세·점심 공유,
# 프로필 카드, 낙서 쪽지 (both ways, gone after 5 s), 무전기 (a tone instead of the mic), 원격 지원
# (answers only, Screen Sharing never opens), 던지기 놀이 (5 hits knock the host out, the joiner sees the stars), 그룹 뽑기
# (the same winner on both), 사진 메시지 (a photo over the link), 의자 (the joiner sits, the host sees it), 같이 뛰기,
# 별 대결, 5 s of silence (this script freezes one copy) and a friend going offline (this script ends one copy).
# Every step prints PASS or FAIL (Social/SocialQA.swift).
# Usage: qa/social-e2e.sh <DogMonitor.app> [timeout seconds, default 420]
#   SHOTS=<dir>  where the screen captures go (default: a temporary folder, printed at the end)
# Only the two copies this script starts are ever stopped; the installed app is not touched.
set -u
APP="${1:?사용법: qa/social-e2e.sh <DogMonitor.app> [초]}"
LIMIT="${2:-420}"
BIN="$APP/Contents/MacOS/DogMonitor"
[ -x "$BIN" ] || { echo "실행 파일이 없어요: $BIN" >&2; exit 2; }
WORK="$(mktemp -d)"
SHOTS="${SHOTS:-$WORK/shots}"
mkdir -p "$SHOTS"
SA=qa.dogmonitor.e2e.a
SB=qa.dogmonitor.e2e.b
PA=""; PB=""

cleanup() {
    for p in $PA $PB; do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    defaults delete "$SA" >/dev/null 2>&1; defaults delete "$SB" >/dev/null 2>&1
}
trap cleanup EXIT

for s in "$SA:QA맥A" "$SB:QA맥B"; do
    defaults delete "${s%%:*}" >/dev/null 2>&1
    defaults write "${s%%:*}" social.nickname "${s#*:}"
done

"$BIN" --qa-defaults "$SA" --qa-host "$WORK/code" </dev/null >/dev/null 2>"$WORK/a.log" & PA=$!
"$BIN" --qa-defaults "$SB" --qa-join "$WORK/code" </dev/null >/dev/null 2>"$WORK/b.log" & PB=$!
echo "A=$PA B=$PB logs: $WORK"

shown=""; froze=0; ended=0; start=$SECONDS
while (( SECONDS - start < LIMIT )); do
    sleep 0.5
    for side in a b; do
        grep -h "^QA \(PASS\|FAIL\)" "$WORK/$side.log" | sed "s/^/[$side] /" | while read -r l; do
            grep -qxF "$l" "$WORK/seen" 2>/dev/null || { echo "$l"; echo "$l" >> "$WORK/seen"; }
        done
        for name in $(sed -n 's/^QA shot //p' "$WORK/$side.log"); do
            case " $shown " in *" $name "*) ;; *) shown="$shown $name"; sleep 1; screencapture -x "$SHOTS/$name.png" && echo "shot $SHOTS/$name.png" ;; esac
        done
    done
    if (( !froze )) && grep -q "^QA ready silence" "$WORK/b.log"; then
        froze=1; sleep 1; echo "B 8초 정지 (SIGSTOP)"; kill -STOP "$PB"; sleep 8; kill -CONT "$PB"
    fi
    if (( !ended )) && grep -q "^QA ready offline" "$WORK/b.log"; then
        ended=1; sleep 1; echo "B 종료 (친구 오프라인)"; kill "$PB"
    fi
    grep -q "^QA DONE" "$WORK/a.log" && break
done

a="$(grep -h '^QA check ' "$WORK/a.log" | head -1)"; b="$(grep -h '^QA check ' "$WORK/b.log" | head -1)"
if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "[ab] QA PASS 확인 숫자 일치 (${a#QA check })"; else echo "[ab] QA FAIL 확인 숫자 ($a / $b)"; fi
sa="$(grep -h '^QA stars ' "$WORK/a.log" | head -1)"; sb="$(grep -h '^QA stars ' "$WORK/b.log" | head -1)"
if [ -n "$sa" ] && [ "$sa" = "$sb" ]; then echo "[ab] QA PASS 별 대결 같은 seed 같은 별 (${sa#QA stars })"; else echo "[ab] QA FAIL 별 배치 ($sa / $sb)"; fi
grep -h "^QA \(voice\|silence\|offline\|remote\)" "$WORK/a.log" "$WORK/b.log"
echo "screens: $SHOTS"
fails=$(cat "$WORK/seen" 2>/dev/null | grep -c "QA FAIL")
[ "$a" = "$b" ] && [ -n "$a" ] && [ "$sa" = "$sb" ] && [ -n "$sa" ] || fails=$((fails + 1))
if grep -q "^QA DONE" "$WORK/a.log" && (( fails == 0 )); then echo "ALL PASS"; exit 0; fi
grep -q "^QA DONE" "$WORK/a.log" || echo "시간 초과 (${LIMIT}s)"
echo "FAIL $fails"; exit 1
