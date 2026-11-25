#!/bin/sh
# Generates the client key pairs the integration tests authenticate with into ci/sshd/keys/ (git-ignored).
# Keys are unencrypted OpenSSH-format files, i.e. what WS3's key service hands the engine.
set -e
cd "$(dirname "$0")"
mkdir -p keys
gen() { # name, ssh-keygen args...
  name="$1"; shift
  [ -f "keys/$name" ] || ssh-keygen -q -N "" -C "tilde-test-$name" -f "keys/$name" "$@"
}
gen id_ed25519 -t ed25519
gen id_ecdsa -t ecdsa -b 256
gen id_ecdsa384 -t ecdsa -b 384
gen id_ecdsa521 -t ecdsa -b 521
gen id_rsa -t rsa -b 2048
gen id_rsa4096 -t rsa -b 4096
echo "keys ready in $(pwd)/keys"
