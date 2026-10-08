#!/bin/bash
# Create one persistent signing identity in a dedicated user-owned keychain.
set -euo pipefail
umask 077

SIGNING_DIR="${TOKENDECK_SIGNING_DIR:-$HOME/.config/tokendeck/signing}"
KEYCHAIN="$SIGNING_DIR/signing.keychain-db"
mkdir -p "$SIGNING_DIR"
register_keychain() {
    /usr/bin/python3 - "$KEYCHAIN" <<'PYTHON'
import shlex, subprocess, sys
chains = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
if sys.argv[1] not in chains:
    subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *chains, sys.argv[1]], check=True)
PYTHON
}
if [[ -f "$SIGNING_DIR/identity" && -f "$KEYCHAIN" && -f "$SIGNING_DIR/password" ]]; then
    register_keychain
    echo "TokenDeck signing identity already exists."
    exit 0
fi
if [[ -e "$KEYCHAIN" || -e "$SIGNING_DIR/identity" ]]; then
    echo "Incomplete signing setup; inspect $SIGNING_DIR before retrying." >&2
    exit 1
fi

WORK_DIR=$(mktemp -d "$SIGNING_DIR/setup.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
/usr/bin/openssl rand -base64 32 > "$SIGNING_DIR/password"
KEYCHAIN_PASSWORD=$(cat "$SIGNING_DIR/password")
cat > "$WORK_DIR/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = name
x509_extensions = signing
prompt = no
[name]
CN = TokenDeck Local Development
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
    -config "$WORK_DIR/certificate.cnf" -keyout "$WORK_DIR/key.pem" \
    -out "$SIGNING_DIR/certificate.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK_DIR/key.pem" \
    -in "$SIGNING_DIR/certificate.pem" -out "$WORK_DIR/identity.p12" \
    -passout "file:$SIGNING_DIR/password"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
/usr/bin/openssl x509 -in "$SIGNING_DIR/certificate.pem" -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr -d ':\r\n' > "$SIGNING_DIR/identity"
register_keychain
echo "Created persistent TokenDeck signing identity in $SIGNING_DIR."
