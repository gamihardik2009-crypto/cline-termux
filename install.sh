#!/data/data/com.termux/files/usr/bin/bash
#
# install.sh -- install the cline-termux package on Termux/Android (aarch64)
#
# What this does:
#   1. Detects Termux and the aarch64 architecture.
#   2. Configures the official Termux glibc repository (via the 'glibc-repo'
#      package, or by writing its sources.list.d entry directly on fresh
#      installs) and installs the glibc runtime (glibc-runner) if the glibc
#      loader is not already present.
#   3. Verifies the integrity of the bundled runtime files (SHA-256).
#   4. Installs the runtime under $PREFIX/lib/cline and the `cline` launcher
#      under $PREFIX/bin/cline.
#
# It is idempotent: re-running it re-installs the same files.
#
# Usage:  bash install.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Locate the package directory (the directory this script lives in).
# ---------------------------------------------------------------------------
PKG_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# ---------------------------------------------------------------------------
# 1. Detect Termux
# ---------------------------------------------------------------------------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
if [ ! -d "$PREFIX" ] || [ ! -d "$PREFIX/bin" ]; then
    echo "ERROR: Termux prefix not found at $PREFIX" >&2
    echo "       This package installs into Termux on Android only." >&2
    exit 1
fi
if ! command -v pkg >/dev/null 2>&1 && ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: neither 'pkg' nor 'apt-get' found -- Termux is required" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Detect architecture (only aarch64/arm64 is supported)
# ---------------------------------------------------------------------------
ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64)
        ;;
    *)
        echo "ERROR: unsupported architecture: $ARCH (only aarch64/arm64)" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# 3. Package-manager helpers (also used to heal a missing main mirror)
# ---------------------------------------------------------------------------
APT="pkg"
command -v pkg >/dev/null 2>&1 || APT=apt-get

# Run a package-manager command quietly; dump its output only on failure.
run_pkg() {
    local _log
    _log=$(mktemp "${TMPDIR:-/tmp}/cline-pkg.XXXXXX") || return 1
    if DEBIAN_FRONTEND=noninteractive "$@" >"$_log" 2>&1; then
        rm -f "$_log"
        return 0
    fi
    echo "--- failed command: $* ---" >&2
    sed 's/^/    /' "$_log" >&2
    rm -f "$_log"
    return 1
}

backup_file() { # backup_file path  (timestamped .bak copy; no-op if absent)
    [ -e "$1" ] || return 0
    cp -f "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)"
}

# Restore the factory main mirror ONLY when sources.list is missing or has no
# active 'deb' line (never touches a user-configured mirror).
ensure_main_mirror() {
    grep -qs '^[[:space:]]*deb ' "$PREFIX/etc/apt/sources.list" 2>/dev/null && return 0
    echo "==> main Termux mirror not configured; restoring default sources.list"
    backup_file "$PREFIX/etc/apt/sources.list"
    mkdir -p "$PREFIX/etc/apt"
    printf '# The main termux repository, with cloudflare cache\ndeb https://packages-cf.termux.dev/apt/termux-main/ stable main\n' \
        > "$PREFIX/etc/apt/sources.list"
    run_pkg "$APT" update -y || true
}

# ---------------------------------------------------------------------------
# 3b. Ensure required tools exist (install them ourselves if missing)
# ---------------------------------------------------------------------------
for tool in curl tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        ensure_main_mirror
        echo "==> Installing missing tool: $tool"
        run_pkg "$APT" install -y "$tool" || {
            echo "ERROR: failed to install $tool" >&2
            exit 1
        }
    fi
done
for tool in bash uname sed sha256sum mkdir install cp chmod rm dd od tr head grep; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool missing: $tool" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# 3b. Remove any previous/conflicting cline installations
#     (our own past install, or leftovers from other install methods)
# ---------------------------------------------------------------------------
if [ -e "$PREFIX/bin/cline" ]; then
    echo "==> Removing previous cline launcher ($PREFIX/bin/cline)"
    rm -f "$PREFIX/bin/cline"
fi
if [ -d "$PREFIX/lib/cline" ]; then
    echo "==> Removing previous cline runtime ($PREFIX/lib/cline)"
    rm -rf "$PREFIX/lib/cline"
fi

# ---------------------------------------------------------------------------
# 4. Ensure the Termux glibc repository and runtime (glibc loader + libraries)
# ---------------------------------------------------------------------------
# Cline's binary needs the glibc loader shipped by Termux's glibc repository.
# A fresh Termux has neither the repository nor its packages, and some installs
# also lack a working main mirror ("No mirror or mirror group selected"),
# which used to abort this installer with:
#     E: Unable to locate package glibc-repo
#
# This block, in order:
#   a. does nothing when the glibc loader already exists (idempotent);
#   b. ensures $PREFIX/etc/apt/sources.list.d/glibc.list exists -- preferring
#      the official 'glibc-repo' package (from the main Termux repo) and, if
#      that is impossible, writing the exact repository line that package
#      installs (no bundled binaries);
#   c. restores the default main mirror ONLY when sources.list is missing or
#      has no active deb line (never touches a user-configured mirror);
#   d. refreshes the package index;
#   e. installs glibc-runner (which pulls in glibc);
#   f. on failure, names the failing layer (repository / mirror+network /
#      package manager state).  Unrelated packages such as xdg-utils or
#      icewm are never purged or reconfigured by this installer.
# ---------------------------------------------------------------------------
GLIBC_LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
GLIBC_LIBC="$PREFIX/glibc/lib/libc.so.6"

GLIBC_LIST_DIR="$PREFIX/etc/apt/sources.list.d"
GLIBC_LIST="$GLIBC_LIST_DIR/glibc.list"
# Exactly what the official 'glibc-repo' package (termux-packages) writes.
GLIBC_LIST_CONTENT='# The glibc termux repository, with cloudflare cache
deb https://packages-cf.termux.dev/apt/termux-glibc/ glibc stable
# The glibc termux repository, without cloudflare cache
# deb https://packages.termux.dev/apt/termux-glibc/ glibc stable'

glibc_repo_configured() {
    [ -f "$GLIBC_LIST" ] && grep -qs '^[[:space:]]*deb .*termux-glibc' "$GLIBC_LIST"
}

write_glibc_list() { # write the official glibc repo definition ourselves
    mkdir -p "$GLIBC_LIST_DIR"
    backup_file "$GLIBC_LIST"
    printf '%s\n' "$GLIBC_LIST_CONTENT" > "$GLIBC_LIST"
}

if [ ! -x "$GLIBC_LD" ]; then
    echo "==> glibc runtime not found; setting up the Termux glibc repository..."

    # -- 4b. make sure the glibc APT repository is configured ----------------
    if glibc_repo_configured; then
        echo "==> glibc repository already configured: $GLIBC_LIST"
    else
        # Preferred path: the official bootstrap package from the main repo
        # (it writes glibc.list and refreshes the index in its postinst).
        if run_pkg "$APT" install -y glibc-repo; then
            echo "==> glibc repository configured via the glibc-repo package"
        fi
        if ! glibc_repo_configured; then
            # The main mirror may be missing entirely (fresh/broken Termux);
            # restore factory defaults only when there is no active deb line.
            ensure_main_mirror
            run_pkg "$APT" install -y glibc-repo || true
            if ! glibc_repo_configured; then
                # Last resort: write the repository file directly, byte-for-byte
                # identical to what the official glibc-repo package installs.
                echo "==> adding the glibc repository directly ($GLIBC_LIST)"
                write_glibc_list
            fi
        fi
    fi

    # -- 4d. refresh the package index ---------------------------------------
    # Tolerate partial failures: a broken main mirror must not abort us if the
    # glibc repository index was fetched successfully.
    echo "==> Refreshing package index..."
    if ! run_pkg "$APT" update -y; then
        echo "WARN: package index refresh failed for at least one repository;" >&2
        echo "      continuing (the glibc repository may still be usable)." >&2
    fi
    # -- 4e. install the glibc runtime ---------------------------------------
    if ! run_pkg "$APT" install -y glibc-runner; then
        echo "ERROR: failed to install the glibc runtime (glibc-runner)." >&2
        if ! glibc_repo_configured; then
            echo "       Cause: the glibc repository is not configured." >&2
            echo "       Expected repo file: $GLIBC_LIST" >&2
            echo "       Re-run install.sh; if it persists, add the repo line:" >&2
            echo "         deb https://packages-cf.termux.dev/apt/termux-glibc/ glibc stable" >&2
        elif ! curl -fsL --max-time 20 -o /dev/null \
                https://packages-cf.termux.dev/apt/termux-glibc/dists/glibc/InRelease; then
            echo "       Cause: the glibc repository is unreachable (network/mirror)." >&2
            echo "       Check your internet connection, or refresh mirrors with:" >&2
            echo "         termux-change-repo" >&2
        else
            echo "       Cause: the package manager state looks broken," >&2
            echo "       or the index refresh was skipped/failed." >&2
            echo "       Try:  pkg update && pkg install -y glibc-runner" >&2
            echo "       Or:   dpkg --configure -a" >&2
            echo "       (This installer never removes unrelated packages.)" >&2
        fi
        exit 1
    fi
    # Best effort: also register the repository package with dpkg when the
    # main repo is usable (keeps future pkg upgrades managing glibc.list).
    DEBIAN_FRONTEND=noninteractive "$APT" install -y glibc-repo >/dev/null 2>&1 || true
fi

# Repair path: apt/dpkg may consider glibc "installed" while its files are
# actually missing (interrupted install, manual cleanup, partial removal).
# Force a reinstall until the loader really exists on disk.
if [ ! -x "$GLIBC_LD" ]; then
    echo "==> glibc files missing although packages are registered; repairing..."
    run_pkg "$APT" reinstall -y glibc glibc-runner || true
fi
if [ ! -x "$GLIBC_LD" ]; then
    echo "==> Still missing; purging and reinstalling the glibc packages..."
    # NOTE: only our own glibc packages are purged here.  IMPORTANT: the
    # 'glibc-repo' package owns glibc.list, so purging it removes the repo
    # definition -- restore the file before reinstalling anything.
    dpkg --purge glibc glibc-runner glibc-repo >/dev/null 2>&1 || true
    rm -rf "$PREFIX/glibc"
    glibc_repo_configured || write_glibc_list
    run_pkg "$APT" update -y || true
    run_pkg "$APT" install -y glibc-runner || {
        echo "ERROR: failed to install glibc-runner" >&2
        exit 1
    }
fi
if [ ! -x "$GLIBC_LD" ]; then
    echo "ERROR: glibc loader still missing: $GLIBC_LD" >&2
    echo "       Try:  pkg install -y glibc-repo glibc-runner" >&2
    exit 1
fi
if [ ! -e "$GLIBC_LIBC" ]; then
    echo "ERROR: glibc libc.so.6 missing under $PREFIX/glibc/lib" >&2
    exit 1
fi
echo "==> glibc runtime OK: $GLIBC_LD"

# ---------------------------------------------------------------------------
# 5. Runtime components
# ---------------------------------------------------------------------------
# bun-termux wrapper + shim are bundled in this repo (small, MIT-licensed).
# The large Cline binary is downloaded from the official npm registry so the
# repo stays small. Its SHA-256 is pinned below for integrity.
RUNTIME_DIR="$PKG_DIR/runtime"

for f in bun-termux bun-shim.so; do
    if [ ! -f "$RUNTIME_DIR/$f" ]; then
        echo "ERROR: bundled runtime file missing: $RUNTIME_DIR/$f" >&2
        exit 1
    fi
    MAGIC=$(dd if="$RUNTIME_DIR/$f" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$MAGIC" != "7f454c46" ]; then
        echo "ERROR: $RUNTIME_DIR/$f is not an ELF binary" >&2
        exit 1
    fi
done
if [ -f "$RUNTIME_DIR/SHA256SUMS" ]; then
    if ! ( cd "$RUNTIME_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
        echo "ERROR: SHA-256 integrity check of bundled runtime failed" >&2
        exit 1
    fi
    echo "==> bundled runtime integrity OK"
fi

# ---------------------------------------------------------------------------
# 5b. Download the Cline CLI binary from npm (with pinned checksum)
# ---------------------------------------------------------------------------
CLINE_VERSION="3.0.61"
CLINE_NPM_PKG="@cline/cli-linux-arm64"
CLINE_NPM_TGZ_SHA256="80e5b4de8b83c8abea6c652ca7be104b0f17c6ba12f044ecbca5b60d72253466"
CLINE_ELF_SHA256="e99de9f5fdf9438c093386b9f1dfa2fcbca08ddc01c2b1dbaa35c7ba27d9026d"
CLINE_TGZ_URL="https://registry.npmjs.org/${CLINE_NPM_PKG}/-/cli-linux-arm64-${CLINE_VERSION}.tgz"

CLINE_LIB="$PREFIX/lib/cline"
DL_DIR="$CLINE_LIB/.download"
mkdir -p "$DL_DIR"
TGZ="$DL_DIR/cline-${CLINE_VERSION}.tgz"

if [ -f "$CLINE_LIB/cline" ]; then
    got=$(sha256sum "$CLINE_LIB/cline" | awk '{print $1}')
    if [ "$got" = "$CLINE_ELF_SHA256" ]; then
        echo "==> Cline ${CLINE_VERSION} already installed (checksum OK)"
    else
        echo "==> Existing Cline binary differs; re-downloading..."
        rm -f "$CLINE_LIB/cline"
    fi
fi

if [ ! -f "$CLINE_LIB/cline" ]; then
    echo "==> Downloading Cline ${CLINE_VERSION} from npm (~52 MB)..."
    for tool in curl tar; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "ERROR: required tool missing: $tool (pkg install $tool)" >&2
            exit 1
        }
    done
    echo "==> Downloading Cline ${CLINE_VERSION} from npm (~52 MB)..."
    dl_ok=0
    for attempt in 1 2 3 4 5; do
        if curl -fSL --retry 5 --retry-all-errors --retry-delay 3 -C - \
             -o "$TGZ" "$CLINE_TGZ_URL"; then
            dl_ok=1
            break
        fi
        echo "==> Download attempt $attempt failed; retrying (resume)..."
        sleep 3
    done
    if [ "$dl_ok" != "1" ]; then
        echo "ERROR: download failed after retries: $CLINE_TGZ_URL" >&2
        echo "       Check your internet connection and re-run: bash install.sh" >&2
        exit 1
    fi
    got=$(sha256sum "$TGZ" | awk '{print $1}')
    if [ "$got" != "$CLINE_NPM_TGZ_SHA256" ]; then
        echo "ERROR: checksum mismatch for downloaded Cline package" >&2
        echo "       expected: $CLINE_NPM_TGZ_SHA256" >&2
        echo "       got:      $got" >&2
        rm -rf "$DL_DIR"
        exit 1
    fi
    echo "==> Download integrity OK"
    tar -xzf "$TGZ" -C "$DL_DIR" package/bin/cline
    install -m 0755 "$DL_DIR/package/bin/cline" "$CLINE_LIB/cline"
    rm -rf "$DL_DIR"
fi
CLINE_LIB="$PREFIX/lib/cline"
mkdir -p "$CLINE_LIB"

install -m 0755 "$RUNTIME_DIR/bun-termux"  "$CLINE_LIB/bun-termux"
install -m 0644 "$RUNTIME_DIR/bun-shim.so" "$CLINE_LIB/bun-shim.so"
rm -rf "$DL_DIR"

# Render the launcher template with the actual prefix, then install it.
sed "1s|@PREFIX@|$PREFIX|" "$PKG_DIR/bin/cline" > "$PREFIX/bin/cline"
chmod 0755 "$PREFIX/bin/cline"

# Sanity: the launcher's interpreter must exist.
SHEBANG=$(head -n1 "$PREFIX/bin/cline" | sed 's|^#!||')
if [ -z "$SHEBANG" ] || [ ! -x "$SHEBANG" ]; then
    echo "ERROR: launcher interpreter not found: $SHEBANG" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
echo
echo "==> Installed:"
echo "      $PREFIX/bin/cline                 (launcher)"
echo "      $CLINE_LIB/cline                  (Cline ELF)"
echo "      $CLINE_LIB/bun-termux             (runtime wrapper)"
echo "      $CLINE_LIB/bun-shim.so            (runtime shim)"
echo
echo "    Cline binary SHA-256:"
sha256sum "$CLINE_LIB/cline" | sed 's/^/      /'
echo
echo "    Try:  cline --version"
echo "          cline --help"
echo "          cline"