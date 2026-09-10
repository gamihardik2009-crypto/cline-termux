#!/data/data/com.termux/files/usr/bin/bash
#
# uninstall.sh -- remove the cline-termux package from Termux
#
# Removes only the files that install.sh created:
#   $PREFIX/bin/cline
#   $PREFIX/lib/cline/{cline,bun-termux,bun-shim.so,tmp/}
#
# User data in ~/.cline is preserved by default.
# Pass --purge-data to also delete ~/.cline.
#
# Usage:  bash uninstall.sh [--purge-data]
#
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
CLINE_LIB="$PREFIX/lib/cline"

removed=0

# Only remove the launcher if it is ours (contains the cline-termux marker).
if [ -f "$PREFIX/bin/cline" ]; then
    if grep -q 'cline-termux' "$PREFIX/bin/cline" 2>/dev/null; then
        rm -f "$PREFIX/bin/cline"
        removed=1
    else
        echo "WARN: $PREFIX/bin/cline is not the cline-termux launcher; leaving it." >&2
    fi
fi

# Remove runtime files (only paths we own).
rm -rf "$CLINE_LIB"

# Optional user-data purge (off by default).
if [ "${1:-}" = "--purge-data" ]; then
    rm -rf "${HOME:-}/.cline"
    echo "Removed ~/.cline user data."
fi

if [ "$removed" = "1" ] || [ ! -e "$CLINE_LIB" ]; then
    echo "Cline (cline-termux) uninstalled."
else
    echo "Cline (cline-termux) uninstalled (launcher was not ours; removed runtime only)."
fi
echo
echo "Note: the glibc packages (glibc-repo, glibc-runner) were left installed."
echo "      Remove them with  pkg remove glibc-runner glibc-repo  if no longer needed."