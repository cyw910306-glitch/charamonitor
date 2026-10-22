#!/usr/bin/env bash
# Builds build.noindex/DogMonitor.app (release, universal arm64+x86_64, ad-hoc signed).
# Usage: scripts/build_app.sh [--install] [--open]
#   --install  copy the app to /Applications (or ~/Applications when /Applications is not writable)
#   --open     launch the app afterwards (the installed copy when --install is given)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build.noindex/DogMonitor.app"
INSTALL=0
OPEN=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --open) OPEN=1 ;;
        *) echo "알 수 없는 옵션: $arg (쓸 수 있는 것: --install --open)" >&2; exit 2 ;;
    esac
done

# Universal (Apple Silicon + Intel) so any Mac can run the same download.
ARCHS=(--arch arm64 --arch x86_64)
echo "==> swift build (release, universal)"
swift build -c release "${ARCHS[@]}" --package-path "$ROOT"
BIN="$(swift build -c release "${ARCHS[@]}" --package-path "$ROOT" --show-bin-path)/DogMonitor"
lipo -archs "$BIN"

echo "==> 앱 번들 조립"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DogMonitor"
cp "$ROOT/my-dog/jelly-avatar.jpg" "$APP/Contents/Resources/jelly.jpg"
# 내 ChatGPT attaches this style guide to every drawing (AIDraw/ChatGPTCharacterClient.swift).
cp "$ROOT/Resources/style-ref.png" "$APP/Contents/Resources/style-ref.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.jelly.dogmonitor</string>
    <key>CFBundleName</key><string>DogMonitor</string>
    <key>CFBundleDisplayName</key><string>DogMonitor</string>
    <key>CFBundleExecutable</key><string>DogMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.8.4</string>
    <key>CFBundleVersion</key><string>37</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>ko</string>
    <key>CFBundleLocalizations</key><array><string>ko</string><string>en</string></array>
    <key>LSHasLocalizedDisplayName</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Jelly</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.jelly.dogmonitor.say</string>
            <key>CFBundleURLSchemes</key><array><string>charamonitor</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>CharaMonitor Setup</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>com.jelly.charamonitor.setup</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.jelly.charamonitor.setup</string>
            <key>UTTypeDescription</key><string>CharaMonitor Setup</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>charamonitor</string></array></dict>
        </dict>
    </array>
    <key>NSCalendarsUsageDescription</key><string>AI 비서가 곧 시작하는 일정을 말풍선으로 알려 드리고, 부탁하면 확인을 받은 뒤 'AI 비서' 캘린더에 일정을 추가해요. 설정에서 켠 경우에만 읽고 써요.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>AI 비서가 곧 시작하는 일정을 말풍선으로 알려 드리고, 부탁하면 확인을 받은 뒤 'AI 비서' 캘린더에 일정을 추가해요. 설정에서 켠 경우에만 읽고 써요.</string>
    <key>NSRemindersUsageDescription</key><string>AI 비서가 마감이 다가온 미리 알림을 알려 드리고, 부탁하면 확인을 받은 뒤 'AI 비서' 목록에 미리 알림을 추가해요. 설정에서 켠 경우에만 읽고 써요.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>AI 비서가 마감이 다가온 미리 알림을 알려 드리고, 부탁하면 확인을 받은 뒤 'AI 비서' 목록에 미리 알림을 추가해요. 설정에서 켠 경우에만 읽고 써요.</string>
    <key>NSAppleEventsUsageDescription</key><string>AI 비서가 새 메일의 보낸 사람과 제목을 알려 드리려고 Mail에 물어봐요. 메시지와 Mail 앱으로 비서가 확인받은 문자·메일을 보낼 때 써요. 설정에서 켠 경우에만 써요.</string>
    <key>NSContactsUsageDescription</key><string>AI 비서가 문자를 보낸 사람을 연락처 이름으로 알려 드리고, 메일을 부탁할 때 이름으로 주소를 찾아요. 주소는 메일을 보낼 때 메일 서버로만 가고 AI로 보내지 않아요.</string>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

# Finder, Spotlight and Launchpad show "캐릭모니터" (search "캐릭" finds it); the file stays DogMonitor.app.
# macOS uses the localized name only while Info.plist CFBundleDisplayName equals the file name, so that stays "DogMonitor".
for lang in ko en Base; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    printf '"CFBundleDisplayName" = "캐릭모니터";\n"CFBundleName" = "캐릭모니터";\n' > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done
# English UI (tools/i18n/merge.py): the Korean source text is the key, so Korean needs no table.
if [ -f "$ROOT/Resources/en.lproj/Localizable.strings" ]; then
    cp "$ROOT/Resources/en.lproj/Localizable.strings" "$APP/Contents/Resources/en.lproj/Localizable.strings"
fi

echo "==> 아이콘"
TMP="$(mktemp -d "${TMPDIR:-/private/tmp}/dogmonitor-icon.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
if "$BIN" --render-sprites "$TMP/sprites" >/dev/null 2>&1 && [ -f "$TMP/sprites/icon-1024.png" ]; then
    SET="$TMP/AppIcon.iconset"
    mkdir -p "$SET"
    # Up to 32 px the three characters turn to specks: those slots get Jelly alone.
    pick() { if [ "$1" -le 32 ] && [ -f "$TMP/sprites/icon-small-1024.png" ]; then echo "$TMP/sprites/icon-small-1024.png"; else echo "$TMP/sprites/icon-1024.png"; fi; }
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" "$(pick "$s")" --out "$SET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z "$d" "$d" "$(pick "$d")" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
else
    echo "경고: 아이콘 렌더 실패, 기본 아이콘으로 진행합니다." >&2
fi

# A fixed self-signed identity keeps macOS permissions (전체 디스크 접근) across updates for every user: TCC remembers
# "this bundle id + this certificate", while an ad-hoc signature is a new app on every build.
# Created once on the maintainer's Mac (see docs/SIGNING.md). Without it the build falls back to ad-hoc.
SIGN_ID="CharaMonitor Code Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
    echo "==> 서명 ($SIGN_ID)"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "==> 서명 (ad-hoc: '$SIGN_ID' 인증서가 없어 업데이트마다 권한이 풀려요)" >&2
    codesign --force --deep --sign - "$APP"
fi

FINAL="$APP"
if [ "$INSTALL" = 1 ]; then
    DEST="/Applications"
    [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
    rm -rf "$DEST/DogMonitor.app"
    cp -R "$APP" "$DEST/"
    FINAL="$DEST/DogMonitor.app"
    # An older copy in ~/Applications would show up twice in Spotlight and Launchpad.
    if [ "$DEST" = "/Applications" ] && [ -d "$HOME/Applications/DogMonitor.app" ]; then
        rm -rf "$HOME/Applications/DogMonitor.app"
    fi
    echo "==> 설치: $FINAL"
fi

if [ "$OPEN" = 1 ]; then
    open "$FINAL"
fi

echo "$FINAL"
