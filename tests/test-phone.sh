#!/usr/bin/env bash
# Tests for the checks phone/setup.sh makes before it changes anything.
# Android's commands are replaced by the stand-ins in tests/stubs.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$REPO/versions.env" "$WORK/"
pass=0 fail=0

# expect CODE "description" [VAR=value ...] [-- flags]
expect() {
  local want=$1 what=$2; shift 2
  local vars=() flags=()
  while [ $# -gt 0 ]; do
    if [ "$1" = -- ]; then shift; flags=("$@"); break; fi
    vars+=("$1"); shift
  done
  rm -rf "$WORK/lock"
  local out rc
  out=$(env PATH="$REPO/tests/stubs:$PATH" CCA_DIR="$WORK" ${vars[@]+"${vars[@]}"} \
    sh "$REPO/phone/setup.sh" preflight ${flags[@]+"${flags[@]}"} 2>&1)
  rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "FAIL $what: expected $want, got $rc"; echo "$out" | sed 's/^/    | /'; fi
}

# Phones that must be refused before anything else is looked at.
expect 20 "Android too old"            F_SDK=23
expect 21 "32-bit phone"               F_ABI64=
expect 22 "x86 device"                 F_ABI64=x86_64 F_ABI=x86_64
expect 23 "secondary user"             F_USER=10
expect 21 "32-bit wins over Termux state" F_ABI64= F_TERMUX=foreign

# No Termux yet.
expect 3  "fresh phone needs the Termux app"
expect 24 "not enough free space"      F_FREE_KB=1000000
expect 25 "no internet"                F_NET=none
expect 12 "mobile data needs a yes"    F_NET=mobile
expect 3  "mobile data after a yes"    F_NET=mobile -- --allow-mobile-data
expect 3  "unknown network type carries on" F_NET=unknown

# Termux already there.
expect 11 "Play Store / F-Droid Termux needs REPLACE"  F_TERMUX=foreign
expect 3  "after REPLACE the app is needed"            F_TERMUX=foreign -- --replace-termux
expect 26 "debuggable but not drivable"                F_TERMUX=broken
expect 10 "someone's own Termux needs a yes"           F_TERMUX=unmarked
expect 0  "someone's own Termux after a yes"           F_TERMUX=unmarked -- --use-existing-termux
expect 0  "our Termux, interrupted install"            F_TERMUX=ours
expect 0  "Termux installed but never opened"          F_TERMUX=empty
expect 0  "finished install skips space and network checks" F_TERMUX=ours F_INSTALLED=1 F_FREE_KB=1000 F_NET=none
expect 24 "unfinished install still checks space"      F_TERMUX=ours F_FREE_KB=1000

echo "phone checks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
