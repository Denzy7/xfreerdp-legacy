#!/usr/bin/env bash
# Clean up after building xfreerdp-legacy (Debian via mkdeb.sh/build-and-log.sh,
# or Arch via makepkg). Shows what it will remove and asks first.
#
# Usage (from this directory):
#   ./cleanup.sh               build intermediates only (extracted sources, staging,
#                              makepkg src/ pkg/); keeps tarballs, packages and logs
#   ./cleanup.sh --all         also built packages, logs and source tarballs
#                              (a rebuild then has to download the sources again)
#   ./cleanup.sh --deps        Debian: remove the build deps build-and-log.sh installed,
#                              plus only the extra packages that frees up
#   ./cleanup.sh --uninstall   remove the installed xfreerdp-legacy package
#   ./cleanup.sh --local       remove the ~/.local install made by buildfreerdp.sh
#   -n  dry run (show the plan, change nothing)    -y  don't ask
#
# Flags combine. Root steps use doas or sudo, whichever exists.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

ALL=0 DEPS=0 UNINSTALL=0 LOCAL=0 DRY=0 YES=0
for arg in "$@"; do
  case "$arg" in
    --all)       ALL=1 ;;
    --deps)      DEPS=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --local)     LOCAL=1 ;;
    -n)          DRY=1 ;;
    -y)          YES=1 ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *)           echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

if (( EUID == 0 )); then ROOT=()
elif command -v doas >/dev/null; then ROOT=(doas)
elif command -v sudo >/dev/null; then ROOT=(sudo)
else ROOT=(false)
fi

if command -v dpkg-query >/dev/null && ! command -v pacman >/dev/null; then DISTRO=debian
elif command -v pacman >/dev/null; then DISTRO=arch
else DISTRO=other
fi

# ---------------------------------------------------------------- Plan
paths=()
add() { local p; for p in "$@"; do [[ -e $p || -L $p ]] && paths+=("$p"); done; return 0; }

shopt -s nullglob
# Debian build tree (mkdeb.sh): keep the source tarballs unless --all
add build-deb/debian build-deb/src/*/
# makepkg build tree
add src pkg
if (( ALL )); then
  add build-deb xfreerdp-legacy_*.deb xfreerdp-legacy-*.log .build-deps-installed
  add xfreerdp-legacy-*.pkg.tar.* openssl-*.tar.gz freerdp-*.tar.gz
fi
if (( LOCAL )); then
  add "$HOME/.local/rdp-legacy" "$HOME/.local/bin/xfreerdp-legacy" "$HOME/build/rdp-legacy"
fi
shopt -u nullglob

remove_pkgs=() orphans=()
if (( DEPS )); then
  if [[ $DISTRO != debian ]]; then
    echo "!! --deps is only for Debian/Ubuntu (on Arch: pacman -Rns \$(pacman -Qdtq) for orphans)" >&2
    exit 1
  fi
  # What build-and-log.sh installed; older runs only left it in their logs
  if [[ -f .build-deps-installed ]]; then
    mapfile -t wanted < <(sort -u .build-deps-installed)
  else
    mapfile -t wanted < <(sed -n 's/^  MISSING  //p' xfreerdp-legacy-*.log 2>/dev/null | sort -u)
  fi
  for p in "${wanted[@]}"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
      remove_pkgs+=("$p")
    fi
  done
fi

uninstall=0
if (( UNINSTALL )); then
  if [[ $DISTRO == debian ]] &&
     dpkg-query -W -f='${Status}' xfreerdp-legacy 2>/dev/null | grep -q "install ok installed"; then
    uninstall=1
  elif [[ $DISTRO == arch ]] && pacman -Q xfreerdp-legacy >/dev/null 2>&1; then
    uninstall=1
  fi
fi

# ---------------------------------------------------------------- Show
nothing=1
if (( ${#paths[@]} )); then
  nothing=0
  echo "Files to delete:"
  du -sh "${paths[@]}" 2>/dev/null | sed 's/^/  /'
fi
if (( uninstall )); then
  nothing=0
  echo "Package to uninstall: xfreerdp-legacy"
fi
if (( ${#remove_pkgs[@]} )); then
  nothing=0
  echo "Build deps to remove: ${remove_pkgs[*]}"
  # Anything else apt would take with them (packages that depend on these)
  mapfile -t extra < <(apt-get -s remove "${remove_pkgs[@]}" 2>/dev/null \
    | awk '/^Remv /{print $2}' | grep -vxF -f <(printf '%s\n' "${remove_pkgs[@]}") || true)
  if (( ${#extra[@]} )); then
    echo "!! apt would ALSO remove these, which depend on them: ${extra[*]}"
    echo "!! Check that list before you answer y."
  fi
  echo "  (plus any packages that only these needed; listed after removal)"
elif (( DEPS )); then
  echo "Build deps: none recorded or none still installed."
fi
if (( UNINSTALL && !uninstall )); then echo "xfreerdp-legacy is not installed."; fi

if (( nothing )); then echo "Nothing to clean."; exit 0; fi
if (( DRY )); then echo "(dry run: nothing changed)"; exit 0; fi
if (( !YES )); then
  read -rp "Proceed? [y/N] " ans
  [[ $ans == [yY]* ]] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------- Do it
if (( ${#paths[@]} )); then
  rm -rf -- "${paths[@]}"
  echo ">> Deleted files"
fi

if (( uninstall )); then
  case "$DISTRO" in
    debian) "${ROOT[@]}" apt-get remove -y xfreerdp-legacy ;;
    arch)   "${ROOT[@]}" pacman -R --noconfirm xfreerdp-legacy ;;
  esac
  echo ">> Uninstalled xfreerdp-legacy"
fi

if (( ${#remove_pkgs[@]} )); then
  # Only autoremove what *this* removal orphaned, not packages that were
  # already autoremovable before (those are the admin's business)
  before="$(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}' | sort)"
  "${ROOT[@]}" apt-get remove -y "${remove_pkgs[@]}"
  after="$(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}' | sort)"
  mapfile -t orphans < <(comm -13 <(echo "$before") <(echo "$after") | sed '/^$/d')
  if (( ${#orphans[@]} )); then
    echo ">> Also removing packages only the build deps needed: ${orphans[*]}"
    "${ROOT[@]}" apt-get remove -y "${orphans[@]}"
  fi
  rm -f .build-deps-installed
  echo ">> Removed build deps"
fi

echo ">> Done"
