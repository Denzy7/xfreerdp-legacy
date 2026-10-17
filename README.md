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
the display before handling `/version`, so that message means the binary
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

## Usage

### When to use it

Use `xfreerdp-legacy` only for servers that modern clients can't reach, such
as Windows Server 2008 R2 / Windows 7 without TLS 1.2. For Windows 10/11 and
current servers, use your distro's FreeRDP 3 (`xfreerdp3`): it's maintained
and gets security fixes. The options below work with both.

### Connect

```sh
xfreerdp-legacy /v:<host> /u:<user> /dynamic-resolution +clipboard
```

It asks for the password; don't put `/p:` on the command line, where it ends
up in your shell history and the process list. Add `/d:<domain>` for a domain
account.

Useful options:

| Option | Effect |
|---|---|
| `/dynamic-resolution` | Resize the remote desktop with the window |
| `/f` | Fullscreen (Ctrl+Alt+Enter toggles) |
| `+clipboard` | Shared clipboard, both directions |
| `/sound` | Play remote audio locally (otherwise it's discarded) |
| `/microphone` | Send local microphone to the server |
| `/drive:home,$HOME` | Share a local folder, shown as a drive on the server |
| `/sec:nla` | Require NLA (CredSSP) login; `/sec:tls` for servers without it |
| `/cert:name:<name>` | Expect this certificate name, e.g. the server's computer name when connecting by IP |
| `/log-level:DEBUG` | Verbose output for troubleshooting |

Use `/`-style options only (`/version`, not `--version`). The wrapper already
passes `/tls-seclevel:0 /cert:tofu`, and FreeRDP rejects command lines that
mix `/` and `--` styles.

### Certificates

`/cert:tofu` accepts the server's certificate on the first connection and
saves it. If it changes later, the connection is refused: check why before
trusting it. If the change is expected (server reinstalled or a new
certificate), forget the old one and connect again:

- `xfreerdp-legacy` (FreeRDP 2): delete the host's line from
  `~/.config/freerdp/known_hosts2`, e.g. `sed -i '/^<host> 3389 /d' ~/.config/freerdp/known_hosts2`
- `xfreerdp3` (FreeRDP 3): delete `~/.config/freerdp/server/<host>_3389.pem`

Windows uses a self-signed certificate named after the computer, so
connecting by IP prints a "certificate name mismatch" warning. That's
expected; `/cert:name:<computer-name>` silences it.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Connection times out | Firewall on the server drops port 3389, or the host is down |
| Connection refused | Remote Desktop isn't enabled on the server (see below) |
| Handshake / TLS error | Retry with `/log-level:DEBUG`; for very old servers try `/sec:tls` or `/sec:rdp` |
| Login fails right away | Windows refuses RDP for accounts with a blank password; set one |
| "Not authorized for remote login" | Add the account to the *Remote Desktop Users* group on the server |
| `ERRCONNECT_CONNECT_CANCELLED` on exit | Normal: you closed the window |
| Kerberos errors with `ATHENA.MIT.EDU` (FreeRDP 3) | FreeRDP tries Kerberos first and falls back to NTLM. `'/auth-pkg-list:!kerberos'` skips it (quote the `!` in bash) |

### Enabling Remote Desktop on Windows

On the Windows machine, in an Administrator Command Prompt (Remote Desktop
needs Pro, Enterprise or Education, or a Server edition):

```bat
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f
sc config TermService start= auto
netsh advfirewall firewall add rule name="RDP 3389" dir=in action=allow protocol=TCP localport=3389 profile=any
net stop TermService /y
net start TermService
```

`netstat -an | find ":3389"` should then show `LISTENING`. Stripped-down
Windows builds (e.g. tiny10) often ship with TermService disabled and the
built-in firewall rules removed; the commands above handle both.

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
