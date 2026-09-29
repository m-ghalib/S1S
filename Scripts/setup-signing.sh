#!/bin/bash
# One-time setup: create a self-signed code-signing certificate named "TabType Dev"
# in your login keychain. Signing with a STABLE identity (instead of ad-hoc) means
# macOS remembers your Accessibility and Screen Recording grants across rebuilds.
#
# After running this, do the one manual step it prints (trust the cert for Code
# Signing in Keychain Access), then build with ./Scripts/build.sh app.
set -euo pipefail

IDENTITY="TabType Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ Code-signing identity \"$IDENTITY\" already exists. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Generating self-signed code-signing certificate \"$IDENTITY\"…"
openssl req -x509 -newkey rsa:2048 -days 3650 \
    -keyout "$TMP/dev.key" -out "$TMP/dev.crt" -nodes \
    -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -legacy \
    -in "$TMP/dev.crt" -inkey "$TMP/dev.key" \
    -out "$TMP/dev.p12" -password pass:s1s >/dev/null 2>&1

security import "$TMP/dev.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P s1s -T /usr/bin/codesign

echo ""
echo "✓ Certificate imported into your login keychain."
echo ""
echo "ONE MANUAL STEP (required so codesign will use it):"
echo "  1. Open Keychain Access → login → Certificates."
echo "  2. Double-click \"$IDENTITY\"."
echo "  3. Expand ▸ Trust, set \"Code Signing\" to \"Always Trust\", close (enter password)."
echo ""
echo "Then run: ./Scripts/build.sh app"
