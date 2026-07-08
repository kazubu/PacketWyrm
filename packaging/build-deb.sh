#!/usr/bin/env bash
# Build a binary .deb for PacketWyrm from already-built artifacts in sw/build/.
#
# This assembles the package with plain dpkg-deb (no debhelper). It does NOT
# compile anything and does NOT touch the network. Build the software first:
#     make -C sw -j
# (optionally `make -C sw pw_flash pw_reboot` etc. for the helper tools).
#
# Layout produced under a staging root, then `dpkg-deb --build`:
#     /usr/bin/{packetwyrmd,pktwyrm,packetwyrm-proxyd, pw_* helpers}
#     /usr/lib/<multiarch>/libpacketwyrm.so
#     /lib/systemd/system/{packetwyrmd,packetwyrm-proxyd}.service
#     /usr/lib/{sysusers.d,tmpfiles.d}/packetwyrm.conf
#     /etc/packetwyrm/packetwyrm.yaml            (conffile, EDIT-ME example)
#     /usr/share/bash-completion/completions/pktwyrm
#     /usr/share/zsh/vendor-completions/_pktwyrm
#     /usr/share/man/man1/pktwyrm.1, man8/packetwyrm{d,-proxyd}.8
#     /usr/share/packetwyrm/grafana/packetwyrm-dashboard.json (+README)
#
set -euo pipefail

# --- locations -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/sw/build"
DEB_SRC="$SCRIPT_DIR/deb"
DIST_DIR="$SCRIPT_DIR/dist"

# --- version + arch --------------------------------------------------------
# Fallback version if not in a git tree / no tags.
VERSION="${VERSION:-0.1.0}"
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if desc="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null)"; then
        # Strip a leading v; turn describe's dashes into deb-friendly form.
        desc="${desc#v}"
        # git describe with tags -> 1.2.3-4-gabc123 ; without tags -> abc123.
        # Make it a valid deb version: replace '-' after the tag with '+'.
        if printf '%s' "$desc" | grep -qE '^[0-9]'; then
            VERSION="$(printf '%s' "$desc" | sed 's/-/+/;s/-/./g')"
        else
            # No tag: 0.1.0+g<sha> (or +dirty)
            VERSION="${VERSION}+g${desc}"
        fi
    fi
fi

ARCH="$(dpkg --print-architecture)"
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "")"
if [ -n "$MULTIARCH" ]; then
    LIBDIR="usr/lib/$MULTIARCH"
else
    LIBDIR="usr/lib"
fi

echo "==> PacketWyrm .deb build"
echo "    version : $VERSION"
echo "    arch    : $ARCH"
echo "    libdir  : /$LIBDIR"

# --- sanity: required artifacts --------------------------------------------
require() {
    if [ ! -f "$BUILD_DIR/$1" ]; then
        echo "ERROR: missing artifact sw/build/$1 -- run 'make -C sw -j' first" >&2
        exit 1
    fi
}
require packetwyrmd
require pktwyrm
require packetwyrm-proxyd
require libpacketwyrm.so

# Optional helper tools: include if present, warn (do not fail) if not.
OPTIONAL_TOOLS="pw_flash pw_reboot pw_phase3_loopback pw_phase3_forward pw_phase3_punt pw_phase3_inject pw_phase3_modgen pw_phase3_ipv6gen"

# --- derive runtime Depends from ldd ---------------------------------------
# Map the shared objects packetwyrmd links against to their Debian packages.
# We check the three the task calls out (libyaml, libjson-c, libssl) plus
# whatever the binaries actually pull in, then pin reasonable version floors.
echo "==> deriving Depends from ldd $BUILD_DIR/packetwyrmd (+ pktwyrm, proxyd)"
LDD_OUT="$( { ldd "$BUILD_DIR/packetwyrmd" "$BUILD_DIR/pktwyrm" "$BUILD_DIR/packetwyrm-proxyd" 2>/dev/null || true; } )"
printf '%s\n' "$LDD_OUT" | grep '=>' | awk '{print $1}' | sort -u | sed 's/^/      /'

# Explicit floors (Ubuntu/Debian current stable-ish). libssl on 64-bit-time
# Ubuntu is libssl3t64; accept either package name via an alternative.
DEPENDS="libc6, libyaml-0-2 (>= 0.2.1), libjson-c5 (>= 0.15), libssl3 | libssl3t64 (>= 3.0.0)"
echo "    Depends : $DEPENDS"

# --- assemble staging root -------------------------------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pw-deb.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
chmod 0755 "$STAGE"   # mktemp makes 0700; the package root should be 0755
echo "==> staging in $STAGE"

install -d "$STAGE/DEBIAN"
install -d "$STAGE/usr/bin"
install -d "$STAGE/$LIBDIR"
install -d "$STAGE/lib/systemd/system"
install -d "$STAGE/usr/lib/sysusers.d"
install -d "$STAGE/usr/lib/tmpfiles.d"
install -d "$STAGE/etc/packetwyrm"
install -d "$STAGE/usr/share/bash-completion/completions"
install -d "$STAGE/usr/share/zsh/vendor-completions"
install -d "$STAGE/usr/share/man/man1"
install -d "$STAGE/usr/share/man/man8"
install -d "$STAGE/usr/share/packetwyrm/grafana"

# Binaries -> /usr/bin
install -m 0755 "$BUILD_DIR/packetwyrmd"       "$STAGE/usr/bin/packetwyrmd"
install -m 0755 "$BUILD_DIR/pktwyrm"           "$STAGE/usr/bin/pktwyrm"
install -m 0755 "$BUILD_DIR/packetwyrm-proxyd" "$STAGE/usr/bin/packetwyrm-proxyd"

# Optional helper tools.
for t in $OPTIONAL_TOOLS; do
    if [ -f "$BUILD_DIR/$t" ]; then
        install -m 0755 "$BUILD_DIR/$t" "$STAGE/usr/bin/$t"
        echo "    + helper tool: $t"
    else
        echo "    - helper tool not built (skipped): $t"
    fi
done

# Shared library -> /usr/lib/<multiarch>
install -m 0644 "$BUILD_DIR/libpacketwyrm.so" "$STAGE/$LIBDIR/libpacketwyrm.so"

# systemd units: install to /lib/systemd/system, rewriting the ExecStart
# path from /usr/local/sbin (dev install) to /usr/bin (packaged location).
for unit in packetwyrmd.service packetwyrm-proxyd.service; do
    sed 's#/usr/local/sbin/#/usr/bin/#g' "$SCRIPT_DIR/$unit" \
        > "$STAGE/lib/systemd/system/$unit"
    chmod 0644 "$STAGE/lib/systemd/system/$unit"
done

# sysusers / tmpfiles
install -m 0644 "$SCRIPT_DIR/packetwyrm.sysusers"  "$STAGE/usr/lib/sysusers.d/packetwyrm.conf"
install -m 0644 "$SCRIPT_DIR/packetwyrm.tmpfiles"  "$STAGE/usr/lib/tmpfiles.d/packetwyrm.conf"

# Example env config as the conffile. 0640: it may later hold system.secret.
install -m 0640 "$DEB_SRC/packetwyrm.yaml.example" "$STAGE/etc/packetwyrm/packetwyrm.yaml"

# Shell completions
install -m 0644 "$SCRIPT_DIR/completions/pktwyrm.bash" \
    "$STAGE/usr/share/bash-completion/completions/pktwyrm"
install -m 0644 "$SCRIPT_DIR/completions/_pktwyrm" \
    "$STAGE/usr/share/zsh/vendor-completions/_pktwyrm"

# man pages (gzip -9n; -n for reproducibility)
gzip -9nc "$SCRIPT_DIR/man/pktwyrm.1"            > "$STAGE/usr/share/man/man1/pktwyrm.1.gz"
gzip -9nc "$SCRIPT_DIR/man/packetwyrmd.8"        > "$STAGE/usr/share/man/man8/packetwyrmd.8.gz"
gzip -9nc "$SCRIPT_DIR/man/packetwyrm-proxyd.8"  > "$STAGE/usr/share/man/man8/packetwyrm-proxyd.8.gz"
chmod 0644 "$STAGE"/usr/share/man/man*/*.gz

# Grafana dashboard + README
install -m 0644 "$SCRIPT_DIR/grafana/packetwyrm-dashboard.json" \
    "$STAGE/usr/share/packetwyrm/grafana/packetwyrm-dashboard.json"
install -m 0644 "$SCRIPT_DIR/grafana/README.md" \
    "$STAGE/usr/share/packetwyrm/grafana/README.md"

# --- DEBIAN control dir ----------------------------------------------------
sed -e "s#@VERSION@#$VERSION#g" \
    -e "s#@ARCH@#$ARCH#g" \
    -e "s#@DEPENDS@#$DEPENDS#g" \
    "$DEB_SRC/DEBIAN/control.in" > "$STAGE/DEBIAN/control"

install -m 0644 "$DEB_SRC/DEBIAN/conffiles" "$STAGE/DEBIAN/conffiles"
install -m 0755 "$DEB_SRC/DEBIAN/postinst"  "$STAGE/DEBIAN/postinst"
install -m 0755 "$DEB_SRC/DEBIAN/prerm"     "$STAGE/DEBIAN/prerm"
install -m 0755 "$DEB_SRC/DEBIAN/postrm"    "$STAGE/DEBIAN/postrm"

# --- build the .deb --------------------------------------------------------
mkdir -p "$DIST_DIR"
DEB_PATH="$DIST_DIR/packetwyrm_${VERSION}_${ARCH}.deb"
echo "==> dpkg-deb --build --root-owner-group"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB_PATH"

echo
echo "==> dpkg-deb --info $DEB_PATH"
dpkg-deb --info "$DEB_PATH"
echo
echo "==> dpkg-deb --contents $DEB_PATH"
dpkg-deb --contents "$DEB_PATH"

# --- optional lintian ------------------------------------------------------
if command -v lintian >/dev/null 2>&1; then
    echo
    echo "==> lintian (informational; not fatal)"
    lintian "$DEB_PATH" || echo "   (lintian reported issues; not failing the build)"
else
    echo
    echo "==> lintian not installed; skipping lint"
fi

echo
echo "==> built: $DEB_PATH"
