#!/usr/bin/env bash
# 원격 모임 end to end on one Mac: qa/relay-local.js (web/api/relay.js, in-memory store) and two copies of the built
# app in relay mode (--qa-relay, own throwaway preferences suites) in one room: hello, 오늘 한마디, 퇴근한 척,
# 운세 다시 뽑기, 낙서 쪽지 (shows 5 s) and 🎉; then each sees the other's character in 친구 상주 (hello's look), A types
# for 8 s (입력 중 on the relay's live channel), sends a 200-character 3-line 한마디 (보냄), the same id again and a last
# line, and B sees the dots, the bubble over A's head and the line once. Then A makes a 그룹 뽑기 (B replays the same
# winner, compared here) and throws 5 items at B, whose Mac knocks B out and tells the room: A sees the stars over B's
# seat. Every step prints PASS or FAIL (Social/SocialQA.swift meetSteps).
# Usage: qa/relay-e2e.sh <DogMonitor.app> [timeout seconds, default 240]
# Only the relay and the two copies this script starts are ever stopped; the installed app is not touched.
set -u
APP="${1:?사용법: qa/relay-e2e.sh <DogMonitor.app> [초]}"
LIMIT="${2:-240}"
BIN="$APP/Contents/MacOS/DogMonitor"
[ -x "$BIN" ] || { echo "실행 파일이 없어요: $BIN" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
SA=qa.dogmonitor.meet.a
SB=qa.dogmonitor.meet.b
PR=""; PA=""; PB=""

cleanup() {
    for p in $PA $PB $PR; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    defaults delete "$SA" >/dev/null 2>&1; defaults delete "$SB" >/dev/null 2>&1
}
trap cleanup EXIT

node "$ROOT/qa/relay-local.js" >"$WORK/relay.log" 2>&1 & PR=$!
for _ in $(seq 50); do grep -q '^relay ' "$WORK/relay.log" && break; sleep 0.1; done
PORT="$(sed -n 's/^relay //p' "$WORK/relay.log")"
[ -n "$PORT" ] || { echo "relay 가 안 떴어요"; cat "$WORK/relay.log"; exit 1; }
URL="http://127.0.0.1:$PORT/api/relay"
CODE="QAMEET$(printf %05d%05d $RANDOM $RANDOM)"

for s in "$SA:QA맥A" "$SB:QA맥B"; do
    defaults delete "${s%%:*}" >/dev/null 2>&1
    defaults write "${s%%:*}" social.nickname "${s#*:}"
done
"$BIN" --qa-defaults "$SA" --qa-relay "$URL" --qa-meet "$CODE" --qa-first </dev/null >/dev/null 2>"$WORK/a.log" & PA=$!
"$BIN" --qa-defaults "$SB" --qa-relay "$URL" --qa-meet "$CODE" </dev/null >/dev/null 2>"$WORK/b.log" & PB=$!
echo "relay=$URL A=$PA B=$PB logs: $WORK"

start=$SECONDS
while (( SECONDS - start < LIMIT )); do
    sleep 1
    grep -q "^QA DONE" "$WORK/a.log" && grep -q "^QA DONE" "$WORK/b.log" && break
done
for side in a b; do grep -h "^QA \(PASS\|FAIL\|doodle\)" "$WORK/$side.log" | sed "s/^/[$side] /"; done
echo "relay: $(grep -c '^POST 200' "$WORK/relay.log") POST 200, $(grep -c '^GET 200' "$WORK/relay.log") GET 200, $(grep -Evc ' 200$|^relay ' "$WORK/relay.log") other"
fails=$(cat "$WORK/a.log" "$WORK/b.log" | grep -c "^QA FAIL")
da="$(grep -h '^QA drawn ' "$WORK/a.log" | head -1)"; db="$(grep -h '^QA drawn ' "$WORK/b.log" | head -1)"
if [ -n "$da" ] && [ "$da" = "$db" ]; then echo "[ab] QA PASS 그룹 뽑기 같은 결과 (${da#QA drawn })"; else echo "[ab] QA FAIL 그룹 뽑기 결과 ($da / $db)"; fails=$((fails + 1)); fi
if grep -q "^QA DONE" "$WORK/a.log" && grep -q "^QA DONE" "$WORK/b.log" && (( fails == 0 )); then echo "ALL PASS"; exit 0; fi
grep -q "^QA DONE" "$WORK/a.log" && grep -q "^QA DONE" "$WORK/b.log" || echo "시간 초과 (${LIMIT}s)"
echo "FAIL $fails"; exit 1
