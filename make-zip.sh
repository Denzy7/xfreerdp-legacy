#!/usr/bin/env bash
# Bundle the Debian builder into dist/xfreerdp-legacy-deb.zip: the pkg/ scripts,
# README-deb.txt (as README.txt) and the source tarballs, so the target machine
# only needs apt. Versions and checksums are read from pkg/mkdeb.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$ROOT/pkg"
DIST="$ROOT/dist"
CACHE="$DIST/cache"
NAME="xfreerdp-legacy-deb"

var() { sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p" "$PKG/mkdeb.sh"; }
OPENSSL_VER="$(var OPENSSL_VER)"
FREERDP_VER="$(var FREERDP_VER)"
OPENSSL_SHA256="$(var OPENSSL_SHA256)"
FREERDP_SHA256="$(var FREERDP_SHA256)"

mkdir -p "$CACHE"
cd "$CACHE"
[[ -f openssl-$OPENSSL_VER.tar.gz ]] || curl -fLO \
  "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VER//./_}/openssl-$OPENSSL_VER.tar.gz"
[[ -f freerdp-$FREERDP_VER.tar.gz ]] || curl -fL -o "freerdp-$FREERDP_VER.tar.gz" \
  "https://github.com/FreeRDP/FreeRDP/archive/refs/tags/$FREERDP_VER.tar.gz"
sha256sum -c <<EOF
$OPENSSL_SHA256  openssl-$OPENSSL_VER.tar.gz
$FREERDP_SHA256  freerdp-$FREERDP_VER.tar.gz
EOF

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
D="$STAGE/$NAME"
mkdir -p "$D/build-deb/src"
install -m755 "$PKG"/{mkdeb.sh,rdp-legacy-build.sh,build-and-log.sh,cleanup.sh} "$D/"
install -m644 "$PKG/README-deb.txt" "$D/README.txt"
cp "$CACHE"/{openssl-$OPENSSL_VER,freerdp-$FREERDP_VER}.tar.gz "$D/build-deb/src/"

rm -f "$DIST/$NAME.zip"
(cd "$STAGE" && zip -qr "$DIST/$NAME.zip" "$NAME")
ls -lh "$DIST/$NAME.zip"
