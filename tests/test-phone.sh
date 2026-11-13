#!/usr/bin/env bash
# Tests for the scripts that run on the phone (phone/setup.sh and, through it,
# phone/termux-setup.sh). Android's and Termux's commands are replaced by the
# stand-ins in tests/stubs, which act on a throwaway folder: a fake phone.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
APK_HASH=$(printf 'the termux app' | sha256sum | cut -d ' ' -f 1)

# Start a new fake phone. kind: absent | foreign | broken | empty | unmarked | ours
new_phone() {
  NAME=$1
  F=$WORK/$NAME; D=$F/dir
  mkdir -p "$D/phone" "$F"
  cp "$REPO"/phone/*.sh "$D/phone/"
  sed "s/^TERMUX_APK_SHA256=.*/TERMUX_APK_SHA256=$APK_HASH/" "$REPO/versions.env" > "$D/versions.env"
  T=$F/data/files                         # Termux's files folder on the fake phone
  S=$T/home/.claude-code-android          # where the installer keeps its notes
  case "${2:-absent}" in
    absent) echo absent > "$F/kind" ;;
    foreign|broken) echo "$2" > "$F/kind" ;;
    empty) echo debug > "$F/kind"; mkdir -p "$F/data" ;;
    unmarked|ours)
      echo debug > "$F/kind"; mkdir -p "$F/data"
      env F_ROOT="$F" "$REPO/tests/stubs/am" start      # "opens" Termux, which unpacks it
      rm -f "$F/running" "$F/calls"
      [ "$2" = ours ] && mkdir -p "$S" ;;
  esac
  return 0
}

put_apk() { printf '%s' "${1:-the termux app}" > "$D/termux.apk"; }

# phone MODE [flags] [VAR=value ...]  -> output in $OUT, code in $RC
phone() {
  local args=() vars=()
  for a; do case "$a" in *=*) vars+=("$a") ;; *) args+=("$a") ;; esac; done
  mkdir -p "$D/phone"; cp "$REPO"/phone/*.sh "$D/phone/"   # the laptop pushes these every run
  [ -f "$D/versions.env" ] || sed "s/^TERMUX_APK_SHA256=.*/TERMUX_APK_SHA256=$APK_HASH/" "$REPO/versions.env" > "$D/versions.env"
  OUT=$(env PATH="$REPO/tests/stubs:$PATH" CCA_DIR="$D" CCA_TERMUX_ROOT="$T" \
    CCA_TEST_PATH="$REPO/tests/stubs:$PATH" F_ROOT="$F" ${vars[@]+"${vars[@]}"} \
    sh "$D/phone/setup.sh" ${args[@]+"${args[@]}"} 2>&1)
  RC=$?
}

check() {   # check "description" command...
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "FAIL [$NAME] $what"; echo "$OUT" | tail -n 14 | sed 's/^/    | /'; fi
}
rc() { [ "$RC" -eq "$1" ]; }
said() { printf '%s' "$OUT" | grep -qF -- "$1"; }
not_said() { ! said "$1"; }
called() { grep -qF -- "$1" "$F/calls" 2>/dev/null; }
times() { [ "$(grep -cF -- "$2" "$F/calls" 2>/dev/null)" -eq "$1" ]; }
kind() { [ "$(cat "$F/kind")" = "$1" ]; }
missing() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

# --- checks made before anything is changed ----------------------------------

# refuse CODE "description" KIND [VAR=value | --flag ...]
refuse() {
  local want=$1 what=$2 k=$3; shift 3
  new_phone "pre-$want-${what// /-}" "$k"
  phone preflight "$@"
  check "$what: code $want" rc "$want"
  check "$what: ends with its code line" said "CCA_EXIT=$want"
}

refuse 20 "Android too old" absent F_SDK=23
refuse 21 "32-bit phone" absent F_ABI64=
refuse 22 "x86 device" absent F_ABI64=x86_64 F_ABI=x86_64
refuse 23 "secondary user" absent F_USER=10
refuse 21 "32-bit wins over Termux state" foreign F_ABI64=
refuse 3  "fresh phone needs the Termux app" absent
refuse 24 "not enough free space" absent F_FREE_KB=1000000
refuse 25 "no internet" absent F_NET=none
refuse 12 "mobile data needs a yes" absent F_NET=mobile
refuse 3  "mobile data after a yes" absent F_NET=mobile --allow-mobile-data
refuse 3  "network not reported carries on" absent F_NET=unknown
refuse 3  "unrecognised network type carries on" absent F_NET=odd
refuse 11 "Play Store or F-Droid Termux needs REPLACE" foreign
refuse 3  "after REPLACE the app is needed" foreign --replace-termux
refuse 31 "foreign Termux with add-ons stops before REPLACE" foreign --replace-termux F_ADDONS=com.termux.api
refuse 26 "debuggable but not drivable" broken
refuse 10 "someone's own Termux needs a yes" unmarked
refuse 0  "someone's own Termux after a yes" unmarked --use-existing-termux
refuse 0  "our Termux, interrupted install" ours
refuse 0  "Termux installed but never opened" empty
refuse 24 "unfinished install still checks space" ours F_FREE_KB=1000

new_phone stale-app-still-asks-for-push absent
put_apk "left over from a cut-off copy"
phone preflight
check "a leftover app file does not skip the push" rc 3

new_phone finished-skips-space ours
touch "$S/guest-ready"
phone preflight F_FREE_KB=1000 F_NET=none
check "a finished install skips the space and network checks" rc 0

new_phone resume-needs-less-space ours
touch "$S/guest-downloaded"
phone preflight F_FREE_KB=900000
check "after the big download, less free space is enough" rc 0

# --- a complete install, then a re-run ----------------------------------------

new_phone fresh absent
put_apk
phone install
check "exits 0" rc 0
check "installs the app" called "pm install"
check "sets up the Linux guest tool" called "apt-get"
check "downloads the guest by its pinned name" called "proot-distro install -n claude-code debian:"
check "creates the claude command" grep -q claude-code-android "$T/usr/bin/claude"
check "marks the guest ready" test -e "$S/guest-ready"
check "remembers the app is ours" test -e "$S/app-installed-by-us"
check "lifts the background-process limit" grep -qx false "$F/setting"
check "writes down the old value first" grep -qx "settings null" "$S/phantom.orig"
check "opens Claude Code" said "Claude Code is open on the phone."
check "says why to switch USB debugging off" said "can read Termux"
check "tidies its copies off the phone" missing "$D"
check "ends with its code line" said "CCA_EXIT=0"

phone install
check "re-run exits 0" rc 0
check "re-run downloads nothing again" times 1 "proot-distro install -n"
check "re-run reports Claude Code as installed" said "Already installed: 9.9.9"
check "re-run does not reinstall the app" times 1 "pm install"

echo 'ARGS' > "$F/ps"; printf 'com.termux\nbash -l\nproot --kill-on-exit\nclaude\n' >> "$F/ps"
: > "$F/calls"
phone install
check "re-run with Claude Code open leaves it alone" said "already open"
check "re-run with Claude Code open does not restart Termux" times 0 "am force-stop"

# --- the Termux app file ------------------------------------------------------

new_phone wrong-app-file absent
put_apk "something else"
phone install
check "a wrong app file is refused" rc 28
check "it is not installed" kind absent
check "it is deleted from the phone" missing "$D/termux.apk"

new_phone blocked-install absent
put_apk
phone install F_PM_FAIL=INSTALL_FAILED_USER_RESTRICTED
check "a blocked install stops with its own code" rc 30
check "the app file is not left behind" missing "$D/termux.apk"

new_phone missing-app-file absent
phone install
check "no app file stops the install" rc 27

# --- interruptions ------------------------------------------------------------

new_phone fails-preparing-guest absent
put_apk
phone install F_FAIL_ROOT=1
check "a failed guest step stops with its code" rc 64
check "it blames the network" said "network problem"
phone install
check "the next run finishes" rc 0
check "the guest is not downloaded twice" times 1 "proot-distro install -n"

new_phone fails-downloading-guest absent
put_apk
phone install F_FAIL_DOWNLOAD=1
check "a failed download stops with its code" rc 63
phone install
check "the next run finishes" rc 0

new_phone claude-does-not-start absent
put_apk
phone install F_FAIL_USER=1
check "a failed Claude Code install stops with its code" rc 65
check "the guest is not marked ready" missing "$S/guest-ready"

new_phone stale-lock ours
mkdir -p "$D/lock"; echo 999999 > "$D/lock/pid"
phone preflight
check "a lock left by a dead run is ignored" rc 0

new_phone live-lock ours
mkdir -p "$D/lock"
if [ -r "/proc/$$/cmdline" ]; then
  sh -c 'exec -a setup.sh sleep 30' >/dev/null 2>&1 & holder=$!
  sleep 1; echo "$holder" > "$D/lock/pid"
  if grep -q setup.sh "/proc/$holder/cmdline" 2>/dev/null; then
    phone preflight
    check "a second run is turned away while one is running" rc 40
  fi
  kill "$holder" 2>/dev/null
fi

# --- an existing Termux -------------------------------------------------------

new_phone existing-termux unmarked
printf '#!/bin/sh\necho my own claude\n' > "$T/usr/bin/claude"
phone install --use-existing-termux
check "exits 0" rc 0
check "does not install the app" times 0 "pm install"
check "sets the person's claude command aside" grep -q "my own claude" "$S/claude.backup"
check "says so" said "set aside"
phone remove
check "uninstall exits 0, with no offer to delete their Termux" rc 0
check "puts their claude command back" grep -q "my own claude" "$T/usr/bin/claude"
check "removes the guest" missing "$T/usr/var/lib/proot-distro/containers/claude-code"
check "leaves Termux installed" kind debug

new_phone existing-claude-is-a-link unmarked
mkdir -p "$T/usr/lib/npm-claude"
echo "the real cli.js" > "$T/usr/lib/npm-claude/cli.js"
if ln -s ../lib/npm-claude/cli.js "$T/usr/bin/claude" 2>/dev/null && [ -L "$T/usr/bin/claude" ]; then
  phone install --use-existing-termux
  check "a linked claude command: the file it points to is untouched" grep -qx "the real cli.js" "$T/usr/lib/npm-claude/cli.js"
  phone remove
  check "a linked claude command: the link is put back" test -L "$T/usr/bin/claude"
  check "a linked claude command: it still points at the same file" grep -qx "the real cli.js" "$T/usr/bin/claude"
fi

new_phone guest-name-taken unmarked
mkdir -p "$T/usr/var/lib/proot-distro/containers/claude-code"
phone install --use-existing-termux
check "a guest of the same name that is not ours is never touched" rc 62
check "it is still there" test -d "$T/usr/var/lib/proot-distro/containers/claude-code"

new_phone old-guest-tool unmarked
phone install --use-existing-termux
check "an out-of-date guest tool is updated" called "install proot-distro"

new_phone replace-foreign foreign
put_apk
phone install --replace-termux
check "replacing a foreign Termux finishes" rc 0
check "the old one is uninstalled first" called "pm uninstall"

# --- phone settings and the last step ----------------------------------------

new_phone settings-blocked absent
put_apk
phone install F_SETTINGS_DENY=1
check "exits 0 when the first setting is blocked" rc 0
check "falls back to the second setting" grep -qx 2147483647 "$F/devcfg"
check "remembers which one it changed" grep -qx "device_config null" "$S/phantom.orig"
check "says it may reset after a restart" said "after a restart"

new_phone old-android-no-limit absent
put_apk
phone install F_SDK=29
check "older Android needs no setting" said "Not needed on this Android version."

new_phone locked-at-the-end unmarked
phone install --use-existing-termux F_LOCKED=1
check "a locked phone is told how to open it" said "The phone is locked."
check "nothing is launched" missing "$S/launch-once"

new_phone termux-busy unmarked
touch "$F/running"; printf 'ARGS\ncom.termux\nbash -l\npython server.py\n' > "$F/ps"
phone install --use-existing-termux
check "a busy Termux is not restarted" times 0 "am force-stop"
check "the person is told" said "busy with something else"

new_phone cannot-read-processes unmarked
touch "$F/running"; : > "$F/ps"
phone install --use-existing-termux
check "when Termux's processes cannot be read, it is not restarted" times 0 "am force-stop"

new_phone hook-never-fires unmarked
phone install --use-existing-termux F_NO_HOOK=1
check "if Claude Code does not open, the marker is cleared" missing "$S/launch-once"
check "and the person is told what to type" said "type: claude"

# --- uninstall ----------------------------------------------------------------

new_phone uninstall-ours absent
put_apk
phone install
phone remove
check "uninstall offers to remove the Termux it installed" rc 13
check "the claude command is gone" missing "$T/usr/bin/claude"
check "the hook is gone" missing "$T/usr/etc/profile.d/claude-code-android.sh"
check "the setting is restored" missing "$F/setting"
check "its notes are gone" missing "$S"
check "the scripts stay for the second step" test -f "$D/phone/setup.sh"
phone remove --remove-termux
check "removing Termux exits 0" rc 0
check "Termux is uninstalled" kind absent

new_phone uninstall-nothing absent
phone remove
check "uninstall with nothing installed exits 0" rc 0
check "and says so" said "Nothing installed by this installer"

new_phone uninstall-not-ours unmarked
phone remove
check "someone's own Termux is left alone" said "Nothing installed by this installer"
check "and is still installed" kind debug

new_phone uninstall-never-opened absent
put_apk
phone install F_LOCKED=1
check "a locked phone stops the install while unpacking" rc 32
phone remove
check "uninstall on a Termux that was never opened still works" rc 13
check "without a raw error" not_said "not found"

new_phone remove-termux-fails ours
phone remove --remove-termux F_UNINSTALL_FAIL=1
check "a failed Termux uninstall is reported" rc 41
check "not claimed as done" not_said "has been removed"

echo "phone scripts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
