#!/usr/bin/env bash
# End-to-end tests: compiles every test/programs/*.ins with insc_jvm and insc_llvm,
# runs the results with `java` and `lli`, and compares stdout with the .output file.
# Programs in test/bad/ must be rejected with a non-zero exit code.
#
# Usage: test/e2e.sh            (after `make`; needs java, llvm-link and lli on PATH)
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

LLI=${LLI:-lli}
JAVA=${JAVA:-java}
passed=0
failed=0

pass() { passed=$((passed + 1)); printf 'ok      %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAILED  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

# check NAME EXPECTED_FILE ACTUAL_FILE
check() {
  if diff -u "$2" "$3" > "$work/diff"; then pass "$1"; else fail "$1" "$(cat "$work/diff")"; fi
}

for src in "$root"/test/programs/*.ins; do
  name=$(basename "$src" .ins)
  expected="${src%.ins}.output"
  cp "$src" "$work/"

  if "$root/insc_jvm" "$work/$name.ins" 2> "$work/err"; then
    "$JAVA" -cp "$work" "$name" > "$work/$name.jvm.out" 2>&1
    check "jvm   $name" "$expected" "$work/$name.jvm.out"
  else
    fail "jvm   $name (compilation)" "$(cat "$work/err")"
  fi

  if "$root/insc_llvm" "$work/$name.ins" 2> "$work/err"; then
    "$LLI" "$work/$name.bc" > "$work/$name.llvm.out" 2>&1
    check "llvm  $name" "$expected" "$work/$name.llvm.out"
  else
    fail "llvm  $name (compilation)" "$(cat "$work/err")"
  fi
done

for src in "$root"/test/bad/*.ins; do
  name=$(basename "$src" .ins)
  compilers="insc_jvm insc_llvm"
  # a file name that is not a Java identifier only matters for the JVM class name
  [ "$name" = invalid-class-name ] && compilers=insc_jvm
  for compiler in $compilers; do
    if "$root/$compiler" --emit-only "$src" 2> "$work/err"; then
      fail "$compiler rejects $name"
    elif [ ! -s "$work/err" ]; then
      fail "$compiler rejects $name (no error message)"
    else
      pass "$compiler rejects $name: $(head -n1 "$work/err" | sed "s|$root/||")"
    fi
  done
done
rm -f "$root"/test/bad/*.j "$root"/test/bad/*.ll

# Large generated inputs. The first must run (a JVM method is limited to 64 KB
# of bytecode); the second only checks that compilation stays fast, as the
# task requires O(n log n) — so tools are skipped with --emit-only.
# gen_big FILE STATEMENTS DEPTH
gen_big() {
  {
    for i in $(seq 1 "$2"); do echo "v$((i % 300)) = $i * 3 - $((i % 7));"; done
    printf 'v1'; for i in $(seq 1 "$3"); do printf ' - (v%d + 1' $((i % 300)); done
    for i in $(seq 1 "$3"); do printf ')'; done; echo ';'
    printf '1'; for i in $(seq 1 "$3"); do printf ' + %d' $((i % 300)); done; echo
  } > "$1"
}

gen_big "$work/big.ins" 2000 1000
if "$root/insc_jvm" "$work/big.ins" && "$root/insc_llvm" "$work/big.ins"; then
  "$JAVA" -cp "$work" big > "$work/big.jvm.out" 2>&1
  "$LLI" "$work/big.bc" > "$work/big.llvm.out" 2>&1
  check "big program (300 locals, depth 1000): jvm and llvm agree" "$work/big.jvm.out" "$work/big.llvm.out"
else
  fail "big program (compilation)"
fi

gen_big "$work/huge.ins" 200000 20000
for compiler in insc_jvm insc_llvm; do
  start=$(date +%s%N)
  if "$root/$compiler" --emit-only "$work/huge.ins"; then
    pass "$compiler: 200k statements + depth-20k expressions in $(( ($(date +%s%N) - start) / 1000000 )) ms"
  else
    fail "$compiler: huge program"
  fi
done

echo
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]
