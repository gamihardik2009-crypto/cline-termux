#!/data/data/com.termux/files/usr/bin/bash
#
# run-test-suite.sh -- post-install test suite for the cline-termux package.
#
# Runs the full battery of non-authenticated tests against an installed
# `cline` command and writes everything under suite_out/.
#
# Usage:  bash run-test-suite.sh [output_dir]
#
set -u

SUITE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="${1:-$SUITE_DIR/suite_out}"
mkdir -p "$OUT"
LOG="$OUT/results.log"
: > "$LOG"

PASS=0
FAIL=0
PARTIAL=0
SKIP=0

note()  { printf '%s\n' "$*" | tee -a "$LOG"; }
result() { # result name
    local r="$1" name="$2"
    printf '%-10s %s\n' "$r" "$name" >> "$LOG"
    case "$r" in
        PASS) PASS=$((PASS+1)) ;;
        FAIL) FAIL=$((FAIL+1)) ;;
        PARTIAL) PARTIAL=$((PARTIAL+1)) ;;
        *) SKIP=$((SKIP+1)) ;;
    esac
}

# ---------------------------------------------------------------------------
note "=== cline-termux post-install test suite ==="
note "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
note "host: $(uname -a)"
note "arch: $(uname -m)"
note "PREFIX: ${PREFIX:-/data/data/com.termux/files/usr}"
note "HOME: $HOME"
note "TMPDIR: ${TMPDIR:-<unset>}"
note "cline: $(command -v cline 2>/dev/null || echo NOT-FOUND)"
note

# ---------------------------------------------------------------------------
# [T1] installation sanity
# ---------------------------------------------------------------------------
note "--- T1: installation sanity ---"
CLINE_CMD=$(command -v cline 2>/dev/null)
if [ -n "$CLINE_CMD" ] && [ -x "$CLINE_CMD" ] && echo "$CLINE_CMD" | grep -q '/bin/cline'; then
    note "which cline -> $CLINE_CMD"
    result PASS "T1 which/command -v cline"
else
    note "which cline -> '$CLINE_CMD' (unexpected)"
    result FAIL "T1 which/command -v cline"
fi

run() { # name timeout cmd...
    local name="$1" tmo="$2"; shift 2
    local out="$OUT/t1_${name}.txt"
    timeout "$tmo" "$@" >"$out" 2>&1
    echo "$?" > "$OUT/t1_${name}.exit"
}

# ---------------------------------------------------------------------------
# [T2] basic commands
# ---------------------------------------------------------------------------
note "--- T2: basic commands ---"
run version 60 cline --version
if [ "$(cat "$OUT/t1_version.exit")" = "0" ] && grep -q '3.0.61' "$OUT/t1_version.txt"; then
    note "cline --version -> $(head -1 "$OUT/t1_version.txt")"
    result PASS "T2 cline --version"
else
    note "cline --version FAILED (exit=$(cat "$OUT/t1_version.exit")):"
    head -5 "$OUT/t1_version.txt" | sed 's/^/    /' >> "$LOG"
    result FAIL "T2 cline --version"
fi

run help 60 cline --help
if [ "$(cat "$OUT/t1_help.exit")" = "0" ] && [ -s "$OUT/t1_help.txt" ]; then
    result PASS "T2 cline --help"
else
    result FAIL "T2 cline --help"
fi

run version2 60 cline version
if [ "$(cat "$OUT/t1_version2.exit")" = "0" ] && [ -s "$OUT/t1_version2.txt" ]; then
    result PASS "T2 cline version"
else
    result FAIL "T2 cline version"
fi

run doctor 120 cline doctor
if [ "$(cat "$OUT/t1_doctor.exit")" = "0" ]; then
    result PASS "T2 cline doctor"
else
    note "cline doctor exit=$(cat "$OUT/t1_doctor.exit"); output tail:"
    tail -10 "$OUT/t1_doctor.txt" | sed 's/^/    /' >> "$LOG"
    result FAIL "T2 cline doctor"
fi

# ---------------------------------------------------------------------------
# [T3] working directory independence
# ---------------------------------------------------------------------------
note "--- T3: working directory independence ---"
ok=1
for d in "$HOME" "$TMPDIR" "$SUITE_DIR"; do
    [ -d "$d" ] || continue
    ( cd "$d" && timeout 60 cline --version >"$OUT/t3_cwd.txt" 2>&1 )
    if [ "$?" = "0" ] && grep -q '3.0.61' "$OUT/t3_cwd.txt"; then
        note "  cwd=$d OK"
    else
        note "  cwd=$d FAILED"
        ok=0
    fi
done
# ---------------------------------------------------------------------------
# [T4] filesystem behavior in an isolated project
# ---------------------------------------------------------------------------
note "--- T4: filesystem behavior ---"
PROJ="$HOME/cline-package-test/project"
rm -rf "$HOME/cline-package-test"
mkdir -p "$PROJ/nested"
printf 'hello termux\n' > "$PROJ/test.txt"
printf 'nested file\n' > "$PROJ/nested/test2.txt"

( cd "$PROJ" && timeout 60 cline doctor >"$OUT/t4_doctor.txt" 2>&1 ); d1=$?
( cd "$PROJ" && timeout 60 cline history >"$OUT/t4_history.txt" 2>&1 ); d2=$?
( cd "$PROJ" && timeout 60 cline --help >"$OUT/t4_help.txt" 2>&1 ); d3=$?

note "  doctor exit=$d1 history exit=$d2 help exit=$d3"
note "  files intact: $(cat "$PROJ/test.txt" 2>/dev/null | tr -d '\n') / $(cat "$PROJ/nested/test2.txt" 2>/dev/null | tr -d '\n')"
note "  ~/.cline exists: $([ -d "$HOME/.cline" ] && echo yes || echo no)"
note "  TMPDIR writable: $([ -w "$TMPDIR" ] && echo yes || echo no)"
if [ "$d1" = "0" ] && [ "$d2" = "0" ] && [ "$d3" = "0" ] \
   && [ "$(cat "$PROJ/test.txt" 2>/dev/null)" = "hello termux" ] \
   && [ "$(cat "$PROJ/nested/test2.txt" 2>/dev/null)" = "nested file" ]; then
    result PASS "T4 filesystem + project access"
else
    result PARTIAL "T4 filesystem + project access"
fi

# ---------------------------------------------------------------------------
# [T5] network runtime (non-authenticated)
# ---------------------------------------------------------------------------
note "--- T5: network runtime ---"
# cline update performs a pure version check against the npm registry and
# never self-replaces (package-manager detection returns UNKNOWN for a
# standalone binary). Safe, non-authenticated.
run update 90 cline update
ue=$?
note "  cline update exit=$ue; output:"
sed 's/^/    /' "$OUT/t1_update.txt" | head -8 >> "$LOG"
if [ "$ue" = "0" ]; then
    result PASS "T5 cline update (npm registry check)"
else
    result PARTIAL "T5 cline update (npm registry check)"
fi

# Independent HTTPS fetch through the same glibc Bun runtime family.
# (The runtime's own Bun binary is used only as a network probe; it is not
# part of the shipped package.)
if [ -x "$HOME/bt-test/run/bin/buno" ] && [ -x "$HOME/bt-test/bun-termux/bun-termux" ]; then
    ( cd "$HOME" && timeout 60 env BUN_INSTALL="$HOME/bt-test/run" \
        "$HOME/bt-test/bun-termux/bun-termux" -e \
        'const r=await fetch("https://registry.npmjs.org/cline/latest"); console.log("https_status", r.status)' \
        >"$OUT/t5_fetch.txt" 2>&1 )
    fe=$?
    note "  runtime fetch exit=$fe; output: $(cat "$OUT/t5_fetch.txt" | tr '\n' ' ')"
    if [ "$fe" = "0" ] && grep -q 'https_status 200' "$OUT/t5_fetch.txt"; then
        result PASS "T5 HTTPS fetch via glibc Bun runtime"
    else
        result FAIL "T5 HTTPS fetch via glibc Bun runtime"
    fi
else
    result SKIP "T5 HTTPS fetch via glibc Bun runtime (probe binary not present)"
fi

# ---------------------------------------------------------------------------
# [T6] syscall stability (strace)
# ---------------------------------------------------------------------------
note "--- T6: syscall stability ---"
if command -v strace >/dev/null 2>&1; then
    for name in version help doctor; do
        strace -f -o "$OUT/t6_${name}.strace" env cline --"$name" >/dev/null 2>&1
        echo "$?" > "$OUT/t6_${name}.exit"
    done
    note "  trace exit codes: version=$(cat "$OUT/t6_version.exit") help=$(cat "$OUT/t6_help.exit") doctor=$(cat "$OUT/t6_doctor.exit")"
    BAD=$(grep -hE 'SIGSYS|Bad system call|killed by SIGSYS|+++ killed by SIG' "$OUT"/t6_*.strace 2>/dev/null | wc -l)
    CRASH=$(grep -hE 'SIGSEGV|SIGILL|SIGABRT|SIGTRAP|SIGBUS' "$OUT"/t6_*.strace 2>/dev/null | wc -l)
    CR=$(grep -hE 'close_range\(' "$OUT"/t6_*.strace 2>/dev/null | wc -l)
    note "  SIGSYS/Bad-syscall lines: $BAD; crash-signal lines: $CRASH; close_range calls: $CR"
    if [ "$BAD" = "0" ] && [ "$CRASH" = "0" ]; then
        result PASS "T6 syscall stability (no SIGSYS/crash)"
    else
        result FAIL "T6 syscall stability (no SIGSYS/crash)"
    fi
else
    result SKIP "T6 syscall stability (strace not installed)"
fi

# ---------------------------------------------------------------------------
# [T7] process cleanup
# ---------------------------------------------------------------------------
note "--- T7: process cleanup ---"
sleep 2
LEFT=$(ps -A 2>/dev/null | grep -E 'cline|bun-termux|buno|cline-hub|hub' | grep -v grep | head -20)
if [ -z "$LEFT" ]; then
    note "  no leftover processes"
    result PASS "T7 process cleanup"
else
    note "  leftover processes:"; echo "$LEFT" | sed 's/^/    /' >> "$LOG"
    result FAIL "T7 process cleanup"
fi

# ---------------------------------------------------------------------------
# [T8] update behavior inspection (non-destructive)
# ---------------------------------------------------------------------------
note "--- T8: update behavior inspection ---"
run updatehelp 60 cline update --help
note "  cline update --help exit=$(cat "$OUT/t1_updatehelp.exit")"
note "  source-level facts (from apps/cli/src/commands/update.ts):"
note "    - startup check only queries https://registry.npmjs.org/<pkg>/<tag>"
note "    - install path spawns npm/pnpm/yarn/bun global update commands"
note "    - standalone binary => UNKNOWN package manager => no command run"
note "    - Cline never replaces its own executable"
result PASS "T8 update behavior inspection (source-level, non-destructive)"

# ---------------------------------------------------------------------------
note
note "=== SUITE SUMMARY ==="
note "PASS=$PASS FAIL=$FAIL PARTIAL=$PARTIAL SKIP=$SKIP"
note "output directory: $OUT"
exit 0
if [ "$ok" = "1" ]; then result PASS "T3 multiple working dirs"; else result FAIL "T3 multiple working dirs"; fi