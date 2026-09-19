#!/bin/bash
# setup-signing-identity.sh — one-time creation of a local code-signing identity.
#
# Why: ad-hoc signatures (`codesign --sign -`) change with every build, so macOS
# treats each build as a different app and asks for the login-keychain password
# again ("Ngate2VPN wants to use your confidential information…"). Signing every
# build with the same self-signed identity keeps "Always Allow" valid across
# updates.
#
# Run once:   ./Scripts/setup-signing-identity.sh
# Then build: ./build-app.sh        (picks the identity up automatically)
#
# What it does: creates a self-signed code-signing certificate, imports it into
# your login keychain, and marks it trusted for code signing (macOS shows one
# password/Touch ID dialog for that last step).

set -euo pipefail

NAME="${1:-Ngate2VPN Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "✓ Identity \"$NAME\" already exists and is valid — nothing to do."
    exit 0
fi

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "Identity \"$NAME\" exists but is not trusted for code signing."
    echo "Trusting it (macOS will ask for your password)…"
    HASH=$(security find-identity -p codesigning | grep "\"$NAME\"" | head -1 | awk '{print $2}')
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP/cert.pem"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
    echo "✓ Done ($HASH)."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
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
EOF

# /usr/bin/openssl (LibreSSL) writes PKCS#12 files that `security import` reads;
# a Homebrew OpenSSL 3 needs -legacy for that.
OPENSSL=/usr/bin/openssl
P12_PASS=$(uuidgen)

echo "==> Generating certificate \"$NAME\" (valid 10 years)…"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/openssl.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$P12_PASS"

echo "==> Importing into the login keychain…"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

echo "==> Trusting it for code signing (macOS will ask for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo ""
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "✓ Identity \"$NAME\" is ready."
    echo ""
    echo "Next: run ./build-app.sh. The first build may show a keychain dialog asking"
    echo "whether codesign may use the new key — choose \"Always Allow\"."
    echo "After installing that build, the first launch asks for keychain access once;"
    echo "choose \"Always Allow\" and later updates will not ask again."
else
    echo "✗ The identity was created but is not reported as valid for code signing."
    echo "  Check Keychain Access → login → \"$NAME\" → Trust → Code Signing: Always Trust."
    exit 1
fi
