#!/usr/bin/env bash
# AI Stack 2026 — support-bundle.
#
# EXISTS SO A VIEWER ASKING FOR HELP HAS A REDACTED ARTEFACT TO SEND instead
# of a screenshot of their terminal.  A screenshot is outside any control we
# can enforce; the only answer is to redact at the source and point at this
# command by name.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"
OUT="$ROOT/support-bundle-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

docker compose ps -a > "$W/ps.txt" 2>&1 || true
docker compose config --no-interpolate > "$W/compose-resolved.yaml" 2>&1 || true
docker compose config --images > "$W/images.txt" 2>&1 || true
cp versions.env "$W/" 2>/dev/null || true
cp manifest.yaml limits.yaml security-exceptions.yaml "$W/" 2>/dev/null || true
docker version > "$W/docker-version.txt" 2>&1 || true
uname -a > "$W/uname.txt" 2>&1 || true
bash scripts/doctor.sh > "$W/doctor.txt" 2>&1 || true

mkdir -p "$W/logs"
for s in $(docker compose ps --services 2>/dev/null); do
  docker compose logs --tail 300 --no-color "$s" 2>&1 | bash scripts/redact.sh > "$W/logs/$s.log" || true
done

# .env WITHOUT its values: keys only.  The pin block is safe and useful.
sed -E 's/^([A-Z0-9_]+)=.*/\1=<redacted>/' .env 2>/dev/null \
  | sed -E 's/^(.*_(TAG|IMAGE|DIGEST))=<redacted>/\1/' > "$W/env-keys.txt" || true
grep -E '^[A-Z0-9_]+_(TAG|IMAGE|DIGEST)=' .env >> "$W/env-keys.txt" 2>/dev/null || true

# Everything goes through the redactor a second time, including filenames'
# content, before it is packed.  Belt and braces: this is the artefact a
# stranger will read.
find "$W" -type f -name '*.txt' -o -name '*.yaml' -o -name '*.log' | while read -r f; do
  bash scripts/redact.sh < "$f" > "$f.red" && mv "$f.red" "$f"
done

tar czf "$OUT" -C "$W" .
chmod 0600 "$OUT"
cat <<EOF

Wrote $OUT

It is REDACTED, not guaranteed clean: the filter removes the literal value of
every secret this stack holds plus anything shaped like a key, token, bearer
header or database URL. It cannot catch a secret an application chose to
print in a shape nobody anticipated.

Glance through it before you send it.
EOF
