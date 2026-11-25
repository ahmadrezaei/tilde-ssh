#!/bin/bash
# Regenerates Fixtures/ with the system ssh-keygen (OpenSSH). These are throw-away test keys, safe to commit.
# Passphrase for every *.enc fixture: tilde-test-passphrase
#
#   <name>            unencrypted openssh-key-v1         <name>.pub  public key line
#   <name>.enc        encrypted openssh-key-v1           <name>.fp   `ssh-keygen -lf` output
#   <name>.pem        traditional PEM (RSA / EC)         <name>.art  `ssh-keygen -lv` output (fingerprint + randomart)
#   <name>.p8         PKCS#8
#   <name>.pem.enc / <name>.p8.enc  encrypted variants
set -e
cd "$(dirname "$0")/Fixtures"
PW=tilde-test-passphrase
rm -f ./*

gen() { # name type bits
  if [ "$3" = "-" ]; then
    ssh-keygen -q -t "$2" -N "" -C "fixture-$1@tilde" -f "$1"
  else
    ssh-keygen -q -t "$2" -b "$3" -N "" -C "fixture-$1@tilde" -f "$1"
  fi
}

for spec in "ed25519 ed25519 -" "ecdsa256 ecdsa 256" "ecdsa384 ecdsa 384" "ecdsa521 ecdsa 521" "rsa3072 rsa 3072" "rsa4096 rsa 4096"; do
  set -- $spec
  gen "$1" "$2" "$3"
  cp "$1" "$1.enc"
  ssh-keygen -q -p -f "$1.enc" -P "" -N "$PW" -C "fixture-$1@tilde" > /dev/null
  ssh-keygen -lf "$1.pub" > "$1.fp"
  ssh-keygen -lv -f "$1.pub" > "$1.art"
done

# Other ciphers (ed25519 only).
cp ed25519 ed25519.aes256cbc.enc
ssh-keygen -q -Z aes256-cbc -p -f ed25519.aes256cbc.enc -P "" -N "$PW" > /dev/null
cp ed25519 ed25519.aes128ctr.enc
ssh-keygen -q -Z aes128-ctr -p -f ed25519.aes128ctr.enc -P "" -N "$PW" > /dev/null

# Traditional PEM and PKCS#8 conversions.
for n in rsa3072 ecdsa256 ecdsa384 ecdsa521; do
  cp "$n" "$n.pem"
  ssh-keygen -q -p -m PEM -f "$n.pem" -P "" -N "" > /dev/null
  cp "$n" "$n.pem.enc"
  ssh-keygen -q -p -m PEM -f "$n.pem.enc" -P "" -N "$PW" > /dev/null
done
for n in rsa3072 ecdsa256 ecdsa384 ecdsa521; do
  # Note: the system (LibreSSL) ssh-keygen writes EC PKCS#8 with *explicit* curve parameters.
  cp "$n" "$n.p8"
  ssh-keygen -q -p -m PKCS8 -f "$n.p8" -P "" -N "" > /dev/null
  cp "$n" "$n.p8.enc"
  ssh-keygen -q -p -m PKCS8 -f "$n.p8.enc" -P "" -N "$PW" > /dev/null
done

# Keys made by OpenSSL 3 (named-curve PKCS#8, PBES2 encryption, SEC1, Ed25519 PKCS#8).
# Needs Homebrew OpenSSL: brew install openssl
O=${OPENSSL:-/opt/homebrew/bin/openssl}
$O genpkey -algorithm ed25519 -out ossl-ed25519.p8 2> /dev/null
$O genpkey -algorithm ed25519 -aes-256-cbc -pass "pass:$PW" -out ossl-ed25519.p8.enc 2> /dev/null
$O genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ossl-ecdsa256.p8 2> /dev/null
$O genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -aes-256-cbc -pass "pass:$PW" -out ossl-ecdsa384.p8.enc 2> /dev/null
$O ecparam -name secp521r1 -genkey -noout -out ossl-ecdsa521.sec1 2> /dev/null
$O genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out ossl-rsa3072.p8 2> /dev/null
$O genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -aes-256-cbc -pass "pass:$PW" -out ossl-rsa3072.p8.enc 2> /dev/null
ed_pub() { # key [passin] -> public line (ssh-keygen cannot read Ed25519 PKCS#8)
  local pass="${2:-none}"
  $O pkey -in "$1" -passin "pass:$pass" -pubout -outform DER 2> /dev/null | tail -c 32 | python3 -c '
import sys, base64, struct
pk = sys.stdin.buffer.read()
blob = struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32) + pk
print("ssh-ed25519 " + base64.b64encode(blob).decode())'
}
ed_pub ossl-ed25519.p8 > ossl-ed25519.p8.pub
ed_pub ossl-ed25519.p8.enc "$PW" > ossl-ed25519.p8.enc.pub
ssh-keygen -y -f ossl-ecdsa256.p8 > ossl-ecdsa256.p8.pub
ssh-keygen -y -P "$PW" -f ossl-ecdsa384.p8.enc > ossl-ecdsa384.p8.enc.pub
ssh-keygen -y -f ossl-ecdsa521.sec1 > ossl-ecdsa521.sec1.pub
ssh-keygen -y -f ossl-rsa3072.p8 > ossl-rsa3072.p8.pub
ssh-keygen -y -P "$PW" -f ossl-rsa3072.p8.enc > ossl-rsa3072.p8.enc.pub
for f in ossl-*.pub; do ssh-keygen -lf "$f" | sed 's/ ([A-Z0-9]*)$//' > "${f%.pub}.fp"; done
chmod 600 ossl-* 
ls -la
