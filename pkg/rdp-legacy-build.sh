#!/usr/bin/env bash
# Shared build steps for the xfreerdp-legacy packages (PKGBUILD and mkdeb.sh).
#
# FreeRDP 2.x and OpenSSL 1.1.1 linked statically into a single xfreerdp binary,
# installed to /opt/rdp-legacy, for legacy RDP servers (e.g. Windows Server 2008 R2
# with TLS 1.0 only). Only system X11/pulse/cairo/etc. are linked dynamically.
#
# Usage:
#   rdp-legacy-build.sh build   <openssl-srcdir> <freerdp-srcdir>
#   rdp-legacy-build.sh install <openssl-srcdir> <freerdp-srcdir> <destdir>
#
# Env: PREFIX (default /opt/rdp-legacy), JOBS (default nproc)

set -euo pipefail

PREFIX="${PREFIX:-/opt/rdp-legacy}"
JOBS="${JOBS:-$(nproc)}"

cmd="${1:?usage: $0 build|install <openssl-src> <freerdp-src> [destdir]}"
OSSL_SRC="$(realpath "${2:?missing openssl source dir}")"
FRDP_SRC="$(realpath "${3:?missing freerdp source dir}")"
# OpenSSL is only needed at build time; it is staged here, not into the package.
# Its prefix is still PREFIX so no build paths get compiled into the binaries.
OSSL="$OSSL_SRC/_stage$PREFIX"

# Keep the system OpenSSL 3 out of the picture
unset OPENSSL_CONF LD_LIBRARY_PATH

build() {
  # ---------------------------------------------------------------- OpenSSL
  # Static only; -fPIC so it links into the PIE xfreerdp binary on any toolchain.
  # openssldir points into PREFIX so 1.1.1 never reads the system OpenSSL 3 config.
  echo ">> Building static OpenSSL"
  cd "$OSSL_SRC"
  ./config --prefix="$PREFIX" --openssldir="$PREFIX/ssl" --libdir=lib \
    no-shared no-tests -fPIC
  make -j"$JOBS"
  make DESTDIR="$OSSL_SRC/_stage" install_sw

  # ---------------------------------------------------------------- FreeRDP
  echo ">> Building FreeRDP"
  cd "$FRDP_SRC"
  # CMAKE_POLICY_VERSION_MINIMUM=3.5 fixes CMake 4.x; the -Wno-* flags let the
  # 2.x codebase build with modern GCC. BUILD_SHARED_LIBS=OFF links winpr,
  # libfreerdp and OpenSSL into xfreerdp itself, so there is exactly one OpenSSL
  # instance (shared libfreerdp2 + libwinpr2 would each embed their own copy).
  # --exclude-libs keeps those symbols private from any system libcrypto that
  # another library might load into the same process.
  CFLAGS="${CFLAGS:-} -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-implicit-function-declaration" \
  LDFLAGS="${LDFLAGS:-} -Wl,--exclude-libs,ALL" \
  PKG_CONFIG_PATH="$OSSL/lib/pkgconfig" \
  cmake -B build \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF \
    -DWITH_WINPR_TOOLS=OFF \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DOPENSSL_ROOT_DIR="$OSSL" \
    -DOPENSSL_INCLUDE_DIR="$OSSL/include" \
    -DOPENSSL_SSL_LIBRARY="$OSSL/lib/libssl.a" \
    -DOPENSSL_CRYPTO_LIBRARY="$OSSL/lib/libcrypto.a" \
    -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_SWSCALE=OFF \
    -DWITH_WAYLAND=OFF -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF \
    -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_MANPAGES=OFF -DWITH_ALSA=OFF \
    -DWITH_OSS=OFF -DWITH_PULSE=ON -DWITH_X11=ON \
    -DWITH_CAIRO=ON

  echo ">> OpenSSL as seen by CMake:"
  grep -E "^OPENSSL_(SSL_LIBRARY|CRYPTO_LIBRARY|INCLUDE_DIR):" build/CMakeCache.txt || true
  if grep -E "^OPENSSL_(SSL_LIBRARY|CRYPTO_LIBRARY|INCLUDE_DIR):" build/CMakeCache.txt \
       | grep -v NOTFOUND | grep -qv "$OSSL"; then
    echo "!! CMake picked the wrong OpenSSL (see above)" >&2
    exit 1
  fi

  cmake --build build -j"$JOBS"
}

install_pkg() {
  local dest="$(realpath -m "${1:?missing destdir}")"

  DESTDIR="$dest" cmake --install "$FRDP_SRC/build"

  # Static libs, headers, pkgconfig and cmake files: only needed to build xfreerdp
  rm -rf "$dest$PREFIX/include" "$dest$PREFIX/lib"

  # Nothing may depend on a shared libssl/libcrypto
  echo ">> Checking for dynamic OpenSSL dependencies"
  local f bad=0
  while IFS= read -r -d '' f; do
    if readelf -d "$f" 2>/dev/null | grep -qE "NEEDED.*lib(ssl|crypto)\.so"; then
      echo "!! $f links a shared OpenSSL" >&2
      bad=1
    fi
  done < <(find "$dest$PREFIX" -type f \( -name '*.so*' -o -perm -u+x \) -print0)
  (( bad == 0 )) || exit 1
  if ! grep -qa "OpenSSL $(sed -n 's/.*OPENSSL_VERSION_TEXT *"OpenSSL \([^ ]*\).*/\1/p' "$OSSL/include/openssl/opensslv.h")" \
       "$dest$PREFIX/bin/xfreerdp"; then
    echo "!! xfreerdp does not contain the bundled OpenSSL" >&2
    exit 1
  fi

  install -Dm755 /dev/stdin "$dest/usr/bin/xfreerdp-legacy" <<EOF
#!/usr/bin/env bash
# OPENSSL_CONF would make the bundled 1.1.1 parse a system OpenSSL 3 config
unset OPENSSL_CONF
# tofu: accept the server cert on first connect, refuse if it changes later
exec $PREFIX/bin/xfreerdp /tls-seclevel:0 /cert:tofu "\$@"
EOF
}

case "$cmd" in
  build)   build ;;
  install) install_pkg "${4:-}" ;;
  *)       echo "unknown command: $cmd" >&2; exit 2 ;;
esac
