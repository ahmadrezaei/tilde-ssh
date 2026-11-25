#!/bin/sh
# Installs the test public keys for each account, generates host keys on first start, then runs sshd.
set -e

mkdir -p /etc/ssh/sshd_config.d
# Optional extra sshd settings for a role, e.g. "KexAlgorithms diffie-hellman-group14-sha256".
if [ -n "$SSHD_EXTRA" ]; then
  printf '%s\n' "$SSHD_EXTRA" | tr ';' '\n' > /etc/ssh/sshd_config.d/extra.conf
fi

ssh-keygen -A >/dev/null

install_key() {
  user="$1"; pub="$2"
  [ -f "$pub" ] || return 0
  home="/home/$user"
  mkdir -p "$home/.ssh"
  cat "$pub" >> "$home/.ssh/authorized_keys"
  chown -R "$user:$user" "$home/.ssh"
  chmod 700 "$home/.ssh"
  chmod 600 "$home/.ssh/authorized_keys"
}

install_key ed25519user /keys/id_ed25519.pub
install_key ecdsauser /keys/id_ecdsa.pub
install_key ecdsauser /keys/id_ecdsa384.pub
install_key ecdsauser /keys/id_ecdsa521.pub
install_key rsauser /keys/id_rsa.pub
install_key rsauser /keys/id_rsa4096.pub

# Unlock accounts (Alpine locks passwordless users) and start the daemon.
for user in ed25519user ecdsauser rsauser; do
  echo "$user:$(head -c 24 /dev/urandom | base64)" | chpasswd
done

exec /usr/sbin/sshd -D -e
