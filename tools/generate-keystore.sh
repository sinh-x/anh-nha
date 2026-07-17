#!/usr/bin/env bash
# Generate a release keystore for anh-nha and write android/key.properties.
# Run once on the machine that publishes releases. Never commit the keystore
# or key.properties — both are gitignored.
#
# Usage: tools/generate-keystore.sh [keystore-path] [alias]
set -euo pipefail

KEYSTORE="${1:-android/app/anh-nha.jks}"
ALIAS="${2:-anh-nha}"
STORE_PASS="${STORE_PASS:-$(openssl rand -base64 18)}"
KEY_PASS="${KEY_PASS:-$STORE_PASS}"

mkdir -p "$(dirname "$KEYSTORE")"

keytool -genkey -v \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass "$STORE_PASS" -keypass "$KEY_PASS" \
  -dname "CN=anh-nha, OU=Family, O=sinh, L=Hanoi, C=VN"

cat > android/key.properties <<EOF
storeFile=$KEYSTORE
storePassword=$STORE_PASS
keyAlias=$ALIAS
keyPassword=$KEY_PASS
EOF

echo "Keystore written to $KEYSTORE"
echo "Config written to android/key.properties (gitignored)"
echo "Back up $KEYSTORE and the password somewhere safe — losing it means"
echo "you cannot publish updates under the same package id."