#!/usr/bin/env bash
# Creates a self-signed code-signing identity for local builds.
#
# macOS remembers the Accessibility permission by code signature. Ad-hoc signatures
# change on every build, so the permission stops applying after each rebuild. A
# stable local identity fixes that.
#
# The identity lives in its own keychain file inside .signing/ (git-ignored). Your
# login keychain and keychain search list are left alone. Delete .signing/ to undo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_DIR="$ROOT/.signing"
KEYCHAIN="$SIGNING_DIR/spacenamer-signing.keychain-db"
PASSWORD="spacenamer"
NAME="SpaceNamer Local Signing"

if [ -f "$KEYCHAIN" ]; then
  echo "✓ Local signing identity already exists ($KEYCHAIN)"
  exit 0
fi

# The system LibreSSL writes PKCS#12 files the macOS keychain can import; OpenSSL 3+
# defaults to algorithms it rejects, so force the legacy ones either way.
OPENSSL=/usr/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl)"

mkdir -p "$SIGNING_DIR"
WORK="$(mktemp -d)"
cleanup() {
  status=$?
  rm -rf "$WORK"
  if [ $status -ne 0 ]; then rm -f "$KEYCHAIN"; fi
}
trap cleanup EXIT

cat > "$WORK/openssl.cnf" <<EOF
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
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -name "$NAME" -passout "pass:$PASSWORD" -out "$WORK/identity.p12"

# create-keychain adds the new keychain to the search list; put the list back after.
original_keychains=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%\"}"
  original_keychains+=("${line#\"}")
done < <(security list-keychains -d user)

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "${original_keychains[@]}"
security set-keychain-settings "$KEYCHAIN" # no auto-lock timeout
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

echo "✓ Created \"$NAME\" in $KEYCHAIN"
echo "  Builds from scripts/build-app.sh now keep the same signature."
