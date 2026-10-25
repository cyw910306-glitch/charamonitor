# Shared by qa/real-*.sh (source it): the built app on a throwaway preferences suite and its own home folder (so
# Application Support files such as Drift.json stay out of the owner's), a helper window app, CGEvent input that only
# ever lands on these two (qainput's QA_ALLOW_PIDS), and cropped screen captures. Only the PIDs started here are stopped.
# Needs: 손쉬운 사용 and 화면 기록 for the terminal (real_preflight says which is missing).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
SHOTS="${SHOTS:-$WORK/shots}"
mkdir -p "$SHOTS" "$WORK/home"
QPID=""; HPID=""; FAILS=0

real_preflight() {
    swiftc -O -o "$WORK/qainput" "$ROOT/qa/real-tools/qainput.swift" || exit 2
    [ "$("$WORK/qainput" trusted)" = yes ] || { echo "FAIL 손쉬운 사용 권한 없음 (CGEvent 를 보낼 수 없어요)"; exit 2; }
    screencapture -x -R0,0,4,4 "$WORK/probe.png" 2>/dev/null && [ -s "$WORK/probe.png" ] || { echo "FAIL 화면 기록 권한 없음"; exit 2; }
}

# real_app <DogMonitor.app> <suite> <plist> [args...]: starts the app on that suite (the plist's keys imported first).
real_app() {
    local app="$1" suite="$2" plist="$3"; shift 3
    SUITE="$suite"
    defaults delete "$suite" >/dev/null 2>&1
    defaults import "$suite" "$plist"
    CFFIXED_USER_HOME="$WORK/home" "$app/Contents/MacOS/DogMonitor" --qa-defaults "$suite" "$@" </dev/null >/dev/null 2>"$WORK/app.log" &
    QPID=$!
    echo "앱 PID $QPID, 로그 $WORK/app.log"
}

# real_helper X Y W H [level] [backdrop X Y W H]: the helper window there (top left origin), at window level `level`
# (default 0, a normal window; 2 keeps the owner's windows from covering it mid-test), with a plain window behind it
# when a backdrop is given; its clicks go to $WORK/helper.log.
real_helper() {
    local app="$WORK/DriftHelper.app"
    if [ ! -d "$app" ]; then
        mkdir -p "$app/Contents/MacOS"
        swiftc -O -o "$app/Contents/MacOS/DriftHelper" "$ROOT/qa/drift-helper/main.swift" || exit 2
        cat > "$app/Contents/Info.plist" <<'PLIST'
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
        codesign --force --sign - "$app" >/dev/null 2>&1
    fi
    : > "$WORK/helper.cmd"
    open -n "$app" --stdout "$WORK/helper.log" --args --frame "$1" "$2" "$3" "$4" --level "${5:-0}" ${6:+--backdrop "$6" "$7" "$8" "$9"} --cmd "$WORK/helper.cmd"
    HPID=""
    for _ in $(seq 1 40); do HPID="$(pgrep -f "$app/Contents/MacOS/DriftHelper" | head -1)"; [ -n "$HPID" ] && break; sleep 0.25; done
    [ -n "$HPID" ] || { echo "FAIL 도우미 창이 뜨지 않음"; exit 1; }
    sleep 1
}

# Input, with the helper put in front first (the owner may have clicked another window over it meanwhile).
q() { echo front >> "$WORK/helper.cmd"; sleep 0.35; QA_ALLOW_PIDS="$QPID $HPID" QA_HOTKEY_TAKEN="$(grep -q '^QA hotkeys on true failed \[\]' "$WORK/app.log" && echo 1)" "$WORK/qainput" "$@"; }
# Window lines of the QA app: id layer x y w h sharing name (sharing 0: a hotspot).
qwin() { "$WORK/qainput" windows "$QPID"; }
shot() { screencapture -x -R"$2" "$SHOTS/$1.png" && echo "shot $SHOTS/$1.png"; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
applog() { cat "$WORK/app.log"; }
helperlog() { cat "$WORK/helper.log" 2>/dev/null; }

real_cleanup() {
    [ -n "$HPID" ] && kill "$HPID" 2>/dev/null
    [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
    for p in ${EXTRA_PIDS:-}; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    [ -n "${SUITE:-}" ] && defaults delete "$SUITE" >/dev/null 2>&1
    for s in ${EXTRA_SUITES:-}; do defaults delete "$s" >/dev/null 2>&1; done
    echo "작업 폴더 $WORK, 스크린샷 $SHOTS"
}
trap real_cleanup EXIT
