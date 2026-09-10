#!/data/data/com.termux/files/usr/bin/bash
#
# install.sh -- install the cline-termux package on Termux/Android (aarch64)
#
# What this does:
#   1. Detects Termux and the aarch64 architecture.
#   2. Installs the glibc runtime dependency (glibc-repo + glibc-runner) if
#      the glibc loader is not already present.
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
# 3. Ensure required tools exist (install them ourselves if missing)
# ---------------------------------------------------------------------------
for tool in curl tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "==> Installing missing tool: $tool"
        DEBIAN_FRONTEND=noninteractive pkg install -y "$tool" || {
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
# 4. Install runtime dependencies if required (glibc loader + libraries)
# ---------------------------------------------------------------------------
GLIBC_LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
GLIBC_LIBC="$PREFIX/glibc/lib/libc.so.6"

if [ ! -x "$GLIBC_LD" ]; then
    echo "==> Refreshing package index..."
    DEBIAN_FRONTEND=noninteractive pkg update -y >/dev/null 2>&1 || true
    echo "==> Installing glibc runtime (glibc-repo, glibc-runner) ..."
    DEBIAN_FRONTEND=noninteractive pkg install -y glibc-repo || {
        echo "ERROR: failed to install glibc-repo (check network / Termux repos)" >&2
        exit 1
    }
    DEBIAN_FRONTEND=noninteractive pkg install -y glibc-runner || {
        echo "ERROR: failed to install glibc-runner" >&2
        exit 1
    }
fi

# Repair path: apt/dpkg may consider glibc "installed" while its files are
# actually missing (interrupted install, manual cleanup, partial removal).
# Force a reinstall until the loader really exists on disk.
if [ ! -x "$GLIBC_LD" ]; then
    echo "==> glibc files missing although packages are registered; repairing..."
    DEBIAN_FRONTEND=noninteractive pkg reinstall -y glibc glibc-runner 2>/dev/null || true
fi
if [ ! -x "$GLIBC_LD" ]; then
    echo "==> Still missing; purging and reinstalling glibc packages..."
    dpkg --purge glibc glibc-runner glibc-repo >/dev/null 2>&1 || true
    rm -rf "$PREFIX/glibc"
    DEBIAN_FRONTEND=noninteractive pkg update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive pkg install -y glibc-repo glibc-runner || {
        echo "ERROR: failed to install glibc-repo / glibc-runner" >&2
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