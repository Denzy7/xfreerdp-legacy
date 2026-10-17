#!/usr/bin/env bash
# Build OpenSSL 1.1.1w + FreeRDP 2.11.7 locally (no root) for legacy RDP servers
# (e.g. Windows Server 2008 R2 with TLS 1.0 only).
#
# Installs to: ~/.local/rdp-legacy
# Wrapper:     ~/.local/bin/xfreerdp-legacy
# Uninstall:   rm -rf ~/.local/rdp-legacy ~/.local/bin/xfreerdp-legacy
#
# Build deps (needs root once):
#
#   Arch:
#   sudo pacman -S --needed base-devel cmake libx11 libxext libxkbfile libxcursor \
#     libxrandr libxi libxinerama libxdamage libxrender libxtst libxv libxfixes libpulse cairo
#
#   Debian / Ubuntu:
#   sudo apt install build-essential cmake pkg-config curl libx11-dev libxext-dev \
#     libxkbfile-dev libxcursor-dev libxrandr-dev libxi-dev libxinerama-dev libxdamage-dev \
#     libxrender-dev libxtst-dev libxv-dev libxfixes-dev libpulse-dev libcairo2-dev

set -euo pipefail

PREFIX="$HOME/.local/rdp-legacy"
BUILD="$HOME/build/rdp-legacy"
OPENSSL_VER="1.1.1w"
FREERDP_VER="2.11.7"
JOBS="$(nproc)"

mkdir -p "$PREFIX" "$BUILD" "$HOME/.local/bin"

# Keep the system OpenSSL 3 out of the picture. Our OpenSSL is pinned via the
# -DOPENSSL_* cache vars below; PKG_CONFIG_PATH only gives it priority while the
# distro's default search dirs (incl. Debian multiarch) still resolve X11 etc.
unset OPENSSL_CONF LD_LIBRARY_PATH
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

# ---------------------------------------------------------------- OpenSSL
if [[ -f "$PREFIX/lib/libssl.so.1.1" ]]; then
  echo ">> OpenSSL $OPENSSL_VER already installed, skipping"
else
  echo ">> Building OpenSSL $OPENSSL_VER"
  cd "$BUILD"
  [[ -f openssl-$OPENSSL_VER.tar.gz ]] || curl -fLO \
    "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VER//./_}/openssl-$OPENSSL_VER.tar.gz"
  rm -rf "openssl-$OPENSSL_VER"
  tar xf "openssl-$OPENSSL_VER.tar.gz"
  cd "openssl-$OPENSSL_VER"
  ./config --prefix="$PREFIX" --openssldir="$PREFIX/ssl" --libdir=lib shared \
    -Wl,-rpath,"$PREFIX/lib"
  make -j"$JOBS"
  make install_sw
fi

# ---------------------------------------------------------------- FreeRDP
echo ">> Building FreeRDP $FREERDP_VER"
cd "$BUILD"
[[ -f freerdp-$FREERDP_VER.tar.gz ]] || curl -fL -o "freerdp-$FREERDP_VER.tar.gz" \
  "https://github.com/FreeRDP/FreeRDP/archive/refs/tags/$FREERDP_VER.tar.gz"
rm -rf "FreeRDP-$FREERDP_VER"
tar xf "freerdp-$FREERDP_VER.tar.gz"
cd "FreeRDP-$FREERDP_VER"

# CMAKE_POLICY_VERSION_MINIMUM=3.5 fixes CMake 4.x error:
#   "Compatibility with CMake < 3.5 has been removed from CMake."
CFLAGS="-Wno-incompatible-pointer-types -Wno-int-conversion -Wno-implicit-function-declaration" \
cmake -B build \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_RPATH="$PREFIX/lib" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DOPENSSL_ROOT_DIR="$PREFIX" \
  -DOPENSSL_INCLUDE_DIR="$PREFIX/include" \
  -DOPENSSL_SSL_LIBRARY="$PREFIX/lib/libssl.so" \
  -DOPENSSL_CRYPTO_LIBRARY="$PREFIX/lib/libcrypto.so" \
  -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_SWSCALE=OFF \
  -DWITH_WAYLAND=OFF -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF \
  -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_MANPAGES=OFF -DWITH_ALSA=OFF \
  -DWITH_OSS=OFF -DWITH_PULSE=ON -DWITH_X11=ON \
  -DWITH_CAIRO=ON

# Abort before compiling if CMake grabbed the system OpenSSL 3.
# Only check the exact cache entries (ignore *_DEBUG / *_RELEASE / NOTFOUND helpers).
echo ">> OpenSSL as seen by CMake:"
grep -E "^OPENSSL_(SSL_LIBRARY|CRYPTO_LIBRARY|INCLUDE_DIR):" build/CMakeCache.txt || true
if grep -E "^OPENSSL_(SSL_LIBRARY|CRYPTO_LIBRARY|INCLUDE_DIR):" build/CMakeCache.txt \
     | grep -v NOTFOUND | grep -qv "$PREFIX"; then
  echo "!! CMake picked the wrong OpenSSL (see above)"
  exit 1
fi

cmake --build build -j"$JOBS"
cmake --install build

# ---------------------------------------------------------------- Verify
echo ">> Linked OpenSSL:"
ldd "$PREFIX/bin/xfreerdp" | grep -E "libssl|libcrypto" || true
for lib in libssl libcrypto; do
  if ! ldd "$PREFIX/bin/xfreerdp" | grep -q "$lib\.so\.1\.1 => $PREFIX/"; then
    echo "!! $lib is not resolved from $PREFIX — something went wrong"
    exit 1
  fi
done

# ---------------------------------------------------------------- Wrapper
cat > "$HOME/.local/bin/xfreerdp-legacy" <<EOF
#!/usr/bin/env bash
# An OpenSSL 3 config would break OpenSSL 1.1.1's parser
unset OPENSSL_CONF
# tofu: accept the server cert on first connect, refuse if it changes later
exec "$PREFIX/bin/xfreerdp" /tls-seclevel:0 /cert:tofu "\$@"
EOF
chmod +x "$HOME/.local/bin/xfreerdp-legacy"

echo
echo ">> Done. Connect with:"
echo "   xfreerdp-legacy /v:<host> /u:<user> /sec:nla /dynamic-resolution +clipboard"
