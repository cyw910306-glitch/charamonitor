#!/usr/bin/env bash
# Creates the fixed self-signed code signing identity "CharaMonitor Code Signing" in the login keychain (once).
set -euo pipefail
NAME="CharaMonitor Code Signing"
DIR="$HOME/Library/Application Support/JellyMonitorSeller"
mkdir -p "$DIR"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then echo "이미 있어요: $NAME"; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cs.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
O=CharaMonitor
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$DIR/codesign.key" -out "$DIR/codesign.crt" -days 7300 -config "$TMP/cs.cnf" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey "$DIR/codesign.key" -in "$DIR/codesign.crt" -out "$DIR/codesign.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$DIR/codesign.key" -in "$DIR/codesign.crt" -out "$DIR/codesign.p12" -passout "pass:$PASS"
printf '%s' "$PASS" > "$DIR/codesign.p12.pass"
chmod 600 "$DIR/codesign.key" "$DIR/codesign.p12" "$DIR/codesign.p12.pass"
security import "$DIR/codesign.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
security find-identity -p codesigning | grep "$NAME" && echo "완료: 다음 빌드부터 이 인증서로 서명해요."
