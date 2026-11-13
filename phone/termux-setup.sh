#!/data/data/com.termux/files/usr/bin/bash
# Runs inside Termux, started by setup.sh through run-as.
#   termux-setup.sh install|remove
# Every step checks what is already there first, so running it again is safe.

export PREFIX=/data/data/com.termux/files/usr
export HOME=/data/data/com.termux/files/home
export PATH=$PREFIX/bin
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
APT="apt-get -y -q -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confnew"

step() { echo; echo "[$1/7] $2"; }

stop() {
  code=$1; shift
  echo; echo "STOPPED: $1"; shift
  for line; do echo "  $line"; done
  exit "$code"
}

# Run a slow command with its output going to the log, and say something every
# half minute so the person can see it has not frozen.
quiet() {
  "$@" >>"$LOG" 2>&1 </dev/null &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    waited=$((waited + 5))
    if [ $((waited % 30)) -eq 0 ]; then echo "  ...still working ($((waited / 60)) min $((waited % 60)) s)"; fi
  done
  wait "$pid"
}

# Network steps get three tries.
retry() {
  local n
  for n in 1 2 3; do
    quiet "$@" && return 0
    [ "$n" -lt 3 ] && { echo "  That did not work; trying again..."; sleep 5; }
  done
  return 1
}

fail_with_log() {
  echo; echo "STOPPED: $1"
  echo "  This is usually a network problem. Check the phone's internet and run the"
  echo "  installer again; it continues from here."
  echo "  Last lines of the phone's setup log:"
  tail -n 12 "$LOG" | sed 's/^/    /'
  exit "$2"
}

in_guest() { proot-distro login "$GUEST_NAME" "$@"; }

guest_ok() {
  [ -e "$S/guest-ready" ] && in_guest --user claude -- "$CLAUDE_BIN" --version >/dev/null 2>&1
}

install_packages() {
  step 3 "Termux packages"
  if command -v proot-distro >/dev/null; then echo "Already installed."; return; fi
  echo "Updating Termux and adding the Linux guest tool (a few minutes)..."
  dpkg --configure -a >>"$LOG" 2>&1
  retry $APT update || fail_with_log "Could not reach Termux's package servers." 61
  retry $APT full-upgrade || fail_with_log "Could not update Termux's packages." 61
  retry $APT install proot-distro || fail_with_log "Could not install the Linux guest tool." 61
}

install_guest() {
  step 4 "Linux guest"
  if guest_ok; then echo "Already installed."; return; fi
  if [ -e "$S/guest-packages" ] && [ -d "$CONTAINER" ]; then echo "Already downloaded."; return; fi
  if [ -d "$CONTAINER" ]; then
    [ -e "$S/guest-started" ] || stop 62 \
      "Termux already has a Linux guest named '$GUEST_NAME' that this installer did not create." \
      "Rename it in Termux (proot-distro rename $GUEST_NAME another-name) and run the installer again."
    # Left half-built by an interrupted run: start it again from clean.
    proot-distro kill "$GUEST_NAME" >>"$LOG" 2>&1
    proot-distro remove "$GUEST_NAME" >>"$LOG" 2>&1
  fi
  echo "Downloading a small Linux system (Debian) into Termux..."
  touch "$S/guest-started"
  rm -f "$S/guest-ready" "$S/guest-packages"
  retry proot-distro install -n "$GUEST_NAME" "$GUEST_IMAGE" || fail_with_log "Could not download the Linux guest." 63
}

install_claude() {
  step 5 "Claude Code"
  if guest_ok; then
    echo "Already installed: $(in_guest --user claude -- "$CLAUDE_BIN" --version 2>/dev/null)"
  else
    if [ ! -e "$S/guest-packages" ]; then
      echo "Preparing the Linux guest (a few minutes)..."
      retry in_guest -- /bin/sh "$S/guest-setup.sh" root || fail_with_log "Could not prepare the Linux guest." 64
      touch "$S/guest-packages"
    fi
    echo "Downloading Claude Code from Anthropic..."
    retry in_guest --user claude -- /bin/sh "$S/guest-setup.sh" user || fail_with_log "Could not install Claude Code." 65
    touch "$S/guest-ready"
    guest_ok || fail_with_log "Claude Code was installed but does not start." 66
    echo "Installed: $(in_guest --user claude -- "$CLAUDE_BIN" --version 2>/dev/null)"
  fi

  # The 'claude' command in Termux.
  if [ -e "$WRAPPER" ] && ! grep -q claude-code-android "$WRAPPER"; then
    [ -e "$S/claude.backup" ] || cp "$WRAPPER" "$S/claude.backup"
    echo "Termux already had a 'claude' command. It was saved and will be put back"
    echo "if you uninstall."
  fi
  cat > "$WRAPPER" <<EOF
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
  chmod 755 "$WRAPPER"

  # Lets the installer open Claude Code once without typing on the phone:
  # a new Termux session starts it if the one-time marker is there.
  cat > "$HOOK" <<'EOF'
# claude-code-android: open Claude Code once, right after the installer finishes.
if [ -e "$HOME/.claude-code-android/launch-once" ]; then
  rm -f "$HOME/.claude-code-android/launch-once"
  claude
fi
EOF
  echo "$TERMUX_VERSION $GUEST_IMAGE" > "$S/installed"
}

remove_all() {
  if [ -e "$S/guest-started" ] && command -v proot-distro >/dev/null; then
    proot-distro kill "$GUEST_NAME" >/dev/null 2>&1
    proot-distro remove "$GUEST_NAME" >/dev/null 2>&1
    echo "Linux guest removed."
  fi
  if [ -e "$WRAPPER" ] && grep -q claude-code-android "$WRAPPER"; then
    rm -f "$WRAPPER"
    if [ -e "$S/claude.backup" ]; then
      cp "$S/claude.backup" "$WRAPPER" && chmod 755 "$WRAPPER"
      echo "Your earlier 'claude' command was put back."
    fi
  fi
  rm -f "$HOOK"
}

case "$1" in
  install)
    : > "$LOG"
    install_packages
    install_guest
    install_claude ;;
  remove) remove_all ;;
  *) echo "usage: termux-setup.sh install|remove"; exit 2 ;;
esac
