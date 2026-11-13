#!/bin/sh
# Runs inside the Linux guest, started by termux-setup.sh.
#   guest-setup.sh root   packages and the 'claude' user (run as root)
#   guest-setup.sh user   Claude Code itself (run as the 'claude' user)
set -e

case "$1" in
  root)
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a
    apt-get update
    apt-get install -y --no-install-recommends curl ca-certificates git tzdata
    id claude >/dev/null 2>&1 || useradd -m -s /bin/bash claude
    ;;
  user)
    cd "$HOME"
    # Anthropic's own installer. Download first, then run, so a broken download
    # is never executed half-way.
    curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh
    bash /tmp/claude-install.sh
    rm -f /tmp/claude-install.sh
    "$HOME/.local/bin/claude" --version
    ;;
  *) echo "usage: guest-setup.sh root|user"; exit 2 ;;
esac
