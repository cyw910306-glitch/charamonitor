#!/usr/bin/env bash
# 딴짓 지킴이's paw on a real app, safely: builds a throwaway helper app (qa/drift-helper, bundle id
# qa.charamonitor.drifthelper), opens it in front, and runs the app's own close path on it
# (DogMonitor --drift-qa-terminate: the protection checks, then NSRunningApplication.terminate). The command refuses any
# bundle id outside qa.charamonitor.*, so no other app is ever touched. Browser tabs are not closed here (their scripts are
# checked as text in DriftTests).
# Usage: qa/drift-e2e.sh <DogMonitor 실행 파일 (.build/debug/DogMonitor 또는 앱 안의 것)>
set -u
BIN="${1:?사용법: qa/drift-e2e.sh <DogMonitor 실행 파일>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
APP="$WORK/DriftHelper.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/DriftHelper" "$ROOT/qa/drift-helper/main.swift" || exit 1
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>qa.charamonitor.drifthelper</string>
<key>CFBundleExecutable</key><string>DriftHelper</string>
<key>CFBundleName</key><string>DriftHelper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
open -n "$APP" --stdout "$WORK/helper.log"
PID=""
for _ in $(seq 1 40); do
    PID="$(pgrep -f "$APP/Contents/MacOS/DriftHelper" | head -1)"   # this run's own temporary path only
    [ -n "$PID" ] && break
    sleep 0.25
done
[ -n "$PID" ] || { echo "FAIL 도우미가 뜨지 않음"; rm -rf "$WORK"; exit 1; }
sleep 1
"$BIN" --drift-qa-terminate qa.charamonitor.drifthelper
STATUS=$?
sleep 0.5
if grep -q quit "$WORK/helper.log" 2>/dev/null; then echo "PASS 정상 종료 요청(terminate)으로 닫힘"; else echo "FAIL 도우미가 정상 종료 요청을 받지 못함"; STATUS=1; fi
if kill -0 "$PID" 2>/dev/null; then echo "FAIL 도우미가 아직 실행 중"; STATUS=1; kill "$PID"; else echo "PASS 도우미 종료됨"; fi
"$BIN" --drift-qa-terminate com.apple.finder >/dev/null 2>&1
[ $? -eq 2 ] && echo "PASS qa.charamonitor.* 밖의 앱은 거부" || { echo "FAIL 다른 앱을 거부하지 않음"; STATUS=1; }
rm -rf "$WORK"
exit $STATUS
