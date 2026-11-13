#!/data/data/com.termux/files/usr/bin/bash
# Runs inside Termux, started by setup.sh through run-as.
#   termux-setup.sh install|remove
# Every step checks what is already there first, so running it again is safe.
#
# Markers in ~/.claude-code-android record how far the install got:
#   guest-started      the guest named $GUEST_NAME was created by this installer
#   guest-downloaded   its download finished
#   guest-packages     its packages and the 'claude' user are in place
#   guest-ready        Claude Code is installed in it and starts

ROOT=${CCA_TERMUX_ROOT:-/data/data/com.termux/files}   # CCA_* are for the tests only
export PREFIX=$ROOT/usr
export HOME=$ROOT/home
export PATH=$PREFIX/bin${CCA_TEST_PATH:+:$CCA_TEST_PATH}
export TMPDIR=$PREFIX/tmp
export LANG=en_US.UTF-8
export TERM=xterm-256color
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$TMPDIR"
cd "$HOME" || exit 60

S=$HOME/.claude-code-android
LOG=$S/setup.log
. "$S/versions.env"

CLAUDE_BIN=/home/claude/.local/bin/claude
WRAPPER=$PREFIX/bin/claude
HOOK=$PREFIX/etc/profile.d/claude-code-android.sh
CONTAINER=$PREFIX/var/lib/proot-distro/containers/$GUEST_NAME
# Keep config files the person has edited (confold): this may be their own Termux.
APT="apt-get -y -q -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold"
# Android's own sleep: Termux's can be unusable while Termux upgrades itself.
SLEEP=/system/bin/sleep
[ -x "$SLEEP" ] || SLEEP="sleep"

step() { echo; echo "[$1/7] $2"; }

stop() {
  code=$1; shift
  echo; echo "STOPPED: $1"; shift
  for line; do echo "  $line"; done
  exit "$code"
}

# If the cable is pulled, this script only notices at its next line of output.
# Stop the slow command it was waiting for as well, so nothing is left running
# for the next run to collide with.
CHILD=
cleanup() {
  if [ -n "$CHILD" ]; then
    kill "$CHILD" 2>/dev/null
    # A step inside the guest runs as processes of its own; stop those too.
    # Only while the guest is unfinished: a finished one may be running the
    # person's Claude Code session.
    [ -e "$S/guest-ready" ] || proot-distro kill "$GUEST_NAME" >/dev/null 2>&1
  fi
  rm -f "$S/run.pid"
}
trap cleanup EXIT
trap 'exit 129' HUP PIPE TERM INT

# Run a slow command with its output going to the log, and say something every
# half minute so the person can see it has not frozen.
quiet() {
  "$@" >>"$LOG" 2>&1 </dev/null &
  CHILD=$!
  local waited=0
  while kill -0 "$CHILD" 2>/dev/null; do
    $SLEEP 5
    waited=$((waited + 5))
    if [ $((waited % 30)) -eq 0 ]; then echo "  ...still working ($((waited / 60)) min $((waited % 60)) s)"; fi
  done
  wait "$CHILD"
  local rc=$?
  CHILD=
  return $rc
}

# Network steps get three tries.
retry() {
  local n
  for n in 1 2 3; do
    quiet "$@" && return 0
    [ "$n" -lt 3 ] && { echo "  That did not work; trying again..."; $SLEEP 5; }
  done
  return 1
}

# fail CODE "headline" "advice line" ...   (also shows the end of the setup log)
fail() {
  local code=$1; shift
  echo; echo "STOPPED: $1"; shift
  for line; do echo "  $line"; done
  echo "  Last lines of the phone's setup log:"
  tail -n 12 "$LOG" | sed 's/^/    /'
  exit "$code"
}
NETWORK="This is usually a network problem. Check the phone's internet and run the installer again; it continues from here."

in_guest() { proot-distro login "$GUEST_NAME" "$@"; }

# Prints Claude Code's version if the finished guest can start it.
claude_version() {
  [ -e "$S/guest-ready" ] && in_guest --user claude -- "$CLAUDE_BIN" --version 2>/dev/null
}

# Wait for an earlier run that is still winding down, so two never overlap.
take_over() {
  local other n=0
  other=$(cat "$S/run.pid" 2>/dev/null)
  case "$other" in ''|*[!0-9]*) other= ;; esac
  if [ -n "$other" ] && [ "$other" != $$ ] && grep -q termux-setup "/proc/$other/cmdline" 2>/dev/null; then
    kill "$other" 2>/dev/null
    while kill -0 "$other" 2>/dev/null && [ "$n" -lt 10 ]; do $SLEEP 1; n=$((n + 1)); done
  fi
  echo $$ > "$S/run.pid"
}

install_packages() {
  step 3 "Termux packages"
  # An older proot-distro does not know the options used below; treat it as missing.
  if proot-distro install --help 2>&1 | grep -q -- '--name'; then
    echo "Already installed."
    return
  fi
  echo "Updating Termux and adding the Linux guest tool (a few minutes)..."
  dpkg --configure -a >>"$LOG" 2>&1
  retry $APT update || fail 61 "Could not reach Termux's package servers." "$NETWORK"
  retry $APT full-upgrade || fail 61 "Could not update Termux's packages." "$NETWORK"
  retry $APT install proot-distro || fail 61 "Could not install the Linux guest tool." "$NETWORK"
}

install_guest() {
  step 4 "Linux guest"
  # (guest-packages also counts: installs made before guest-downloaded existed.)
  if [ -d "$CONTAINER" ] && { [ -e "$S/guest-downloaded" ] || [ -e "$S/guest-packages" ]; }; then
    echo "Already downloaded."
    return
  fi
  if [ -d "$CONTAINER" ]; then
    [ -e "$S/guest-started" ] || stop 62 \
      "Termux already has a Linux guest named '$GUEST_NAME' that this installer did not create." \
      "Rename it in Termux (proot-distro rename $GUEST_NAME another-name) and run the installer again."
    # Left half-downloaded by an interrupted run: start it again from clean.
    proot-distro kill "$GUEST_NAME" >>"$LOG" 2>&1
    proot-distro remove "$GUEST_NAME" >>"$LOG" 2>&1
  fi
  echo "Downloading a small Linux system (Debian) into Termux..."
  touch "$S/guest-started"
  rm -f "$S/guest-downloaded" "$S/guest-packages" "$S/guest-ready"
  retry proot-distro install -n "$GUEST_NAME" "$GUEST_IMAGE" || fail 63 "Could not download the Linux guest." "$NETWORK"
  touch "$S/guest-downloaded"
}

install_claude() {
  step 5 "Claude Code"
  local version
  if version=$(claude_version); then
    echo "Already installed: $version"
  else
    if [ ! -e "$S/guest-packages" ]; then
      echo "Preparing the Linux guest (a few minutes)..."
      retry in_guest -- /bin/sh "$S/guest-setup.sh" root || fail 64 "Could not prepare the Linux guest." "$NETWORK"
      touch "$S/guest-packages"
    fi
    echo "Downloading Claude Code from Anthropic..."
    retry in_guest --user claude -- /bin/sh "$S/guest-setup.sh" user || fail 65 "Could not install Claude Code." "$NETWORK"
    touch "$S/guest-ready"
    if ! version=$(claude_version); then
      rm -f "$S/guest-ready"
      fail 66 "Claude Code was installed but does not start on this phone." \
        "Run the installer again. If it stops here again, please report it with the log."
    fi
    echo "Installed: $version"
  fi

  # The 'claude' command in Termux. Anything already there that is not ours
  # (a file, or a link into an npm install) is moved aside untouched.
  if [ -L "$WRAPPER" ] || { [ -e "$WRAPPER" ] && ! grep -q claude-code-android "$WRAPPER"; }; then
    if [ ! -e "$S/claude.backup" ] && [ ! -L "$S/claude.backup" ]; then
      mv "$WRAPPER" "$S/claude.backup"
      echo "Termux already had a 'claude' command. It was set aside and will be put"
      echo "back if you uninstall."
    fi
    rm -f "$WRAPPER"
  fi
  cat > "$WRAPPER.new" <<EOF
#!$PREFIX/bin/bash
# claude-code-android: runs Claude Code inside its Linux guest.
# Settings and sign-in are kept in ~/.claude in Termux, outside the guest,
# so the guest can be rebuilt without losing them.
exec proot-distro login $GUEST_NAME --user claude --work-dir "\$PWD" \\
  --env CLAUDE_CONFIG_DIR="\$HOME/.claude" \\
  --env PATH="/home/claude/.local/bin:/usr/local/bin:/usr/bin:/bin:\$PREFIX/bin" \\
  --env TZ="\$(getprop persist.sys.timezone 2>/dev/null)" \\
  -- $CLAUDE_BIN "\$@"
EOF
  chmod 755 "$WRAPPER.new"
  mv -f "$WRAPPER.new" "$WRAPPER"

  # Lets the installer open Claude Code once without typing on the phone:
  # a new Termux session starts it if the one-time marker is there.
  mkdir -p "${HOOK%/*}"
  cat > "$HOOK" <<'EOF'
# claude-code-android: open Claude Code once, right after the installer finishes.
if [ -e "$HOME/.claude-code-android/launch-once" ]; then
  rm -f "$HOME/.claude-code-android/launch-once"
  claude
fi
EOF
}

remove_all() {
  if [ -e "$S/guest-started" ] && command -v proot-distro >/dev/null; then
    proot-distro kill "$GUEST_NAME" >/dev/null 2>&1
    proot-distro remove "$GUEST_NAME" >/dev/null 2>&1
    echo "Linux guest removed."
  fi
  if [ -e "$WRAPPER" ] && [ ! -L "$WRAPPER" ] && grep -q claude-code-android "$WRAPPER"; then
    rm -f "$WRAPPER"
    if [ -e "$S/claude.backup" ] || [ -L "$S/claude.backup" ]; then
      mv "$S/claude.backup" "$WRAPPER"
      echo "Your earlier 'claude' command was put back."
    fi
  fi
  rm -f "$HOOK"
}

take_over
case "$1" in
  install)
    : > "$LOG"
    install_packages
    install_guest
    install_claude ;;
  remove) remove_all ;;
  *) echo "usage: termux-setup.sh install|remove"; exit 2 ;;
esac
