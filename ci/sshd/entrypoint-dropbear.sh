#!/bin/sh
# Installs the test public keys, then runs Dropbear in the foreground (-R creates host keys on demand).
set -e

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
install_key rsauser /keys/id_rsa.pub
install_key rsauser /keys/id_rsa4096.pub

# Unlock the key-only accounts (Dropbear refuses locked users).
for user in ed25519user ecdsauser rsauser; do
  echo "$user:$(head -c 24 /dev/urandom | base64)" | chpasswd
done

exec dropbear -F -E -R
