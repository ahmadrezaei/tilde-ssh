#!/usr/bin/env bash
# Starts a throwaway, unprivileged OpenSSH server for integration tests and prints the environment the tests read.
#
#   eval "$(scripts/ci-sshd.sh start)"     # exports TILDE_TEST_SSH_*
#   scripts/ci-sshd.sh stop
#
# GitHub's macOS runners have no Docker, and TildeKit only builds on Apple platforms, so the integration job runs
# sshd directly on the runner: port 2222 on 127.0.0.1, key-only login as the current user, host and user keys
# generated into a temp directory. Nothing outside that directory is modified.
set -euo pipefail

STATE_DIR="${TILDE_SSHD_DIR:-${TMPDIR:-/tmp}/tilde-sshd}"
PORT="${TILDE_SSHD_PORT:-2222}"

start() {
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  ssh-keygen -q -t ed25519 -N '' -f "$STATE_DIR/host_ed25519"
  ssh-keygen -q -t ed25519 -N '' -C 'tilde-ci-user' -f "$STATE_DIR/user_ed25519"
  ssh-keygen -q -t ecdsa -b 256 -N '' -C 'tilde-ci-user-ecdsa' -f "$STATE_DIR/user_ecdsa"
  ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -C 'tilde-ci-user-rsa' -f "$STATE_DIR/user_rsa"
  cat "$STATE_DIR"/user_*.pub > "$STATE_DIR/authorized_keys"
  chmod 600 "$STATE_DIR/authorized_keys"

  cat > "$STATE_DIR/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $STATE_DIR/host_ed25519
PidFile $STATE_DIR/sshd.pid
AuthorizedKeysFile $STATE_DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
AllowUsers $(id -un)
LogLevel ERROR
EOF

  "$(command -v sshd || echo /usr/sbin/sshd)" -f "$STATE_DIR/sshd_config" -E "$STATE_DIR/sshd.log"

  for _ in $(seq 1 20); do
    if ssh-keyscan -p "$PORT" 127.0.0.1 >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
  ssh-keyscan -p "$PORT" 127.0.0.1 >/dev/null 2>&1 || { echo "sshd did not come up; see $STATE_DIR/sshd.log" >&2; exit 1; }

  cat <<EOF
export TILDE_TEST_SSH_HOST=127.0.0.1
export TILDE_TEST_SSH_PORT=$PORT
export TILDE_TEST_SSH_USER=$(id -un)
export TILDE_TEST_SSH_KEY_ED25519=$STATE_DIR/user_ed25519
export TILDE_TEST_SSH_KEY_ECDSA=$STATE_DIR/user_ecdsa
export TILDE_TEST_SSH_KEY_RSA=$STATE_DIR/user_rsa
export TILDE_TEST_SSH_HOST_KEY=$STATE_DIR/host_ed25519.pub
export TILDE_INTEGRATION=1
EOF
}

stop() {
  if [ -f "$STATE_DIR/sshd.pid" ]; then
    kill "$(cat "$STATE_DIR/sshd.pid")" 2>/dev/null || true
  fi
  rm -rf "$STATE_DIR"
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
