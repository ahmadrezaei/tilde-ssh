#!/usr/bin/env bash
# Fails if a logging or printing call mentions secret-looking names or key material.
# Rule (docs/DESIGN.md section 10.4): no secrets in logs.
#
# A line is flagged when it contains a logging call AND either
#   - a private-key marker ("BEGIN OPENSSH", "BEGIN RSA", "BEGIN EC", "BEGIN PRIVATE"), or
#   - a secret-named value being logged: interpolated (\(password), \(key.privateKey)) or passed as an argument
#     (print(passphrase), logger.debug(secret)).
#   calls:   print( debugPrint( NSLog( os_log( Logger( logger. log. .debug( .info( .notice( .error( .fault( .warning(
#   secrets: password passphrase privateKey private_key secret
# A message that merely names the concept ("password authentication failed") is fine.
# Escape hatch for a reviewed false positive: end the line with `// log-ok: <reason>`.
#
# Usage: scripts/check-log-secrets.sh [path ...]     (defaults to Packages/TildeKit/Sources and App)
set -euo pipefail

cd "$(dirname "$0")/.."
paths=("$@")
if [ ${#paths[@]} -eq 0 ]; then paths=(Packages/TildeKit/Sources App); fi

calls='(print\(|debugPrint\(|NSLog\(|os_log\(|Logger\(|[Ll]ogger\.|[^A-Za-z]log\.|\.(debug|info|notice|error|fault|warning|trace)\()'
names='(password|passphrase|privateKey|private_key|secret)'
secrets="(BEGIN (OPENSSH|RSA|EC|PRIVATE)|\\\\\\([^)]*${names}|\\((${names}[A-Za-z]*)[,)])"

hits=$(grep -rnIE --include='*.swift' "$calls" "${paths[@]}" 2>/dev/null \
  | grep -iE "$secrets" \
  | grep -v 'log-ok' || true)

if [ -n "$hits" ]; then
  echo "error: possible secret in a log call:" >&2
  echo "$hits" >&2
  echo >&2
  echo "Never log passwords, passphrases or key material. See docs/DESIGN.md section 6.4." >&2
  exit 1
fi
echo "log check ok"
