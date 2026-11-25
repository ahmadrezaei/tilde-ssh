#ifndef CTILDE_BCRYPT_H
#define CTILDE_BCRYPT_H

#include <stddef.h>
#include <stdint.h>

/// Signature of the SHA-512 function the caller supplies, so this target needs no hash implementation.
typedef void (*tilde_sha512_fn)(unsigned char *out, const unsigned char *input, unsigned long long inputLength);

/// Registers the SHA-512 implementation used by `tilde_bcrypt_pbkdf`. Must be called before the first derivation.
void tilde_set_crypto_hash_sha512(tilde_sha512_fn hash_fun);

/// OpenBSD `bcrypt_pbkdf`, the KDF used by encrypted `openssh-key-v1` private keys.
/// Returns 0 on success and -1 on invalid parameters.
int tilde_bcrypt_pbkdf(const unsigned char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
                       uint8_t *key, size_t keylen, unsigned int rounds);

#endif
