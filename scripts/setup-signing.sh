#!/bin/bash
# Creates a self-signed code signing identity in a dedicated keychain, so every build of
# Mailmule has the same signature and macOS keeps the Keychain "Always allow" decision.
set -euo pipefail
NAME="Mailmule Local Signing"
KEYCHAIN="$HOME/Library/Keychains/mailmule-signing.keychain-db"
PASS="mailmule-local"

add_to_search_list() {
  if ! security list-keychains -d user | grep -q "mailmule-signing"; then
    # Keep the existing keychains and append ours; codesign only looks in the search list.
    eval "security list-keychains -d user -s $(security list-keychains -d user | tr '\n' ' ') \"$KEYCHAIN\""
  fi
}

if [ -f "$KEYCHAIN" ]; then
  security unlock-keychain -p "$PASS" "$KEYCHAIN"
  add_to_search_list
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:"$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:"$PASS"

security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
add_to_search_list
echo "Vytvorená podpisová identita: $NAME"
