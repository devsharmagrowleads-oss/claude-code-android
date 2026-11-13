#!/usr/bin/env bash
# Tests for the laptop entry points, run against tests/fake-adb (no phone needed).
#   tests/test-entry.sh sh    tests install.sh
#   tests/test-entry.sh ps    tests install.ps1 (Windows, from Git Bash)
set -u
KIND=${1:-sh}
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0

# Each test runs a fresh copy of the installer in its own folder.
setup() {
  T=$WORK/$1; mkdir -p "$T/repo/phone" "$T/adb"
  cp "$REPO/install.sh" "$REPO/install.ps1" "$REPO/versions.env" "$T/repo/"
  cp "$REPO"/phone/*.sh "$T/repo/phone/"
  export FAKE_ADB_DIR=$T/adb
  printf 'SERIAL1\tdevice\n' > "$T/adb/devices.1"
  unset CCA_TERMUX_APK_URL
}

# run "stdin text" [installer args]  -> output in $OUT, exit code in $RC
run() {
  local input=$1; shift
  if [ "$KIND" = ps ]; then
    export CCA_TEST_BASH; CCA_TEST_BASH=$(cygpath -w "$(command -v bash)")
    export CCA_ADB; CCA_ADB=$(cygpath -w "$REPO/tests/fake-adb.cmd")
    local args=()
    [ "${1:-}" = --uninstall ] && args=(-Uninstall)
    OUT=$(printf '%b' "$input" | powershell -NoProfile -ExecutionPolicy Bypass \
      -File "$(cygpath -w "$T/repo/install.ps1")" "${args[@]}" 2>&1)
  else
    export CCA_ADB=$REPO/tests/fake-adb
    OUT=$(printf '%b' "$input" | bash "$T/repo/install.sh" "$@" 2>&1)
  fi
  RC=$?
}

calls() { cat "$FAKE_ADB_DIR/calls.log" 2>/dev/null; }

check() {   # check "description" command...
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "FAIL [$T_NAME] $what"; echo "$OUT" | sed 's/^/    | /' | tail -n 12; fi
}
said() { printf '%s' "$OUT" | grep -qF -- "$1"; }
called() { calls | grep -qF -- "$1"; }
not_called() { ! called "$1"; }
rc_is() { [ "$RC" -eq "$1" ]; }

t() { T_NAME=$1; setup "$1"; }

t happy
run ""
check "exits 0" rc_is 0
check "runs the install on the phone" called "setup.sh install"
check "does not push Termux when it is not needed" not_called "termux.apk"

t unauthorized-then-allowed
printf 'SERIAL1\tunauthorized\n' > "$FAKE_ADB_DIR/devices.1"
printf 'SERIAL1\tdevice\n' > "$FAKE_ADB_DIR/devices.2"
run ""
check "tells the person to tap Allow" said "Allow USB debugging?"
check "then carries on" called "setup.sh install"

t offline
printf 'SERIAL1\toffline\n' > "$FAKE_ADB_DIR/devices.1"
printf 'SERIAL1\tdevice\n' > "$FAKE_ADB_DIR/devices.2"
run ""
check "says to replug" said "plug it back in"

t no-phone-yet
: > "$FAKE_ADB_DIR/devices.1"
printf 'SERIAL1\tdevice\n' > "$FAKE_ADB_DIR/devices.2"
run ""
check "explains USB debugging" said "USB debugging"
check "then carries on" called "setup.sh install"

t two-phones
printf 'SERIAL1\tdevice\nSERIAL2\tdevice\n' > "$FAKE_ADB_DIR/devices.1"
run "2\n"
check "asks which phone" said "More than one Android device"
check "uses the chosen phone" called "-s SERIAL2 shell sh /data/local/tmp/claude-code-android/phone/setup.sh install"

t unsupported-phone
echo 21 > "$FAKE_ADB_DIR/preflight.rc"
run ""
check "exits with the phone's code" rc_is 21
check "never starts the install" not_called "setup.sh install"
check "never pushes Termux" not_called "termux.apk"

t existing-termux-declined
echo 10 > "$FAKE_ADB_DIR/preflight.rc"
run "n\n"
check "exits non-zero" rc_is 1
check "never starts the install" not_called "setup.sh install"
check "cleans up the phone" called "rm -rf /data/local/tmp/claude-code-android"

t existing-termux-accepted
echo "10 0" > "$FAKE_ADB_DIR/preflight.rc"
run "y\n"
check "exits 0" rc_is 0
check "passes the consent on" called "setup.sh install --use-existing-termux"

t replace-needs-exact-word
echo "11 3" > "$FAKE_ADB_DIR/preflight.rc"
run "yes\n"
check "a plain yes is not enough" not_called "setup.sh install"
check "says cancelled" said "Cancelled"

t mobile-data-accepted
echo "12 0" > "$FAKE_ADB_DIR/preflight.rc"
run "y\n"
check "passes the consent on" called "setup.sh install --allow-mobile-data"

t tampered-termux
echo 3 > "$FAKE_ADB_DIR/preflight.rc"
echo "not the real app" > "$T/bogus.apk"
if [ "$KIND" = ps ]; then export CCA_TERMUX_APK_URL; CCA_TERMUX_APK_URL=$(cygpath -w "$T/bogus.apk")
else export CCA_TERMUX_APK_URL=$T/bogus.apk; fi
run ""
check "refuses the file" said "not the one this installer expects"
check "never pushes it" not_called "termux.apk"
check "never starts the install" not_called "setup.sh install"
check "exits non-zero" rc_is 1

t disconnected-mid-install
echo 1 > "$FAKE_ADB_DIR/install.rc"
echo "" > "$FAKE_ADB_DIR/state"
run ""
check "says the phone was disconnected" said "phone was disconnected"
check "exits non-zero" rc_is 1

t phone-side-failure
echo 61 > "$FAKE_ADB_DIR/install.rc"
run ""
check "says to run again" said "run the installer again"
check "exits with the phone's code" rc_is 61

t uninstall-keeps-termux
run "\n" --uninstall
check "removes" called "setup.sh remove"
check "without deleting Termux" not_called "--remove-termux"

t uninstall-with-termux
run "REMOVE\n" --uninstall
check "deletes Termux only on the exact word" called "setup.sh remove --remove-termux"

echo "$KIND entry point: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
