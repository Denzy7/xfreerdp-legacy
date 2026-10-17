#!/usr/bin/env bash
# Build (and optionally install + smoke-test) the xfreerdp-legacy .deb, logging
# everything to one file you can send back for debugging.
#
# Usage (from this directory, as a normal user):
#   ./build-and-log.sh                  # check deps, build, inspect the .deb
#   ./build-and-log.sh --install-deps   # also apt install missing build deps
#   ./build-and-log.sh --install        # also install the .deb and test it
#   (flags combine)
#
# Root steps use doas or sudo, whichever exists.
# Log: ./xfreerdp-legacy-<host>-<timestamp>.log

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

INSTALL_DEPS=0 INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install-deps) INSTALL_DEPS=1 ;;
    --install)      INSTALL=1 ;;
    -h|--help)      sed -n '2,12p' "$0"; exit 0 ;;
    *)              echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

LOG="$HERE/xfreerdp-legacy-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOG") 2>&1

RESULTS=()
section() { printf '\n========== %s ==========\n' "$*"; }
result()  { RESULTS+=("$1: $2"); printf '>> %s: %s\n' "$1" "$2"; }
run()     { echo "\$ $*"; "$@"; }

if (( EUID == 0 )); then ROOT=()
elif command -v doas >/dev/null; then ROOT=(doas)
elif command -v sudo >/dev/null; then ROOT=(sudo)
else ROOT=(false)
fi

finish() {
  local rc=$?
  section "Summary"
  printf '%s\n' "${RESULTS[@]}"
  echo
  echo "Log saved to: $LOG"
  # Non-zero if any check failed, so CI notices
  if (( rc == 0 )) && printf '%s\n' "${RESULTS[@]}" | grep -q ": FAIL"; then exit 1; fi
  exit "$rc"
}
trap finish EXIT

# ---------------------------------------------------------------- System
section "System"
date -Is
cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION_ID|ID)='
uname -srm
echo "dpkg arch: $(dpkg --print-architecture 2>/dev/null || echo '?')"
echo "nproc: $(nproc)"
echo "free disk here: $(df -h --output=avail . | tail -1 | tr -d ' ')"
ldd --version 2>/dev/null | head -1
for t in gcc cmake make perl pkg-config dpkg-deb dpkg-shlibdeps curl readelf; do
  printf '%-15s ' "$t"
  if ! command -v "$t" >/dev/null; then echo "MISSING"
  elif [[ $t == perl ]]; then perl -e 'print "perl $^V\n"'
  else "$t" --version 2>/dev/null | head -1
  fi
done

# ---------------------------------------------------------------- Build deps
section "Build dependencies"
DEPS=(build-essential dpkg-dev cmake pkg-config curl ca-certificates perl
      libx11-dev libxext-dev libxkbfile-dev libxcursor-dev libxrandr-dev libxi-dev
      libxinerama-dev libxdamage-dev libxrender-dev libxtst-dev libxv-dev
      libxfixes-dev libpulse-dev libcairo2-dev libusb-1.0-0-dev libsystemd-dev)
missing=()
for p in "${DEPS[@]}"; do
  if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
    printf '  ok       %s %s\n' "$p" "$(dpkg-query -W -f='${Version}' "$p")"
  else
    printf '  MISSING  %s\n' "$p"
    missing+=("$p")
  fi
done

if (( ${#missing[@]} )); then
  if (( INSTALL_DEPS )); then
    run "${ROOT[@]}" apt-get update
    run "${ROOT[@]}" apt-get install -y --no-install-recommends "${missing[@]}" &&
      printf '%s\n' "${missing[@]}" >> "$HERE/.build-deps-installed"  # for cleanup.sh --deps
  else
    result "deps" "FAIL, missing: ${missing[*]}"
    echo "Re-run with --install-deps, or: sudo apt install --no-install-recommends ${missing[*]}"
    exit 1
  fi
fi
result "deps" "ok"

# ---------------------------------------------------------------- Build
section "Build (mkdeb.sh)"
start=$SECONDS
bash "$HERE/mkdeb.sh"
rc=$?
if (( rc != 0 )); then
  result "build" "FAIL (exit $rc after $((SECONDS - start))s), see the lines above"
  exit 1
fi
result "build" "ok ($((SECONDS - start))s)"

DEB="$(ls -t "$HERE"/xfreerdp-legacy_*.deb | head -1)"
STAGE="$HERE/build-deb/debian/xfreerdp-legacy"

# ---------------------------------------------------------------- Inspect
section "Package info"
ls -l "$DEB"
dpkg-deb -I "$DEB"
echo
echo "Files:"
dpkg-deb -c "$DEB" | awk '{print $6}' | grep -v '/$'

BIN="$STAGE/opt/rdp-legacy/bin/xfreerdp"

section "Linked libraries (staged build)"
ls -l "$BIN"
readelf -d "$BIN" | sed -n 's/.*NEEDED.*\[\(.*\)\]/  \1/p'
# grep the file directly: strings|grep -q under pipefail reports false failures
copies="$(grep -ac "OpenSSL 1\.1\.1[a-z]*  " "$BIN")"
if (( copies == 1 )); then
  result "static openssl" "ok (1 copy in xfreerdp)"
else
  result "static openssl" "FAIL, found $copies OpenSSL 1.1.1 copies in xfreerdp (want 1)"
fi

# FreeRDP 2's X11 client opens the display before handling --version, so on a
# headless box "failed to open display" means the binary loaded and started fine.
smoke() {
  local out rc
  out="$("$@" --version 2>&1)"; rc=$?
  echo "$out"
  if (( rc == 0 )); then echo "ok"
  elif grep -q "failed to open display" <<<"$out"; then echo "ok (no X display; binary loads and starts)"
  else echo "FAIL (exit $rc)"
  fi
}

section "Run staged binary"
r="$(smoke "$BIN")"; echo "$r"
result "staged run" "$(tail -1 <<<"$r")"

# ---------------------------------------------------------------- Install
if (( INSTALL )); then
  section "Install .deb"
  if run "${ROOT[@]}" apt-get install -y "$DEB"; then
    result "install" "ok"
    section "Installed binary"
    r="$(smoke xfreerdp-legacy)"; echo "$r"
    result "installed run" "$(tail -1 <<<"$r")"
    echo
    ldd /opt/rdp-legacy/bin/xfreerdp
    if ldd /opt/rdp-legacy/bin/xfreerdp | grep -q "not found"; then
      result "installed libs" "FAIL, missing libraries (see ldd above)"
    elif ldd /opt/rdp-legacy/bin/xfreerdp | grep -qE "lib(ssl|crypto)\.so"; then
      result "installed libs" "FAIL, links a shared OpenSSL"
    else
      result "installed libs" "ok"
    fi
  else
    result "install" "FAIL"
  fi
else
  result "install" "skipped (use --install)"
fi
