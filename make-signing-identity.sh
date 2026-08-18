#!/bin/bash
# Creates a local, self-signed code-signing identity for MacAmp.
#
# Why: ad-hoc signing (codesign -s -) makes the designated requirement a bare
# cdhash, which changes on every build. macOS TCC keys the microphone grant to
# that requirement, so every rebuild is a new app that must ask permission
# again. A certificate makes the requirement identity-based, and the grant
# sticks across rebuilds.
#
# This needs no Apple Developer account. Notarisation and a Developer ID are
# only required to distribute the app to other people.
set -e
D="$HOME/.macamp-signing"
NAME="MacAmp Local Signing"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "identity already present: $NAME"; exit 0
fi

mkdir -p "$D"; chmod 700 "$D"; cd "$D"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=$NAME/O=Adam Britsch" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature"
chmod 600 key.pem

# macOS Security.framework cannot read OpenSSL 3's default PKCS#12 MAC/PBE, so
# these legacy parameters are required, not optional.
openssl pkcs12 -export -out identity.p12 -inkey key.pem -in cert.pem \
  -name "$NAME" -passout pass:macamp \
  -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
chmod 600 identity.p12

security import identity.p12 -k "$HOME/Library/Keychains/login.keychain-db" \
  -P macamp -T /usr/bin/codesign -A

echo "created: $NAME  (private key in $D, never in the repo)"
echo "NOTE: macOS will ask for microphone access ONCE more after the next build,"
echo "      because the app's signing identity has changed. It will not ask again."
