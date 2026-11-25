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

/// A cancellation flag that another thread can raise while a derivation runs.
typedef struct tilde_cancel tilde_cancel_t;
tilde_cancel_t *tilde_cancel_create(void);
void tilde_cancel_request(tilde_cancel_t *cancel);
void tilde_cancel_destroy(tilde_cancel_t *cancel);

/// Like `tilde_bcrypt_pbkdf`, but polls `cancel` between rounds. Returns -2 if cancelled (key is zeroed).
int tilde_bcrypt_pbkdf_cancellable(const unsigned char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
                                   uint8_t *key, size_t keylen, unsigned int rounds, tilde_cancel_t *cancel);

#endif
