#!/usr/bin/env bash
# Build a .deb of FreeRDP 2.11.7 with OpenSSL 1.1.1w, both linked statically,
# for legacy RDP servers (e.g. Windows Server 2008 R2 with TLS 1.0 only).
# Run on the Debian/Ubuntu release you want to install on (no root needed).
#
# Build deps:
#   sudo apt install build-essential dpkg-dev cmake pkg-config curl perl \
#     libx11-dev libxext-dev libxkbfile-dev libxcursor-dev libxrandr-dev libxi-dev \
#     libxinerama-dev libxdamage-dev libxrender-dev libxtst-dev libxv-dev \
#     libxfixes-dev libpulse-dev libcairo2-dev libusb-1.0-0-dev libsystemd-dev
#
# Output: ./xfreerdp-legacy_<ver>-<rel>_<arch>.deb
# Install: sudo apt install ./xfreerdp-legacy_*.deb

set -euo pipefail

PKGNAME="xfreerdp-legacy"
FREERDP_VER="2.11.7"
OPENSSL_VER="1.1.1w"
PKGREL="2"
OPENSSL_SHA256="cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8"
FREERDP_SHA256="22dbeeaad065e93f152d70e04ec8eeab08aa32c406a96be64f252526623625a4"
export PREFIX="/opt/rdp-legacy"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$PWD"
WORK="${WORK:-$PWD/build-deb}"
SRC="$WORK/src"
STAGE="$WORK/debian/$PKGNAME"

for tool in dpkg-deb dpkg-shlibdeps cmake curl readelf; do
  command -v "$tool" >/dev/null || { echo "!! missing $tool (see build deps at top of $0)" >&2; exit 1; }
done

mkdir -p "$SRC"
rm -rf "$STAGE"

# ---------------------------------------------------------------- Sources
cd "$SRC"
[[ -f openssl-$OPENSSL_VER.tar.gz ]] || curl -fLO \
  "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VER//./_}/openssl-$OPENSSL_VER.tar.gz"
[[ -f freerdp-$FREERDP_VER.tar.gz ]] || curl -fL -o "freerdp-$FREERDP_VER.tar.gz" \
  "https://github.com/FreeRDP/FreeRDP/archive/refs/tags/$FREERDP_VER.tar.gz"
sha256sum -c <<EOF
$OPENSSL_SHA256  openssl-$OPENSSL_VER.tar.gz
$FREERDP_SHA256  freerdp-$FREERDP_VER.tar.gz
EOF
rm -rf "openssl-$OPENSSL_VER" "FreeRDP-$FREERDP_VER"
tar xf "openssl-$OPENSSL_VER.tar.gz"
tar xf "freerdp-$FREERDP_VER.tar.gz"

# ---------------------------------------------------------------- Build
bash "$HERE/rdp-legacy-build.sh" build "$SRC/openssl-$OPENSSL_VER" "$SRC/FreeRDP-$FREERDP_VER"
bash "$HERE/rdp-legacy-build.sh" install "$SRC/openssl-$OPENSSL_VER" "$SRC/FreeRDP-$FREERDP_VER" "$STAGE"

DOC="$STAGE/usr/share/doc/$PKGNAME"
install -d "$DOC"
{
  echo "FreeRDP $FREERDP_VER (Apache-2.0):"
  echo
  cat "$SRC/FreeRDP-$FREERDP_VER/LICENSE"
  echo
  echo "OpenSSL $OPENSSL_VER (OpenSSL / SSLeay license), statically linked:"
  echo
  cat "$SRC/openssl-$OPENSSL_VER/LICENSE"
} > "$DOC/copyright"

# ---------------------------------------------------------------- Depends
# dpkg-shlibdeps wants a debian/control and a DEBIAN/ dir in the package root.
cd "$WORK"
install -d "$STAGE/DEBIAN"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$PKGNAME" "$PKGNAME" > debian/control
mapfile -d '' elfs < <(find "$STAGE$PREFIX" -type f \( -name '*.so*' -o -perm -u+x \) -print0)
DEPENDS="$(dpkg-shlibdeps -O "${elfs[@]}" \
  | sed -n 's/^shlibs:Depends=//p')"
[[ -n "$DEPENDS" ]] || { echo "!! dpkg-shlibdeps produced no dependencies" >&2; exit 1; }

# ---------------------------------------------------------------- Package
ARCH="$(dpkg --print-architecture)"
ME="$(id -un)"
MAINTAINER="${MAINTAINER:-$(git config user.name 2>/dev/null || echo "$ME") <$(git config user.email 2>/dev/null || echo "$ME@localhost")>}"
SIZE="$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKGNAME
Version: $FREERDP_VER-$PKGREL
Architecture: $ARCH
Maintainer: $MAINTAINER
Installed-Size: $SIZE
Depends: $DEPENDS
Section: net
Priority: optional
Homepage: https://www.freerdp.com/
Description: FreeRDP 2 X11 client with static OpenSSL 1.1.1 for legacy RDP servers
 A single xfreerdp $FREERDP_VER binary with OpenSSL $OPENSSL_VER linked in, so it
 can still talk TLS 1.0 to old servers such as Windows Server 2008 R2.
 Installed to $PREFIX; launch it with xfreerdp-legacy.
EOF

DEB="$OUT/${PKGNAME}_${FREERDP_VER}-${PKGREL}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB"
echo
echo ">> Built $DEB"
echo "   Install with: sudo apt install $DEB"
