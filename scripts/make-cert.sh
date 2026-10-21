#!/bin/bash
# Creates a self-signed code-signing certificate called "Keylog Dev" in your login
# keychain. It never leaves your Mac and needs no Apple account. Signing every build
# with it lets macOS remember Keylog's Input Monitoring permission across rebuilds.
set -euo pipefail

NAME="${KEYLOG_SIGN_ID:-Keylog Dev}"
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
if grep -qF "\"$NAME\"" <<<"$IDENTITIES"; then
  echo "\"$NAME\" already exists."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

# /usr/bin/openssl is LibreSSL, whose .p12 format the keychain can import.
if ! /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>"$WORK/openssl.log"; then
  cat "$WORK/openssl.log" >&2
  exit 1
fi
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout pass:keylog -out "$WORK/cert.p12"
security import "$WORK/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P keylog -T /usr/bin/codesign
echo "Created \"$NAME\"."
