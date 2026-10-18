#!/usr/bin/env bash
# 캐릭모니터 설치 스크립트
#   설치: curl -fsSL https://jelly-monitor.vercel.app/install.sh | bash
#   삭제: curl -fsSL https://jelly-monitor.vercel.app/install.sh | bash -s -- --uninstall
# 환경 변수: INSTALL_DIR (기본 /Applications, 쓸 수 없으면 ~/Applications), BASE_URL (테스트용)
# Everything runs inside main(), called on the last line, so a cut-off download does nothing.
set -euo pipefail

BASE_URL="${BASE_URL:-https://jelly-monitor.vercel.app}"
BASE_URL="${BASE_URL%/}"
CUSTOM_DIR="${INSTALL_DIR:+1}"
if [ -z "${INSTALL_DIR:-}" ]; then
    # The normal Applications folder, so Spotlight and Launchpad show it like any app.
    if [ -w /Applications ]; then INSTALL_DIR="/Applications"; else INSTALL_DIR="$HOME/Applications"; fi
fi
APP_NAME="DogMonitor.app"
WORK=""

say() { printf '%s\n' "$*"; }
die() { printf '앗, %s\n' "$*" >&2; exit 1; }
cleanup() { if [ -n "$WORK" ]; then rm -rf "$WORK"; fi; }

# Quit only the copy running from this exact install path.
quit_running() {
    local exe="$1/Contents/MacOS/DogMonitor" pid i
    for pid in $(pgrep -f "$exe" || true); do
        [ "$(ps -o comm= -p "$pid" 2>/dev/null || true)" = "$exe" ] || continue
        say "실행 중인 캐릭모니터를 잠시 끌게요."
        kill "$pid" 2>/dev/null || true
        for i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$pid" 2>/dev/null || true
    done
}

# Print every running DogMonitor that is not at the given path.
others_running() {
    local exe="$1/Contents/MacOS/DogMonitor" pid comm
    for pid in $(pgrep -x DogMonitor || true); do
        comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
        [ -n "$comm" ] && [ "$comm" != "$exe" ] && say "${comm%/Contents/MacOS/DogMonitor}"
    done
    return 0
}

uninstall() {
    local app found="" removed="" targets
    if [ -d "$INSTALL_DIR" ]; then INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"; fi
    targets=("$INSTALL_DIR/$APP_NAME")
    # Default run: catch copies in both Applications folders (older versions installed to ~/Applications).
    if [ -z "$CUSTOM_DIR" ]; then
        [ "$INSTALL_DIR" = "/Applications" ] || targets+=("/Applications/$APP_NAME")
        [ "$INSTALL_DIR" = "$HOME/Applications" ] || targets+=("$HOME/Applications/$APP_NAME")
    fi
    for app in "${targets[@]}"; do
        [ -d "$app" ] || continue
        found=1
        quit_running "$app"
        if rm -rf "$app" 2>/dev/null && [ ! -e "$app" ]; then
            removed=1
            say "지웠어요: $app"
        else
            say "지우지 못했어요: $app (Finder에서 휴지통으로 옮겨 주세요)"
        fi
    done
    if [ -z "$found" ]; then
        say "설치된 캐릭모니터를 찾지 못했어요. (찾아본 곳: ${targets[*]})"
        return 0
    fi
    [ -n "$removed" ] || return 0
    # Settings (incl. your dog photo path) are shared by every copy: drop them only when none is left.
    if [ ! -d "$HOME/Applications/$APP_NAME" ] && [ ! -d "/Applications/$APP_NAME" ] && [ ! -d "$INSTALL_DIR/$APP_NAME" ]; then
        defaults delete com.jelly.dogmonitor >/dev/null 2>&1 || true
    fi
    say "캐릭모니터를 삭제했어요. 그동안 고마웠어요!"
    say "로그인 시 자동 실행을 켜 두었다면 시스템 설정 > 일반 > 로그인 항목에서도 지워 주세요."
}

install() {
    local app ver major expected actual stage old others

    [ "$(uname -s)" = "Darwin" ] || die "캐릭모니터는 macOS 전용이에요."
    ver="$(sw_vers -productVersion)"
    major="${ver%%.*}"
    [ "$major" -ge 13 ] 2>/dev/null || die "macOS 13(Ventura) 이상이 필요해요. 지금 버전은 $ver 이에요."

    WORK="$(mktemp -d "${TMPDIR:-/tmp}/jellymonitor.XXXXXX")"
    trap cleanup EXIT

    say "캐릭모니터를 내려받는 중이에요..."
    curl -fsSL --retry 2 "$BASE_URL/JellyMonitor.zip" -o "$WORK/JellyMonitor.zip" \
        || die "내려받기에 실패했어요. 인터넷 연결을 확인하고 다시 시도해 주세요."
    curl -fsSL --retry 2 "$BASE_URL/SHA256SUMS" -o "$WORK/SHA256SUMS" \
        || die "체크섬 파일을 받지 못했어요. 잠시 후 다시 시도해 주세요."

    expected="$(awk '$2 == "JellyMonitor.zip" || $2 == "*JellyMonitor.zip" { print $1 }' "$WORK/SHA256SUMS")"
    actual="$(shasum -a 256 "$WORK/JellyMonitor.zip" | awk '{ print $1 }')"
    [ -n "$expected" ] && [ "$expected" = "$actual" ] \
        || die "파일 검증에 실패했어요(SHA-256 불일치). 설치를 멈출게요."

    ditto -x -k "$WORK/JellyMonitor.zip" "$WORK/unzipped" </dev/null
    [ -d "$WORK/unzipped/$APP_NAME" ] || die "압축 파일 안에 앱이 없어요."
    codesign --verify --deep --strict "$WORK/unzipped/$APP_NAME" 2>/dev/null \
        || die "앱 서명 확인에 실패했어요. 설치를 멈출게요."

    mkdir -p "$INSTALL_DIR"
    INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"   # ps reports resolved paths
    app="$INSTALL_DIR/$APP_NAME"
    # Stage next to the target (same volume) so the final swap is a rename.
    stage="$INSTALL_DIR/.$APP_NAME.new.$$"
    old="$INSTALL_DIR/.$APP_NAME.old.$$"
    rm -rf "$stage" "$old"
    mv "$WORK/unzipped/$APP_NAME" "$stage"
    xattr -dr com.apple.quarantine "$stage" 2>/dev/null || true

    quit_running "$app"
    if [ -e "$app" ]; then mv "$app" "$old"; fi
    mv "$stage" "$app"
    rm -rf "$old"

    # Versions before 1.5 installed to ~/Applications; drop that copy so only one app shows up.
    if [ -z "$CUSTOM_DIR" ] && [ "$INSTALL_DIR" = "/Applications" ] && [ -d "$HOME/Applications/$APP_NAME" ]; then
        quit_running "$HOME/Applications/$APP_NAME"
        rm -rf "$HOME/Applications/$APP_NAME" && say "예전 위치(~/Applications)의 캐릭모니터는 정리했어요."
    fi

    others="$(others_running "$app")"
    open "$app"
    say ""
    say "설치 완료! 캐릭모니터가 $app 에 들어갔어요."
    say "메뉴바에서 달리는 캐릭터를 찾아보세요. 클릭하면 대시보드가 열려요."
    say "종료한 뒤 다시 켜려면 Spotlight(⌘ + Space)에서 '캐릭'을 검색하거나 응용 프로그램 폴더에서 열면 돼요."
    say ""
    if [ -n "$others" ]; then
        say "참고: 다른 곳에 있는 캐릭모니터도 실행 중이에요. 하나만 남기고 메뉴바에서 종료해 주세요."
        say "$others"
        say ""
    fi
    if [ -n "$CUSTOM_DIR" ]; then
        say "삭제 방법: curl -fsSL $BASE_URL/install.sh | INSTALL_DIR='$INSTALL_DIR' bash -s -- --uninstall"
    else
        say "삭제 방법: curl -fsSL $BASE_URL/install.sh | bash -s -- --uninstall"
    fi
}

main() {
    [ "$(id -u)" != 0 ] || die "sudo 없이 실행해 주세요."
    case "${1:-}" in
        "") install ;;
        --uninstall) uninstall ;;
        *) die "모르는 옵션이에요: $1 (쓸 수 있는 것: --uninstall)" ;;
    esac
}

main "$@"
