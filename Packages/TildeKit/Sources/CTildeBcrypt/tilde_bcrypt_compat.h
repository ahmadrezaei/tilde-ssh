/*
 * Minimal compatibility definitions for the vendored OpenBSD Blowfish / bcrypt_pbkdf sources
 * (blf.c, blf.h, bcrypt-kdf.c; copied from the copy that ships inside Citadel, with symbols renamed
 * from citadel_* to tilde_* so both can be linked into one binary). Only what bcrypt_pbkdf needs is
 * included; OpenBSD's bcrypt password-hash code is deliberately left out.
 */
#ifndef TILDE_BCRYPT_COMPAT_H
#define TILDE_BCRYPT_COMPAT_H

#include <stdint.h>
#include <string.h>
#include <sys/types.h>

#define explicit_bzero(s, n) memset_s((s), (n), 0, (n))
#define DEF_WEAK(f)

#endif
