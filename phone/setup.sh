#!/system/bin/sh
# Runs on the phone as the adb shell user. Started by install.ps1 / install.sh,
# which push this folder to /data/local/tmp/claude-code-android first.
#
#   setup.sh preflight|install|remove [flags]
#
# Flags (each one is the person's answer to a question the laptop asked):
#   --use-existing-termux   set up inside a Termux this installer did not create
#   --replace-termux        uninstall a Termux that cannot be driven, then install ours
#   --allow-mobile-data     download over mobile data
#   --remove-termux         (remove only) uninstall the Termux app as well
#
# Exit codes:
#   0   done
#   3   preflight passed, and the Termux APK must be pushed before 'install'
#   10  needs --use-existing-termux     11  needs --replace-termux
#   12  needs --allow-mobile-data
#   20+ stopped; the reason has been printed
exec 2>&1

DIR=${CCA_DIR:-/data/local/tmp/claude-code-android}   # CCA_DIR is for the tests only
PKG=com.termux
STATE=files/home/.claude-code-android   # relative to Termux's data directory
. "$DIR/versions.env"

MODE=$1
[ $# -gt 0 ] && shift
USE_EXISTING=0 REPLACE=0 MOBILE_OK=0 REMOVE_TERMUX=0
for arg; do
  case "$arg" in
    --use-existing-termux) USE_EXISTING=1 ;;
    --replace-termux) REPLACE=1 ;;
    --allow-mobile-data) MOBILE_OK=1 ;;
    --remove-termux) REMOVE_TERMUX=1 ;;
  esac
done

step() { echo; echo "[$1/7] $2"; }

# stop CODE "headline" ["detail line" ...]
stop() {
  code=$1; shift
  echo; echo "STOPPED: $1"; shift
  for line; do echo "  $line"; done
  exit "$code"
}

# Run a command as the Termux app. The working directory is Termux's data directory.
in_termux() { run-as "$PKG" "$@"; }

locked() {
  dumpsys window 2>/dev/null |
    grep -qE 'isKeyguardShowing=true|mShowingLockscreen=true|mDreamingLockscreen=true'
}

# absent | foreign (cannot be driven) | broken (should be drivable, is not)
# | ours | unmarked (someone's own Termux) | empty (installed, never opened)
termux_state() {
  if [ -z "$(pm path "$PKG" 2>/dev/null)" ]; then echo absent
  elif ! run-as "$PKG" true 2>/dev/null; then
    if dumpsys package "$PKG" 2>/dev/null | grep -q 'DEBUGGABLE'; then echo broken; else echo foreign; fi
  elif in_termux sh -c "[ -e $STATE ]"; then echo ours
  elif in_termux sh -c "[ -x files/usr/bin/bash ]"; then echo unmarked
  else echo empty
  fi
}

installed() { in_termux sh -c "[ -e $STATE/installed ]" 2>/dev/null; }

check_phone() {
  sdk=$(getprop ro.build.version.sdk)
  [ "${sdk:-0}" -ge "$MIN_SDK" ] || stop 20 \
    "This phone runs Android $(getprop ro.build.version.release). Android 7 or newer is needed."

  case "$(getprop ro.product.cpu.abilist64)" in
    *arm64-v8a*) ;;
    "") stop 21 "This phone is 32-bit. Only 64-bit phones are supported." ;;
    *) stop 22 "This device's processor ($(getprop ro.product.cpu.abi)) is not supported. Only 64-bit ARM phones are." ;;
  esac

  user=$(am get-current-user 2>/dev/null)
  [ -z "$user" ] || [ "$user" = 0 ] || stop 23 \
    "The phone is switched to a secondary user or guest." \
    "Switch to the phone's main user and run the installer again."
}

# Space and network only matter while there is still something to download.
check_resources() {
  free_mb=$(df -k /data | awk 'END { print int($4 / 1024) }')
  [ "${free_mb:-0}" -ge "$MIN_FREE_MB" ] || stop 24 \
    "Not enough free space on the phone: ${free_mb} MB free, ${MIN_FREE_MB} MB needed." \
    "Free up some space and run the installer again."

  net=$(dumpsys connectivity 2>/dev/null | grep -m1 'Active default network:' | awk '{ print $NF }')
  [ "$net" = none ] && stop 25 \
    "The phone has no internet connection." \
    "Connect it to Wi-Fi and run the installer again."
  [ -n "$net" ] || return 0   # this Android version does not report it; carry on
  line=$(dumpsys connectivity 2>/dev/null | grep -m1 "NetworkAgentInfo{network{$net}")
  case "$line" in
    *WIFI*) ;;
    *MOBILE*|*CELLULAR*)
      if [ "$MOBILE_OK" = 0 ]; then
        echo
        echo "The phone is on mobile data. The install downloads about 500 MB on the phone."
        exit 12
      fi ;;
  esac
}

# Decide what to do about Termux. Sets NEED_APK.
check_termux() {
  NEED_APK=0
  case "$(termux_state)" in
    absent) NEED_APK=1 ;;
    ours|empty) ;;
    unmarked)
      if [ "$USE_EXISTING" = 0 ]; then
        echo
        echo "This phone already has Termux, set up by someone else (probably you)."
        echo "The installer can add Claude Code to it. It will update Termux's packages,"
        echo "add a Linux guest named '$GUEST_NAME' and a 'claude' command."
        echo "Your existing files in Termux are left alone."
        exit 10
      fi ;;
    foreign)
      if [ "$REPLACE" = 0 ]; then
        echo
        echo "This phone has Termux from the Play Store or F-Droid. That version cannot be"
        echo "set up from a laptop. The installer can replace it with the version from"
        echo "Termux's GitHub page, but replacing it DELETES everything inside Termux:"
        echo "files, projects and settings. Back up anything you need first."
        exit 11
      fi
      NEED_APK=1 ;;
    broken) stop 26 \
      "This phone model does not let a laptop run commands inside Termux." \
      "It is not supported yet. Please report your phone model at the project's issue page." ;;
  esac
}

install_termux() {
  [ -f "$DIR/termux.apk" ] || stop 27 "The Termux app file was not copied to the phone. Run the installer again."
  if [ "$(termux_state)" = foreign ]; then
    echo "Removing the old Termux..."
    pm uninstall "$PKG" >/dev/null 2>&1
  fi
  echo "Installing Termux $TERMUX_VERSION..."
  echo "(If the phone shows an install prompt, tap Install or Allow.)"
  out=$(pm install -r "$DIR/termux.apk" 2>&1)
  case "$out" in
    *Success*) ;;
    *INSTALL_FAILED_USER_RESTRICTED*) stop 30 \
      "The phone blocked the install." \
      "On Xiaomi, Redmi and POCO: Settings > Additional settings > Developer options," \
      "switch on 'Install via USB' and 'USB debugging (Security settings)'." \
      "On other phones: watch the screen for an install prompt and tap Allow." \
      "Then run the installer again." ;;
    *UPDATE_INCOMPATIBLE*|*SHARED_USER_INCOMPATIBLE*|*"signatures do not match"*) stop 31 \
      "A Termux add-on from another source is installed (for example Termux:API or Termux:Widget)." \
      "Uninstall the Termux add-ons on the phone and run the installer again." ;;
    *INSUFFICIENT_STORAGE*) stop 24 "Not enough free space on the phone to install Termux." ;;
    *) stop 39 "Android refused to install Termux:" "$out" ;;
  esac
  rm -f "$DIR/termux.apk"
  # Mark it as ours straight away, so an interrupted run is recognised next time.
  in_termux sh -c "mkdir -p $STATE"
}

wait_for_unlock() {
  input keyevent KEYCODE_WAKEUP 2>/dev/null
  locked || return 0
  echo "Unlock your phone to continue (waiting up to 2 minutes)..."
  n=0
  while locked; do
    n=$((n + 1))
    [ "$n" -gt 60 ] && stop 32 "The phone is still locked." "Unlock it and run the installer again."
    sleep 2
  done
}

# Termux unpacks its files the first time it is opened.
unpack_termux() {
  in_termux sh -c '[ -x files/usr/bin/bash ] && [ ! -e files/usr-staging ]' && return 0
  wait_for_unlock
  pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
  echo "Opening Termux so it can unpack itself..."
  am start -n "$PKG/.app.TermuxActivity" >/dev/null 2>&1
  n=0
  until in_termux sh -c '[ -x files/usr/bin/bash ] && [ ! -e files/usr-staging ]'; do
    n=$((n + 1))
    [ "$n" -gt 90 ] && stop 33 \
      "Termux did not finish unpacking." \
      "Open the Termux app on the phone, wait until it shows a prompt, then run the installer again."
    sleep 2
  done
}

# Copy our scripts into Termux and run the part that works inside it.
run_in_termux() {
  in_termux sh -c "mkdir -p $STATE" || stop 34 "Could not write inside Termux."
  for f in phone/termux-setup.sh phone/guest-setup.sh versions.env; do
    in_termux sh -c "cat > $STATE/${f##*/}" < "$DIR/$f" || stop 34 "Could not write inside Termux."
  done
  in_termux files/usr/bin/bash "$STATE/termux-setup.sh" "$1" </dev/null
}

# Android 12 and later stop apps that run many background programs, which kills
# Claude Code mid-session. This lifts that limit. Two settings can do it; some
# phone makers block the first, so fall back to the second.
remember_limit() { in_termux sh -c "[ -e $STATE/phantom.orig ] || echo '$1' > $STATE/phantom.orig"; }

lift_process_limit() {
  sdk=$(getprop ro.build.version.sdk)
  if [ "$sdk" -lt 31 ]; then echo "Not needed on this Android version."; return; fi
  if [ "$sdk" -ge 32 ]; then
    cur=$(settings get global settings_enable_monitor_phantom_procs 2>/dev/null)
    if [ "$cur" = false ]; then echo "Already set."; return; fi
    if settings put global settings_enable_monitor_phantom_procs false >/dev/null 2>&1; then
      remember_limit "settings ${cur:-null}"
      echo "Background-process limit lifted."
      return
    fi
  fi
  cur=$(device_config get activity_manager max_phantom_processes 2>/dev/null)
  if [ "$cur" = 2147483647 ]; then echo "Already set."; return; fi
  if device_config put activity_manager max_phantom_processes 2147483647 >/dev/null 2>&1; then
    remember_limit "device_config ${cur:-null}"
    echo "Background-process limit lifted."
    return
  fi
  echo "Could not change the setting on this phone. Claude Code will still work, but"
  echo "Android may stop it during long sessions. If that happens, switch on"
  echo "'Disable child process restrictions' in Developer options."
}

restore_process_limit() {
  orig=$(in_termux sh -c "cat $STATE/phantom.orig" 2>/dev/null) || return 0
  set -- $orig
  case "$1" in
    settings)
      if [ "$2" = null ]; then settings delete global settings_enable_monitor_phantom_procs >/dev/null 2>&1
      else settings put global settings_enable_monitor_phantom_procs "$2" 2>/dev/null; fi ;;
    device_config)
      if [ "$2" = null ]; then device_config delete activity_manager max_phantom_processes >/dev/null 2>&1
      else device_config put activity_manager max_phantom_processes "$2" 2>/dev/null; fi ;;
  esac
  echo "Background-process setting restored."
}

# Anything running in Termux besides the app itself and idle shells?
termux_busy() {
  in_termux ps -A -o ARGS 2>/dev/null |
    grep -vE '^(ARGS|com\.termux|-?bash( -l)?|ps -A.*|sh -c.*|\[.*\])[[:space:]]*$' |
    grep -q .
}

# Open Termux with Claude Code already started. Nothing is typed into the phone:
# a one-time marker makes the next new Termux session start it. Never interrupts
# something already running in Termux.
open_claude() {
  how="Open the Termux app on the phone and type: claude"
  if locked; then echo "The phone is locked. $how"; return; fi
  if [ -n "$(pidof "$PKG")" ]; then
    if termux_busy; then echo "Termux is busy with something else. $how"; return; fi
    am force-stop "$PKG"
  fi
  in_termux sh -c "touch $STATE/launch-once"
  am start -n "$PKG/.app.TermuxActivity" >/dev/null 2>&1
  n=0
  while in_termux sh -c "[ -e $STATE/launch-once ]"; do
    n=$((n + 1))
    if [ "$n" -gt 15 ]; then
      in_termux sh -c "rm -f $STATE/launch-once"
      echo "$how"
      return
    fi
    sleep 2
  done
  echo "Claude Code is open on the phone."
}

do_preflight() {
  check_phone
  check_termux
  installed || check_resources
}

do_install() {
  step 1 "Checking the phone"
  do_preflight
  echo "$(getprop ro.product.manufacturer) $(getprop ro.product.model), Android $(getprop ro.build.version.release): OK"

  step 2 "Termux app"
  if [ "$NEED_APK" = 1 ]; then install_termux; else echo "Already installed."; fi
  unpack_termux

  run_in_termux install || exit $?   # steps 3 to 5; prints its own reasons

  step 6 "Phone settings"
  lift_process_limit

  step 7 "Opening Claude Code"
  open_claude

  echo
  echo "DONE. Claude Code is installed on this phone."
  echo "  - You can unplug the phone now. The laptop is no longer needed."
  echo "  - Sign in on the phone when Claude Code asks."
  echo "  - Next time: open the Termux app and type: claude"
  echo "  - USB debugging is still switched on. If you do not need it, switch it off in"
  echo "    Settings > Developer options. Claude Code keeps working without it."
  rm -rf "$DIR"   # the copies of these scripts are no longer needed on the phone
}

do_remove() {
  state=$(termux_state)
  if [ "$REMOVE_TERMUX" = 1 ]; then
    case "$state" in ours|unmarked|empty) restore_process_limit ;; esac
    [ "$state" = absent ] || pm uninstall "$PKG" >/dev/null 2>&1
    echo "Termux and everything inside it has been removed."
  else
    case "$state" in
      ours)
        run_in_termux remove
        restore_process_limit
        in_termux sh -c "rm -rf $STATE"
        echo "Claude Code has been removed. Termux itself, your files and your Claude"
        echo "settings (the .claude folder in Termux) were left in place." ;;
      *) echo "Nothing installed by this installer was found on the phone." ;;
    esac
  fi
  rm -rf "$DIR"
}

# One run at a time.
LOCK=$DIR/lock
if ! mkdir "$LOCK" 2>/dev/null; then
  other=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
    stop 40 "The installer is already running on this phone." "Wait for it to finish, or unplug the phone and plug it back in."
  fi
  rm -rf "$LOCK"; mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

case "$MODE" in
  preflight) do_preflight; [ "$NEED_APK" = 1 ] && [ ! -f "$DIR/termux.apk" ] && exit 3; exit 0 ;;
  install) do_install ;;
  remove) do_remove ;;
  *) echo "usage: setup.sh preflight|install|remove [flags]"; exit 2 ;;
esac
