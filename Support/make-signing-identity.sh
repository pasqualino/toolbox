#!/bin/zsh
# One-time setup: creates a self-signed "Toolbox Dev" code-signing identity in your login keychain.
# make-app.sh signs with it when it exists. With a stable identity, macOS keeps Screen Recording,
# Location and other permissions across rebuilds; ad hoc signatures change with every build.
#
# Run it yourself: macOS asks for your password to trust the certificate for code signing.
# Undo: delete "Toolbox Dev" in Keychain Access (login keychain, My Certificates).
set -euo pipefail
NAME="Toolbox Dev"
KEYCHAIN=~/Library/Keychains/login.keychain-db

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.conf" <<EOF
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

# The system LibreSSL: its PKCS#12 encryption is what `security import` accepts.
SSL=/usr/bin/openssl
$SSL req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.conf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
$SSL pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout pass:toolbox

# -T lets codesign use the key without asking each build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P toolbox -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

security find-identity -v -p codesigning | grep "\"$NAME\"" && echo "Done. Rebuild with ./make-app.sh."
