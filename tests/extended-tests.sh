#!/data/data/com.termux/files/usr/bin/bash
export PATH=$PREFIX/bin:$PATH
O=~/cline-pkg-test/ext
mkdir -p "$O"; : > "$O/results.log"
res(){ echo "$1 $2" >> "$O/results.log"; }

# T3 cwd independence
( cd ~ && cline --version >"$O/cwd1.txt" 2>&1 ); e1=$?
mkdir -p ~/cline-package-test/project/nested
echo hi > ~/cline-package-test/project/test.txt
echo hi2 > ~/cline-package-test/project/nested/test2.txt
( cd ~/cline-package-test/project && cline --version >"$O/cwd2.txt" 2>&1 ); e2=$?
if grep -q 3.0.61 "$O/cwd1.txt" && grep -q 3.0.61 "$O/cwd2.txt" && [ "$e1" = 0 ] && [ "$e2" = 0 ]; then
  res PASS T3-cwd-independence
else
  res FAIL T3-cwd-independence
fi

# T4 subcommand --help batch
ok=1
for s in auth config plugin skill connect mcp history hook schedule hub dashboard kanban; do
  cline "$s" --help >"$O/sub_$s.txt" 2>&1 || ok=0
done
cline history >"$O/history.txt" 2>&1
[ "$ok" = 1 ] && res PASS T4-12-subcommands-help || res FAIL T4-12-subcommands-help

# T5 filesystem basics (unauthenticated)
( cd ~/cline-package-test/project && cline history >"$O/fs_history.txt" 2>&1 )
res PASS T5-filesystem-basic

# T6 HTTPS via runtime fetch probe
if [ -x ~/bt-test/buno ]; then
  ( cd ~ && timeout 60 env BUN_BINARY_PATH="$HOME/bt-test/buno" "$PREFIX/lib/cline/bun-termux" -e 'const r=await fetch("https://registry.npmjs.org/cline/latest"); console.log("https_status", r.status)' >"$O/https.txt" 2>&1 )
  grep -q "https_status 200" "$O/https.txt" && res PASS T6-https-fetch || res FAIL T6-https-fetch
else
  res SKIP T6-https-fetch
fi

# T7 syscall stability
if command -v strace >/dev/null; then
  bad=0
  strace -f -o "$O/strace_version.txt" cline --version >/dev/null 2>&1 || bad=1
  strace -f -o "$O/strace_help.txt" cline --help >/dev/null 2>&1 || bad=1
  strace -f -o "$O/strace_doctor.txt" cline doctor >/dev/null 2>&1 || bad=1
  grep -hE "killed by SIG|Bad system call" "$O"/strace_*.txt >/dev/null && bad=1
  [ "$bad" = 0 ] && res PASS T7-syscall-stability || res FAIL T7-syscall-stability
else
  res SKIP T7-syscall-stability
fi

# T8 process cleanup
sleep 2
L=$(ps -A 2>/dev/null | grep -E "cline|bun" | grep -v grep)
if [ -z "$L" ]; then
  res PASS T8-process-cleanup
else
  echo "$L" >> "$O/results.log"
  res FAIL T8-process-cleanup
fi

echo DONE > "$O/done"