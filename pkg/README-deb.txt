xfreerdp-legacy .deb builder
============================
A single xfreerdp binary (FreeRDP 2.11.7 + OpenSSL 1.1.1w, both linked
statically) for legacy RDP servers (e.g. Windows Server 2008 R2, TLS 1.0
only). Installs /opt/rdp-legacy/bin/xfreerdp plus /usr/bin/xfreerdp-legacy;
never touches the system freerdp or openssl.

On a headless box, "failed to open display" in the run checks is expected
and reported as ok: it means the binary loaded and started.

Source tarballs are included in build-deb/src (checked by SHA-256), so only
apt needs the internet.

Quick start (run from this directory as a normal user):

   ./build-and-log.sh --install-deps --install

That installs missing build deps, builds the .deb, inspects it, installs it
and smoke-tests it. Root steps use doas or sudo. Everything is written to
xfreerdp-legacy-<host>-<timestamp>.log in this directory - send that file
back if anything fails.

Flags (combine as needed):
   (none)          check deps, build, inspect the .deb
   --install-deps  apt install any missing build deps
   --install       install the .deb and test the installed binary

Manual route: ./mkdeb.sh, then sudo apt install ./xfreerdp-legacy_*.deb

Connect:
   xfreerdp-legacy /v:<host> /u:<user> /sec:nla /dynamic-resolution +clipboard

The wrapper uses /cert:tofu (accepts the server cert on first connect,
refuses if it later changes) and /tls-seclevel:0.

Cleanup (shows what it removes and asks first; -n = dry run):
   ./cleanup.sh                  build intermediates (~250 MB); keeps the
                                 .deb, logs and source tarballs
   ./cleanup.sh --all            also the .deb, logs and source tarballs
   ./cleanup.sh --deps           remove the build deps build-and-log.sh
                                 installed (and only what that orphans)
   ./cleanup.sh --uninstall      uninstall xfreerdp-legacy
   Everything:  ./cleanup.sh --all --deps --uninstall
