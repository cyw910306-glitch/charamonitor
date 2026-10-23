#!/usr/bin/env bash
# Builds the app and writes the download files into web/:
#   JellyMonitor.dmg, JellyMonitor.zip, SHA256SUMS, version.txt, update.json + update.json.sig (signed, for the in-app updater),
#   sponsors.json.sig (the 후원 친구 list, signed the same way)
#   plugins.json.sig (the 플러그인 days and code hashes, signed the same way)
# Usage: [UPDATE_NOTES="한 줄 요약"] scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build.noindex/DogMonitor.app"
WEB="$ROOT/web"

bash "$ROOT/scripts/build_app.sh"
codesign --verify --deep --strict "$APP"
mkdir -p "$WEB"

TMP="$(mktemp -d "${TMPDIR:-/private/tmp}/jellymonitor-pkg.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "==> zip"
rm -f "$WEB/JellyMonitor.zip"
ditto -c -k --keepParent "$APP" "$WEB/JellyMonitor.zip"

echo "==> dmg"
mkdir -p "$TMP/dmg"
ditto "$APP" "$TMP/dmg/DogMonitor.app"
ln -s /Applications "$TMP/dmg/Applications"
rm -f "$WEB/JellyMonitor.dmg"
hdiutil create -quiet -volname "캐릭모니터" -srcfolder "$TMP/dmg" -fs HFS+ -format UDZO -ov "$WEB/JellyMonitor.dmg"

echo "==> 체크섬, 버전"
(cd "$WEB" && shasum -a 256 JellyMonitor.zip JellyMonitor.dmg > SHA256SUMS)
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" > "$WEB/version.txt"

echo "==> 업데이트 안내 (update.json, 서명)"
# The installed apps fetch these daily; the signature uses the release signing key (never printed).
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
NOTES="${UPDATE_NOTES:-이제 앱이 새 버전을 스스로 받아요. 사진 캐릭터 품질도 좋아졌어요.}"
case "$NOTES" in *'"'*|*'\'*) echo "UPDATE_NOTES 에는 따옴표와 역슬래시를 쓸 수 없어요." >&2; exit 1 ;; esac
ZIP_SHA="$(shasum -a 256 "$WEB/JellyMonitor.zip" | awk '{print $1}')"
printf '{"version":"%s","build":%s,"url":"https://jelly-monitor.vercel.app/JellyMonitor.zip","sha256":"%s","minSystem":"%s","notes":"%s"}\n' \
    "$(plist CFBundleShortVersionString)" "$(plist CFBundleVersion)" "$ZIP_SHA" "$(plist LSMinimumSystemVersion)" "$NOTES" > "$WEB/update.json"
swift "$ROOT/tools/update/sign_manifest.swift" "$WEB/update.json"
# The built app checks the files with its own embedded public key (read-only, no network).
"$APP/Contents/MacOS/DogMonitor" --check-update "$WEB"

echo "==> 후원 친구 목록 (sponsors.json, 서명)"
# web/sponsors.json is edited by hand (raise "serial" with every change: apps refuse a lower one). Signed again on every
# release with the same key and tool, then checked by the built app like update.json.
swift "$ROOT/tools/update/sign_manifest.swift" "$WEB/sponsors.json"
"$APP/Contents/MacOS/DogMonitor" --check-sponsors "$WEB"

echo "==> 플러그인 목록 (plugins.json, 서명)"
# web/plugins.json holds each new plugin's day and its Instagram code's hash (tools/update/plugin_code.swift; the codes
# themselves stay in ~/Library/Application Support/JellyMonitorSeller/plugin-codes.json). Raise "serial" with every change.
swift "$ROOT/tools/update/sign_manifest.swift" "$WEB/plugins.json"
"$APP/Contents/MacOS/DogMonitor" --check-plugins "$WEB"

echo "==> 만든 파일 ($WEB)"
(cd "$WEB" && ls -lh JellyMonitor.dmg JellyMonitor.zip SHA256SUMS version.txt update.json update.json.sig sponsors.json sponsors.json.sig plugins.json plugins.json.sig && cat SHA256SUMS version.txt update.json)
