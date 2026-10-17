# xfreerdp-legacy

FreeRDP 2.11.7 built against OpenSSL 1.1.1w, for RDP servers too old for
OpenSSL 3, such as Windows Server 2008 R2 that only speaks TLS 1.0.

Modern distros ship FreeRDP 3 on OpenSSL 3, which refuses TLS 1.0 handshakes
and legacy ciphers. This repo builds a client that still can, without touching
the system `freerdp` or `openssl`.

## Layout

| Path | What |
|---|---|
| `buildfreerdp.sh` | Quick local build into `~/.local/rdp-legacy` (shared OpenSSL, no root, no package) |
| `pkg/rdp-legacy-build.sh` | Shared build steps for both packages |
| `pkg/PKGBUILD` | Arch package |
| `pkg/mkdeb.sh` | Debian/Ubuntu `.deb` generator |
| `pkg/build-and-log.sh` | Runs `mkdeb.sh` plus checks, logging everything to one file |
| `pkg/cleanup.sh` | Removes build files, build deps and/or the installed package |
| `pkg/README-deb.txt` | README shipped inside the Debian zip |
| `make-zip.sh` | Bundles the Debian builder and sources into `dist/xfreerdp-legacy-deb.zip` |
| `.github/workflows/build.yml` | CI: builds and tests the `.deb`s and the Arch package, releases on tags |

## What the packages contain

A single `/opt/rdp-legacy/bin/xfreerdp` with FreeRDP and OpenSSL both linked
statically (one OpenSSL instance, symbols kept private), plus a
`/usr/bin/xfreerdp-legacy` wrapper. Only system libraries such as X11,
PulseAudio, cairo, libusb and libsystemd are linked dynamically, and the
package dependencies cover them.

The wrapper runs `xfreerdp /tls-seclevel:0 /cert:tofu`. `tofu` accepts the
server certificate on first connect and refuses if it later changes. It also
unsets `OPENSSL_CONF`, so OpenSSL 1.1.1 never parses a system OpenSSL 3 config.

## Arch

```sh
cd pkg
makepkg -si
```

## Debian / Ubuntu

On the Debian machine itself, from `pkg/`:

```sh
./build-and-log.sh --install-deps --install
```

This installs missing build deps, builds `xfreerdp-legacy_<ver>-<rel>_<arch>.deb`,
installs it and smoke-tests it. The output goes to
`xfreerdp-legacy-<host>-<timestamp>.log`.

To build on a machine that doesn't have this repo, run `./make-zip.sh` here,
copy `dist/xfreerdp-legacy-deb.zip` over, unzip it and follow its `README.txt`.
The zip includes the source tarballs, so only `apt` needs internet there.

On a headless machine the run checks report "no X display": FreeRDP 2 opens
the display before handling `--version`, so that message means the binary
loaded and started.

## CI

`.github/workflows/build.yml` runs on every push to `main` and on pull requests:

- **deb**: `build-and-log.sh --install-deps --install` in Debian 12, Debian 13
  and Ubuntu 24.04 containers. It builds, installs and smoke-tests the package,
  and fails if any check fails. Packages and logs are uploaded as artifacts.
- **arch**: `makepkg` in `archlinux:base-devel`, then installs the package and
  checks there's no shared OpenSSL and exactly one bundled copy.

Pushing a `v*` tag also attaches all packages to a GitHub release:

```sh
git tag v2.11.7-2 && git push origin v2.11.7-2
```

The `.deb` files are named per distro, e.g.
`xfreerdp-legacy_2.11.7-2+debian13_amd64.deb`; install the one for your release.

## Connect

```sh
xfreerdp-legacy /v:<host> /u:<user> /sec:nla /dynamic-resolution +clipboard
```

If the handshake fails, add `/log-level:DEBUG`.

## Cleanup

```sh
pkg/cleanup.sh -n                          # show what the default would remove
pkg/cleanup.sh                             # build intermediates only
pkg/cleanup.sh --all --deps --uninstall    # everything
pkg/cleanup.sh --local                     # the ~/.local install from buildfreerdp.sh
```

## Updating versions

Change the versions and SHA-256 sums in both `pkg/PKGBUILD` and `pkg/mkdeb.sh`,
and bump `pkgrel` / `PKGREL`. `make-zip.sh` reads them from `mkdeb.sh`.
