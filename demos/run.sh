#!/usr/bin/env bash
# demos/run.sh -- run the six camera demos' automatic checks on a running stack.
#
#   demos/run.sh                 all six (the ones whose profile is off: NOT RUN)
#   demos/run.sh 3 6             only those
#   demos/run.sh selftest        prove the graders fail bad answers (no docker)
#   DEMO_CHAT_MODEL=local-chat demos/run.sh      the model Open WebUI demos use
#                                (default local-chat-large; Tier 1: local-chat)
#
# Before the first run:  bin/aistack samples setup && demos/setup.sh
#
# Each demo prints its checks and one JSON line; this prints a table at the end.
# Exit: 0 every demo that ran passed and none was blocked; 1 a demo FAILED;
# 2 nothing failed but a demo was BLOCKED (an owner step is missing) or NOT RUN
# (its profile is off).  2 is never a pass: the table says what was not measured.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"   # every check calls `docker compose` for THIS checkout
export DEMO_DC="${DEMO_DC:-docker compose}"
MODEL="${DEMO_CHAT_MODEL:-local-chat-large}"
LOGS="${DEMO_LOGS:-$(mktemp -d /tmp/aistack-demos.XXXXXX)}"
dc() { ( cd "$ROOT" && $DEMO_DC "$@" ); }
running() { dc ps --status running --services 2>/dev/null | grep -qx "$1"; }

if [ "${1:-}" = selftest ]; then exec python3 "$HERE/lib/selftest.py"; fi
python3 "$HERE/lib/selftest.py" >/dev/null || { echo "demos: the graders' self-test failed: python3 demos/lib/selftest.py" >&2; exit 1; }

NAMES=([1]=01-telegram-research [2]=02-hermes-runs-n8n [3]=03-chat-with-documents
       [4]=04-approval-automation [5]=05-arabic-voice [6]=06-arabic-scan-to-answer)
SEL=("$@"); [ ${#SEL[@]} -gt 0 ] || SEL=(1 2 3 4 5 6)

# Open WebUI demos: helpers + check, piped into python INSIDE open-webui.
owui() {  # owui <demo-dir> <json-args>
  cat "$HERE/lib/owui_common.py" "$HERE/$1/check_owui.py" | dc exec -T open-webui python3 - "$2"
}

run_one() {
  local n="$1" d="${NAMES[$1]}"
  case "$n" in
    1) python3 "$HERE/$d/check.py" ;;
    2) python3 "$HERE/$d/check.py" ;;
    3) owui "$d" "$(python3 - "$HERE" "$MODEL" <<'PY'
import glob, json, os, sys
docs = {os.path.basename(p): open(p, encoding="utf-8").read() for p in sorted(glob.glob(sys.argv[1] + "/fixtures/docs/*.md"))}
print(json.dumps({"model": sys.argv[2], "docs": docs, "keep": os.environ.get("DEMO_KEEP") == "1"}, ensure_ascii=False))
PY
)" ;;
    4) bash "$HERE/$d/check.sh" ;;
    5) running tts-arabic && running stt-arabic || { echo '{"demo": "05-arabic-voice", "status": "NOT RUN", "blocked": "profile voice-arabic is off"}'; return 2; }
       python3 - "$HERE/fixtures/audio" <<'PY' || return 1
import hashlib, json, sys
meta = json.load(open(sys.argv[1] + "/audio.json"))
got = hashlib.sha256(open(sys.argv[1] + "/" + meta["file"], "rb").read()).hexdigest()
sys.exit(0 if got == meta["sha256"] else f"fixture {meta['file']} does not match audio.json ({got})")
PY
       dc exec -T open-webui sh -c 'cat > /tmp/demo5-ar-question.wav' < "$HERE/fixtures/audio/ar-question.wav"
       owui "$d" "{\"model\": \"$MODEL\"}" ;;
    6) running docling-arabic || { echo '{"demo": "06-arabic-scan-to-answer", "status": "NOT RUN", "blocked": "profile docs-arabic is off"}'; return 2; }
       dc exec -T open-webui sh -c 'cat > /tmp/demo6-arabic-scan.pdf' < "$ROOT/samples/fixtures/arabic-scan.pdf"
       owui "$d" "$(python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "expected": json.loads(sys.argv[2])}, ensure_ascii=False))' \
                    "$MODEL" "$(python3 "$ROOT/samples/fixtures/make-arabic-scan.py" --expected)")" ;;
    *) echo "unknown demo '$n' (1-6 or selftest)" >&2; return 1 ;;
  esac
}

echo "AI Stack 2026 - the six demos.  Synthetic data only.  Chat model: $MODEL.  Logs: $LOGS"
declare -A ST TM
worst=0
for n in "${SEL[@]}"; do
  d="${NAMES[$n]:-}"; [ -n "$d" ] || { echo "unknown demo '$n'" >&2; exit 1; }
  echo; echo "== $n. $d"
  t0=$(date +%s)
  run_one "$n" 2>&1 | tee "$LOGS/$d.log"
  rc=${PIPESTATUS[0]}
  TM[$n]=$(( $(date +%s) - t0 ))
  st="$(grep -oE '"status": "[A-Z ]+"' "$LOGS/$d.log" | tail -1 | cut -d'"' -f4)"
  [ -n "$st" ] || st=$([ "$rc" = 0 ] && echo PASS || echo FAIL)
  # a status line that says PASS with a non-zero exit is a FAIL, never the reverse
  [ "$st" = PASS ] && [ "$rc" != 0 ] && st=FAIL
  ST[$n]="$st"
  case "$st" in PASS) ;; FAIL) worst=1 ;; *) [ "$worst" = 1 ] || worst=2 ;; esac
done

echo; echo "== Summary (chat model $MODEL)"
printf '  %-3s %-28s %-8s %s\n' "#" demo status "wall s"
for n in "${SEL[@]}"; do printf '  %-3s %-28s %-8s %s\n' "$n" "${NAMES[$n]}" "${ST[$n]}" "${TM[$n]}"; done
case "$worst" in
  0) echo "  every demo that ran passed" ;;
  1) echo "  at least one demo FAILED -- see its checks above and $LOGS" ;;
  2) echo "  nothing failed, but not everything was measured (BLOCKED / NOT RUN above)" ;;
esac
exit "$worst"
