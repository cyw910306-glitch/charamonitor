#!/usr/bin/env bash
# Mac App Store build: build.noindex/mas/CharaMonitor.app (release, universal, `-D MAS`, sandboxed) and, with --pkg,
# the signed installer package App Store Connect takes. Steps and the Xcode route: docs/appstore/xcode-archive.md.
# Usage: scripts/build_mas.sh [--debug] [--pkg]
#   --debug  fast arm64 debug build, for sandbox checks on this Mac only (never uploaded)
#   --pkg    also build CharaMonitor.pkg (needs MAS_INSTALLER_IDENTITY)
# Signing (all optional; without them the app is ad-hoc signed and runs only on this Mac):
#   MAS_SIGN_IDENTITY       e.g. "Apple Distribution: 원창연 (TEAMID)" (default "-" = ad-hoc)
#   MAS_TEAM_ID             the 10-character Team ID; adds application-identifier and team-identifier to the entitlements
#   MAS_PROVISION           the Mac App Store provisioning profile, embedded as Contents/embedded.provisionprofile
#   MAS_INSTALLER_IDENTITY  e.g. "3rd Party Mac Developer Installer: 원창연 (TEAMID)"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="$ROOT/build.noindex/mas"
APP="$OUTDIR/CharaMonitor.app"
RES="$ROOT/Resources/MAS"
CONFIG=release
ARCHS=(--arch arm64 --arch x86_64)
PKG=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug; ARCHS=() ;;
        --pkg) PKG=1 ;;
        *) echo "알 수 없는 옵션: $arg (쓸 수 있는 것: --debug --pkg)" >&2; exit 2 ;;
    esac
done
# Words that must never ship in the App Store build (2.3.1 hidden features, 2.4.5, 2.5.2; third-party character
# names and the old Gumroad store, 5.2.1): checked in the binary and every bundle file at the end, and filtered out of
# the English strings. Lowercase "codex" alone stays allowed: BYOAPIClient.notChat uses it to skip OpenAI's code-model
# ids in the ChatGPT model list.
MAS_BANNED='networkQuality|[Gg]umroad|chat\.db|usernoted|osascript|NSAppleScript|Codex|codex[ -](exec|login|cli)|claude -p|claude-cli|gemini-cli|[Hh]itori|히토리|봇치|기타 소녀|기타를 메고|[Gg]uitar [Gg]irl|짱구|태닝 ?키티|치이카와|먼작귀'
IDENTITY="${MAS_SIGN_IDENTITY:--}"
if [ "$PKG" = 1 ] && { [ "$IDENTITY" = "-" ] || [ -z "${MAS_INSTALLER_IDENTITY:-}" ] || [ -z "${MAS_PROVISION:-}" ]; }; then
    echo "--pkg 에는 MAS_SIGN_IDENTITY, MAS_INSTALLER_IDENTITY, MAS_PROVISION 이 모두 필요해요." >&2
    exit 2
fi

# Its own scratch folder, so switching between this and the plain build never rebuilds everything.
FLAGS=(-c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --package-path "$ROOT" --scratch-path "$ROOT/.build/mas" -Xswiftc -DMAS)
echo "==> swift build ($CONFIG, MAS)"
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/DogMonitor"
lipo -archs "$BIN"

echo "==> 앱 번들 조립"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CharaMonitor"
cp "$ROOT/my-dog/jelly-avatar.jpg" "$APP/Contents/Resources/jelly.jpg"
cp "$RES/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
PLIST="$APP/Contents/Info.plist"
cp "$RES/Info.plist" "$PLIST"
# Xcode stamps these into every bundle it builds; App Store validation reads them, so a SwiftPM bundle gets them too.
IFS=. read -r XMAJ XMIN XPATCH <<<"$(xcodebuild -version | awk 'NR==1 {print $2}')"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
stamp() { plutil -replace "$1" -string "$2" "$PLIST"; }
stamp DTXcode "$(printf '%d%d%d' "$XMAJ" "${XMIN:-0}" "${XPATCH:-0}")"
stamp DTXcodeBuild "$(xcodebuild -version | awk 'NR==2 {print $3}')"
stamp DTSDKName "macosx$SDK_VERSION"
stamp DTSDKBuild "$SDK_BUILD"
stamp DTPlatformName macosx
stamp DTPlatformVersion "$SDK_VERSION"
stamp DTPlatformBuild "$SDK_BUILD"
stamp DTCompiler com.apple.compilers.llvm.clang.1_0
stamp BuildMachineOSBuild "$(sw_vers -buildVersion)"
plutil -lint -s "$PLIST"

# Finder and the menu show "캐릭모니터"; macOS uses it only while CFBundleDisplayName equals the file name (CharaMonitor).
for lang in ko en Base; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    printf '"CFBundleDisplayName" = "캐릭모니터";\n"CFBundleName" = "캐릭모니터";\n' > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done
# English permission prompts (Info.plist holds the Korean ones): App Review often runs in English (5.1.1(ii)).
CAL_EN="The AI assistant tells you about events starting soon and, when you ask and confirm, adds events to an 'AI 비서' calendar. Only when turned on in Settings."
REM_EN="The AI assistant tells you about reminders coming due and, when you ask and confirm, adds reminders to an 'AI 비서' list. Only when turned on in Settings."
cat >> "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<EOF
"NSCalendarsUsageDescription" = "$CAL_EN";
"NSCalendarsFullAccessUsageDescription" = "$CAL_EN";
"NSRemindersUsageDescription" = "$REM_EN";
"NSRemindersFullAccessUsageDescription" = "$REM_EN";
"NSContactsUsageDescription" = "When you ask the AI assistant to write to someone, it looks up their address by name. Addresses go only to your mail server when mail is sent, never to the AI.";
"NSLocalNetworkUsageDescription" = "Finds and connects to your friends' Macs on the same Wi-Fi. Only when Nearby Friends is turned on in Settings.";
"NSMicrophoneUsageDescription" = "Sends your voice to a friend only while you hold the walkie-talkie button.";
EOF
plutil -lint -s "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
# English UI (tools/i18n/merge.py): the Korean source text is the key, so Korean needs no table.
if [ -f "$ROOT/Resources/en.lproj/Localizable.strings" ]; then
    # Rows only the direct build uses (CLI engines, Apple Events, the guitar girl's goodbye...) stay out of the App Store bundle.
    grep -vE "$MAS_BANNED" "$ROOT/Resources/en.lproj/Localizable.strings" > "$APP/Contents/Resources/en.lproj/Localizable.strings"
    plutil -lint -s "$APP/Contents/Resources/en.lproj/Localizable.strings"
fi

echo "==> 아이콘"
"$ROOT/scripts/make_icon.sh" "$BIN" "$APP/Contents/Resources/AppIcon.icns" || echo "경고: 아이콘 렌더 실패, 기본 아이콘으로 진행합니다." >&2

ENT="$RES/CharaMonitor.entitlements"
if [ -n "${MAS_TEAM_ID:-}" ]; then
    # A distribution signature must carry the App ID the provisioning profile names.
    ENT="$OUTDIR/CharaMonitor.signing.entitlements"
    cp "$RES/CharaMonitor.entitlements" "$ENT"
    plutil -replace com.apple.application-identifier -string "$MAS_TEAM_ID.com.jelly.charamonitor.mas" "$ENT"
    plutil -replace com.apple.developer.team-identifier -string "$MAS_TEAM_ID" "$ENT"
fi
if [ -n "${MAS_PROVISION:-}" ]; then
    cp "$MAS_PROVISION" "$APP/Contents/embedded.provisionprofile"
fi

echo "==> 서명 ($([ "$IDENTITY" = "-" ] && echo "ad-hoc, 이 맥 전용" || echo "$IDENTITY"))"
codesign --force --sign "$IDENTITY" --entitlements "$ENT" "$APP"
codesign --verify --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'com.apple.security.app-sandbox' || { echo "샌드박스 권한이 서명에 없어요" >&2; exit 1; }

echo "==> 금지어 검사"
if LC_ALL=C grep -rlaE "$MAS_BANNED" "$APP"; then
    echo "위 파일에 앱 스토어판 금지어가 있어요: $MAS_BANNED" >&2
    exit 1
fi

if [ "$PKG" = 1 ]; then
    echo "==> 설치 패키지"
    productbuild --component "$APP" /Applications --sign "$MAS_INSTALLER_IDENTITY" "$OUTDIR/CharaMonitor.pkg"
    echo "$OUTDIR/CharaMonitor.pkg"
fi
echo "$APP"
