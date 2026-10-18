#!/usr/bin/env bash
# AI Stack 2026 — redact at the source.
#
# Every path that shows a viewer text from inside the stack goes through this:
# `aistack logs`, the health-gate failure output, and support-bundle.
#
# REDACTING AT THE SOURCE IS THE ONLY CONTROL WE HAVE.  A screenshot of a
# terminal is outside anything we can enforce, which is exactly why
# `support-bundle` exists and why the docs point at it by name.
#
# This is a filter, not a guarantee.  It catches the shapes secrets in this
# stack actually take; it cannot catch a secret an application chose to print
# in a shape nobody anticipated.  Said plainly so nobody treats a redacted
# bundle as proof that it contains no secret.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# Build a sed program that blanks the LITERAL VALUE of every secret we hold,
# so a secret is removed because it IS the secret, not because it looked like
# one.  This is the half that a regex-only redactor misses.
PROG="$(mktemp)"; trap 'rm -f "$PROG"' EXIT
if [ -d "$ROOT/secrets" ]; then
  while IFS= read -r f; do
    [ -s "$f" ] || continue
    case "$(basename "$f")" in
      *.env)
        while IFS='=' read -r _ v; do
          [ "${#v}" -ge 8 ] && printf 's|%s|<redacted-secret>|g\n' "$(printf '%s' "$v" | sed 's/[|\\&]/\\&/g')" >> "$PROG"
        done < "$f" ;;
      app_db_passwords)
        while IFS='=' read -r _ v; do
          [ "${#v}" -ge 8 ] && printf 's|%s|<redacted-secret>|g\n' "$(printf '%s' "$v" | sed 's/[|\\&]/\\&/g')" >> "$PROG"
        done < "$f" ;;
      *)
        v="$(head -c 4096 "$f" | tr -d '\n')"
        [ "${#v}" -ge 8 ] && printf 's|%s|<redacted-secret>|g\n' "$(printf '%s' "$v" | sed 's/[|\\&]/\\&/g')" >> "$PROG" ;;
    esac
  done < <(find "$ROOT/secrets" -type f 2>/dev/null)
fi

# Shape-based net, second.
cat >> "$PROG" <<'SED'
s|sk-[A-Za-z0-9_-]\{16,\}|<redacted-key>|g
s|\(password\|passwd\|secret\|token\|api[_-]\?key\)\( *[=:] *\)[^ ",;]\{6,\}|\1\2<redacted>|Ig
s|postgresql://\([^:]*\):[^@]*@|postgresql://\1:<redacted>@|g
s|Bearer [A-Za-z0-9._~+/=-]\{12,\}|Bearer <redacted>|g
s|eyJ[A-Za-z0-9_-]\{10,\}\.[A-Za-z0-9_-]\{10,\}\.[A-Za-z0-9_-]*|<redacted-jwt>|g
SED

exec sed -f "$PROG"
