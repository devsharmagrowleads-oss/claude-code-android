#!/usr/bin/env bash
# Tests for the laptop entry points, run against tests/fake-adb (no phone needed).
#   tests/test-entry.sh sh    tests install.sh
#   tests/test-entry.sh ps    tests install.ps1 (Windows, from Git Bash)
# Both must behave the same, so both run the same tests.
set -u
KIND=${1:-sh}
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
APK_HASH=$(printf 'the termux app' | sha256sum | cut -d ' ' -f 1)

native() { if [ "$KIND" = ps ]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# Each test runs a fresh copy of the installer in its own folder.
t() {
  T_NAME=$1
  T=$WORK/$1; mkdir -p "$T/repo/phone" "$T/adb"
  cp "$REPO/install.sh" "$REPO/install.ps1" "$T/repo/"
  cp "$REPO"/phone/*.sh "$T/repo/phone/"
  sed "s/^TERMUX_APK_SHA256=.*/TERMUX_APK_SHA256=$APK_HASH/" "$REPO/versions.env" > "$T/repo/versions.env"
  export FAKE_ADB_DIR=$T/adb
  printf 'SERIAL1\tdevice\n' > "$T/adb/devices.1"
  printf 'the termux app' > "$T/good.apk"
  export CCA_TERMUX_APK_URL; CCA_TERMUX_APK_URL=$(native "$T/good.apk")
}

# The command line that starts the installer under test.
installer() {
  if [ "$KIND" = ps ]; then
    export CCA_TEST_BASH; CCA_TEST_BASH=$(cygpath -w "$(command -v bash)")
    export CCA_ADB; CCA_ADB=$(cygpath -w "$REPO/tests/fake-adb.cmd")
    local args=()
    [ "${1:-}" = --uninstall ] && args=(-Uninstall)
    powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$T/repo/install.ps1")" ${args[@]+"${args[@]}"}
  else
    export CCA_ADB=$REPO/tests/fake-adb
    bash "$T/repo/install.sh" "$@"
  fi
}

# run "stdin text" [installer args]  -> output in $OUT, exit code in $RC
run() {
  local input=$1; shift
  OUT=$(printf '%b' "$input" | installer "$@" 2>&1)
  RC=$?
}

calls() { cat "$FAKE_ADB_DIR/calls.log" 2>/dev/null; }
logfile() { cat "$T"/repo/logs/*.log 2>/dev/null; }

check() {   # check "description" command...
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "FAIL [$T_NAME] $what"; echo "$OUT" | tail -n 12 | sed 's/^/    | /'; fi
}
said() { printf '%s' "$OUT" | grep -qF -- "$1"; }
not_said() { ! said "$1"; }
logged() { logfile | grep -qF -- "$1"; }
not_logged() { ! logged "$1"; }
called() { calls | grep -qF -- "$1"; }
not_called() { ! called "$1"; }
rc_is() { [ "$RC" -eq "$1" ]; }

t happy
run ""
check "exits 0" rc_is 0
check "runs the install on the phone" called "setup.sh install"
check "does not push Termux when it is not needed" not_called "termux.apk"
check "hides the phone's code line" not_said "CCA_EXIT"
check "ignores adb's own status lines" not_said "maintenance mode"
check "shows the log's place without the laptop's folders" said "Log: logs"

t fresh-phone-gets-termux
echo 3 > "$FAKE_ADB_DIR/preflight.rc"
run ""
check "exits 0" rc_is 0
check "pushes the checked Termux file" called "termux.apk"
check "then installs" called "setup.sh install"

t tampered-termux
echo 3 > "$FAKE_ADB_DIR/preflight.rc"
echo "not the real app" > "$T/good.apk"
run ""
check "refuses the file" said "not the one this installer expects"
check "never pushes it" not_called "termux.apk"
check "never starts the install" not_called "setup.sh install"
check "exits non-zero" rc_is 1

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

t unknown-state
printf 'SERIAL1\trescue\n' > "$FAKE_ADB_DIR/devices.1"
printf 'SERIAL1\tdevice\n' > "$FAKE_ADB_DIR/devices.2"
run ""
check "an unfamiliar state is explained" said "maintenance mode"

t no-phone-yet
: > "$FAKE_ADB_DIR/devices.1"
printf 'SERIAL1\tdevice\n' > "$FAKE_ADB_DIR/devices.2"
run ""
check "explains USB debugging" said "USB debugging"
check "then carries on" called "setup.sh install"

t two-phones
printf 'PHONE-AAAA1111\tdevice\nPHONE-BBBB2222\tdevice\n' > "$FAKE_ADB_DIR/devices.1"
run "2\n"
check "asks which phone" said "More than one Android device"
check "uses the chosen phone" called "-s PHONE-BBBB2222 shell sh /data/local/tmp/claude-code-android/phone/setup.sh install"
check "shows only the end of each serial number" said "(...2222)"
check "keeps full serial numbers out of the log" not_logged "PHONE-BBBB2222"
check "logs the answer" logged "-> 2"

t two-phones-no-answer
printf 'PHONE-AAAA1111\tdevice\nPHONE-BBBB2222\tdevice\n' > "$FAKE_ADB_DIR/devices.1"
run ""
check "gives up instead of asking forever" said "No phone was chosen"
check "exits non-zero" rc_is 1

t odd-serial
printf 'BAD;SERIAL\tdevice\n' > "$FAKE_ADB_DIR/devices.1"
run ""
check "a strange device name is refused" said "does not accept"
check "nothing is sent to it" not_called "setup.sh"

t unsupported-phone
echo 21 > "$FAKE_ADB_DIR/preflight.rc"
run ""
check "exits with the phone's code" rc_is 21
check "never starts the install" not_called "setup.sh install"
check "never pushes Termux" not_called "termux.apk"
check "does not tell the person to try again" not_said "run the installer again"
check "says nothing was changed" said "nothing was changed"

t existing-termux-declined
echo 10 > "$FAKE_ADB_DIR/preflight.rc"
run "n\n"
check "exits non-zero" rc_is 1
check "never starts the install" not_called "setup.sh install"
check "cleans up the phone" called "rm -rf /data/local/tmp/claude-code-android"

t existing-termux-accepted
echo "10 0" > "$FAKE_ADB_DIR/preflight.rc"
run "Yes\n"
check "exits 0" rc_is 0
check "accepts Yes in any case, and passes the consent on" called "setup.sh install --use-existing-termux"
check "logs the answer" logged "-> Yes"

t replace-needs-exact-word
echo "11 3" > "$FAKE_ADB_DIR/preflight.rc"
run "yes\n"
check "a plain yes is not enough" not_called "setup.sh install"
check "says cancelled" said "Cancelled"

t replace-accepted
echo "11 3" > "$FAKE_ADB_DIR/preflight.rc"
run "REPLACE\n"
check "exits 0" rc_is 0
check "pushes Termux" called "termux.apk"
check "passes the consent on" called "setup.sh install --replace-termux"
check "logs the answer" logged "-> REPLACE"

t mobile-data-accepted
echo "12 0" > "$FAKE_ADB_DIR/preflight.rc"
run "y\n"
check "passes the consent on" called "setup.sh install --allow-mobile-data"

t old-adb-loses-exit-codes
touch "$FAKE_ADB_DIR/legacy"
echo 21 > "$FAKE_ADB_DIR/preflight.rc"
run ""
check "the phone's code still gets through" rc_is 21
check "never starts the install" not_called "setup.sh install"
check "does not say Finished" not_said "Finished."

t connection-cut-mid-install
touch "$FAKE_ADB_DIR/cut"
run ""
check "says the connection was lost" said "connection to the phone was lost"
check "exits non-zero" rc_is 255
check "does not say Finished" not_said "Finished."

t phone-side-failure
echo 61 > "$FAKE_ADB_DIR/install.rc"
run ""
check "says to run again" said "run the installer again"
check "exits with the phone's code" rc_is 61

t uninstall-nothing-more
run "" --uninstall
check "removes" called "setup.sh remove"
check "does not ask about Termux when the phone does not offer it" not_said "type REMOVE"
check "exits 0" rc_is 0

t uninstall-keeps-termux
echo 13 > "$FAKE_ADB_DIR/remove.rc"
run "\n" --uninstall
check "asks, because the phone offered it" logged "type REMOVE"
check "without deleting Termux" not_called "--remove-termux"
check "tidies the phone" called "rm -rf /data/local/tmp/claude-code-android"
check "exits 0" rc_is 0

t uninstall-with-termux
echo "13 0" > "$FAKE_ADB_DIR/remove.rc"
run "REMOVE\n" --uninstall
check "deletes Termux only on the exact word" called "setup.sh remove --remove-termux"
check "exits 0" rc_is 0

t uninstall-fails
echo 41 > "$FAKE_ADB_DIR/remove.rc"
run "" --uninstall
check "talks about the removal, not the install" said "removal did not finish"
check "exits with the phone's code" rc_is 41

# What the phone prints must show up while it is still working, not at the end.
t output-arrives-live
touch "$FAKE_ADB_DIR/slow"
installer > "$T/live.out" 2>&1 < /dev/null &
bg=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  grep -q "fake phone: install" "$T/live.out" 2>/dev/null && break
  kill -0 "$bg" 2>/dev/null || break
  sleep 0.25
done
OUT=$(cat "$T/live.out")
check "the phone's first line is visible before the step ends" kill -0 "$bg"
check "and it really is there" said "fake phone: install"
wait "$bg"

echo "$KIND entry point: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
