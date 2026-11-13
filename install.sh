#!/usr/bin/env bash
# claude-code-android: installs Claude Code on an Android phone connected by USB.
# macOS and Linux entry point:   ./install.sh        (remove with ./uninstall.sh)
# The real work happens in phone/setup.sh, which this script copies to the phone
# and runs there. This script only finds adb, waits for the phone, fetches the
# Termux app, and passes on the phone's questions.
# Keep its behaviour and wording in step with install.ps1. Must run on bash 3.2.
set -u
export MSYS_NO_PATHCONV=1   # only matters when the tests run under Git Bash

ROOT=$(cd "$(dirname "$0")" && pwd)
PHONE_DIR=/data/local/tmp/claude-code-android
CACHE=$ROOT/.cache
mkdir -p "$CACHE" "$ROOT/logs"
LOG_NAME=logs/install-$(date +%Y%m%d-%H%M%S).log
LOG=$ROOT/$LOG_NAME
OS=$(uname -s)
UNINSTALL=0
[ "${1:-}" = --uninstall ] && UNINSTALL=1
CURL="curl --proto =https --tlsv1.2 -fsSL"

say() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$LOG"; }

quit() {
  say ""
  say "$1"
  say "Log: $LOG_NAME (in this folder)"
  exit "${2:-1}"
}

# Ask a question; the answer lands in $REPLY and in the log. An empty answer is
# what Enter or a closed input gives.
ask() {
  printf '%s ' "$1"
  read -r REPLY || REPLY=""
  printf '%s -> %s\n' "$1" "$REPLY" >> "$LOG"
}

confirm() { ask "$1 [y/N]"; case "$REPLY" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac; }

# shellcheck source=versions.env
. "$ROOT/versions.env"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
  else shasum -a 256 "$1" | cut -d ' ' -f 1; fi
}

hash_ok() { [ -f "$1" ] && [ "$(sha256_of "$1")" = "$2" ]; }

# Use adb if the laptop already has it; otherwise fetch Google's copy into .tools.
find_adb() {
  if [ -n "${CCA_ADB:-}" ]; then say "(test setting CCA_ADB is in use)"; ADB=$CCA_ADB; return; fi
  if command -v adb >/dev/null 2>&1; then ADB=$(command -v adb); return; fi
  ADB=$ROOT/.tools/platform-tools/adb
  [ -x "$ADB" ] && return

  local kind want zip=$ROOT/.tools/platform-tools.zip
  case "$OS-$(uname -m)" in
    Darwin-*) kind=darwin want=$ADB_SHA256_DARWIN ;;
    Linux-x86_64) kind=linux want=$ADB_SHA256_LINUX ;;
    *) quit "Google does not publish adb for this kind of laptop ($OS $(uname -m)).
Install it with your package manager (the package is usually called
android-tools or android-tools-adb) and run the installer again." ;;
  esac
  command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 ||
    quit "The installer needs 'curl' and 'unzip' to download adb. Install them and run it again."

  say "This laptop does not have adb, the Android tool that talks to the phone."
  say "The installer can download it from Google (about 10 MB) into this folder."
  say "Nothing is installed system-wide. Google's terms: https://developer.android.com/studio/terms"
  confirm "Download adb from Google?" || quit "Cancelled. Nothing was changed."
  mkdir -p "$ROOT/.tools"
  $CURL -o "$zip" "https://dl.google.com/android/repository/platform-tools_r$ADB_VERSION-$kind.zip" ||
    quit "Could not download adb. Check the laptop's internet connection and run the installer again."
  if ! hash_ok "$zip" "$want"; then
    rm -f "$zip"
    quit "The downloaded adb file is not the one this installer expects, so it was not used. Run the installer again; if it keeps happening, report it."
  fi
  unzip -q -o "$zip" -d "$ROOT/.tools"
  rm -f "$zip"
  [ -x "$ADB" ] || quit "The adb download did not unpack correctly. Run the installer again."
}

# One line per device: "serial<TAB>state". adb's own status lines have no tab.
devices() {
  "$ADB" devices </dev/null 2>/dev/null | tr -d '\r' | awk -F '\t' 'NF == 2 { print $1 "\t" $2 }'
}

# Serial numbers identify a phone, so only their last four characters are shown.
hide_serial() {
  if [ "${#1}" -le 4 ]; then printf '%s' "$1"; else printf '...%s' "${1:$((${#1} - 4))}"; fi
}

# Wait until exactly one phone is connected and has allowed this laptop.
wait_phone() {
  local shown="" waited=0 asked=0 list count ready nready state serial i
  while :; do
    list=$(devices)
    if printf '%s\n' "$list" | cut -f 1 | grep -q '[^A-Za-z0-9._:-]'; then
      quit "A connected device reports a name this installer does not accept. Unplug other devices and run it again."
    fi
    count=$(printf '%s' "$list" | grep -c . || true)
    ready=$(printf '%s\n' "$list" | awk -F '\t' '$2 == "device" { print $1 }')
    nready=$(printf '%s' "$ready" | grep -c . || true)
    if [ "$count" -eq 1 ] && [ "$nready" -eq 1 ]; then SERIAL=$ready; return; fi

    if [ "$nready" -ge 1 ] && [ "$count" -gt 1 ]; then
      [ "$asked" -ge 5 ] && quit "No phone was chosen. Unplug the other devices and run the installer again."
      asked=$((asked + 1))
      say ""
      say "More than one Android device is connected:"
      i=0
      while IFS= read -r serial; do
        i=$((i + 1))
        say "  $i. $("$ADB" -s "$serial" shell getprop ro.product.model </dev/null 2>/dev/null | tr -d '\r') ($(hide_serial "$serial"))"
      done <<EOF
$ready
EOF
      ask "Type the number of the phone to set up (or unplug the others and press Enter):"
      case "$REPLY" in
        ''|*[!0-9]*) ;;
        *) SERIAL=$(printf '%s\n' "$ready" | sed -n "${REPLY}p")
           [ -n "$SERIAL" ] && return ;;
      esac
      sleep 2
      continue
    fi

    state=none
    [ "$count" -ge 1 ] && state=$(printf '%s\n' "$list" | head -n 1 | cut -f 2)
    [ "$state" = none ] && [ "$waited" -ge 30 ] && state=none-long
    if [ "$state" != "$shown" ]; then
      shown=$state
      say ""
      case "$state" in
        none)
          say "Waiting for your phone..."
          say "  1. Plug the phone into this laptop with a USB cable (a data cable, not charge-only)."
          say "  2. On the phone: Settings > About phone > tap \"Build number\" 7 times."
          say "  3. Settings > System > Developer options > switch on \"USB debugging\"."
          say "  Steps differ a little by brand: see docs/usb-debugging.md"
          say "  (Press Ctrl+C to cancel. Nothing has been changed yet.)" ;;
        none-long)
          say "Still no phone. Things to try:"
          say "  - Another cable or USB port. Many cables only charge."
          say "  - On the phone, pull down the notifications and set USB to \"File transfer\"."
          [ "$OS" = Darwin ] && say "  - If the Mac asks \"Allow accessory to connect?\", click Allow." ;;
        unauthorized)
          say "Phone found. Now unlock it and look for \"Allow USB debugging?\"."
          say "  Tick \"Always allow from this computer\" and tap Allow."
          say "  No prompt? Unplug the cable and plug it back in." ;;
        authorizing) say "Waiting for you to tap Allow on the phone..." ;;
        offline) say "The phone is connected but not answering. Unplug the cable and plug it back in." ;;
        "no permissions"*)
          say "This laptop is not allowed to talk to the phone over USB."
          say "  On Linux this needs the Android udev rules. Install your distribution's"
          say "  package (android-sdk-platform-tools-common on Debian and Ubuntu,"
          say "  android-udev on Arch), then unplug the phone and plug it back in." ;;
        *) say "The phone is in a maintenance mode. Restart it normally and wait for the home screen." ;;
      esac
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

# Copy the phone-side scripts over, with Unix line endings whatever git did.
push_scripts() {
  local stage=$CACHE/push f
  mkdir -p "$stage/phone"
  "$ADB" -s "$SERIAL" shell "mkdir -p $PHONE_DIR/phone" </dev/null >/dev/null 2>&1
  for f in versions.env phone/setup.sh phone/termux-setup.sh phone/guest-setup.sh; do
    tr -d '\r' < "$ROOT/$f" > "$stage/$f"
    "$ADB" -s "$SERIAL" push "$stage/$f" "$PHONE_DIR/$f" </dev/null >/dev/null 2>&1 ||
      quit "Could not copy files to the phone. Unplug it, plug it back in, and run the installer again."
  done
}

# Run phone/setup.sh on the phone, showing and logging each line as it arrives.
# Its last line is CCA_EXIT=<code>; if that never arrives, the connection was
# cut (255).
run_phone() {
  local line code=255
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      CCA_EXIT=*[!0-9]*) ;;
      CCA_EXIT=?*) code=${line#CCA_EXIT=} ;;
      *) say "$line" ;;
    esac
  done < <("$ADB" -s "$SERIAL" shell "sh $PHONE_DIR/phone/setup.sh $*" </dev/null 2>&1)
  return "$code"
}

# Download the Termux app (once), check it is the exact file we expect, copy it over.
push_termux() {
  local apk=$CACHE/termux-$TERMUX_VERSION.apk url=$TERMUX_APK_URL
  if ! hash_ok "$apk" "$TERMUX_APK_SHA256"; then
    say "Downloading Termux $TERMUX_VERSION (35 MB)..."
    if [ -n "${CCA_TERMUX_APK_URL:-}" ]; then say "(test setting CCA_TERMUX_APK_URL is in use)"; url=$CCA_TERMUX_APK_URL; fi
    if [ -f "$url" ]; then cp "$url" "$apk"
    else $CURL -o "$apk" "$url" ||
      quit "Could not download Termux. Check the laptop's internet connection and run the installer again."
    fi
    if ! hash_ok "$apk" "$TERMUX_APK_SHA256"; then
      rm -f "$apk"
      quit "The downloaded Termux file is not the one this installer expects, so it was not installed. Run the installer again; if it keeps happening, report it."
    fi
  fi
  "$ADB" -s "$SERIAL" push "$apk" "$PHONE_DIR/termux.apk" </dev/null >/dev/null 2>&1 ||
    quit "Could not copy Termux to the phone. Unplug it, plug it back in, and run the installer again."
}

stop_after_failure() {
  local state
  state=$("$ADB" -s "$SERIAL" get-state </dev/null 2>/dev/null | tr -d '\r')
  if [ "$1" -eq 255 ] || [ "$state" != device ]; then
    quit "The connection to the phone was lost. Plug it back in and run this again; it continues where it stopped." "$1"
  fi
  case "$1" in 20|21|22|23|26) quit "This phone cannot be set up, so nothing was changed on it." "$1" ;; esac
  [ "$UNINSTALL" = 1 ] && quit "The removal did not finish. Fix the problem above and run the uninstaller again." "$1"
  quit "The install did not finish. Fix the problem above and run the installer again; it continues where it stopped." "$1"
}

stop_cancelled() {
  "$ADB" -s "$SERIAL" shell "rm -rf $PHONE_DIR" </dev/null >/dev/null 2>&1
  quit "$1"
}

# ---------------------------------------------------------------------------

say "claude-code-android: Claude Code on your Android phone"
say "(unofficial community project, not made by Anthropic)"
say ""
say "Note: this installer has been confirmed on Windows. On macOS and Linux it runs"
say "the same steps on the phone, but this script is not yet confirmed on real"
say "hardware. Please report how it goes."
say ""

find_adb
wait_phone
say ""
say "Phone connected."
push_scripts

if [ "$UNINSTALL" = 1 ]; then
  say ""
  say "Removing Claude Code and its Linux guest from the phone..."
  run_phone remove
  code=$?
  if [ "$code" -eq 13 ]; then
    ask "To ALSO delete the Termux app with every file inside it, type REMOVE. Otherwise press Enter:"
    if [ "$REPLY" = REMOVE ]; then
      run_phone remove --remove-termux
      code=$?
    else
      "$ADB" -s "$SERIAL" shell "rm -rf $PHONE_DIR" </dev/null >/dev/null 2>&1
      code=0
    fi
  fi
  [ "$code" -eq 0 ] || stop_after_failure "$code"
  quit "Finished." 0
fi

flags=""
while :; do
  # shellcheck disable=SC2086  # flags are separate words on purpose
  run_phone preflight $flags
  code=$?
  case "$code" in
    0) break ;;
    3) push_termux; break ;;
    10) if confirm "Add Claude Code to this Termux?"; then flags="$flags --use-existing-termux"
        else stop_cancelled "Cancelled. Nothing was changed on the phone."; fi ;;
    11) ask "Type REPLACE to delete the existing Termux and continue, or press Enter to cancel:"
        if [ "$REPLY" = REPLACE ]; then flags="$flags --replace-termux"
        else stop_cancelled "Cancelled. Nothing was changed on the phone."; fi ;;
    12) if confirm "Continue on mobile data?"; then flags="$flags --allow-mobile-data"
        else stop_cancelled "Cancelled. Connect the phone to Wi-Fi and run the installer again."; fi ;;
    *) stop_after_failure "$code" ;;
  esac
done

say ""
say "Setting up the phone. This takes about 5 to 10 minutes. Keep the phone"
say "plugged in and unlocked."
# shellcheck disable=SC2086
run_phone install $flags || stop_after_failure $?
quit "Finished." 0
