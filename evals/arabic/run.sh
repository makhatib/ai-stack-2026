#!/usr/bin/env bash
# Arabic tests (DoD 2.8, NOM-418): STT, OCR and chat models on synthetic Arabic data.
#
#   evals/arabic/run.sh all              everything below, in order
#   evals/arabic/run.sh <step> [...]     one step: env stt-models fleurs stt ocr chat score
#   evals/arabic/run.sh stt-audio        re-make the synthetic audio (slow: ~1 min/sentence on CPU)
#   evals/arabic/run.sh ocr-docs         re-make the synthetic scans
#
# Needs: Docker, python3 (stdlib only), the voice-arabic and docs-arabic images built
# (`aistack` with those profiles, or `docker compose --profile voice-arabic --profile
# docs-arabic build`), and internet for the one-time downloads (FLEURS, base Whisper,
# Ollama models).  Every test container runs with --network none except the
# downloaders.  Nothing is published beyond 127.0.0.1.
#
# Settings (env):  EVAL_DATA (downloads; default ~/.cache/aistack-evals)
#                  EVAL_OLLAMA_VOLUMES  space-separated Docker volumes holding the Ollama
#                                       models (default: one new volume aistack-evals-ollama)
#                  EVAL_CHAT_MODELS / EVAL_VLM_MODELS  override the model lists
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RAW="$HERE/results/raw"
DATA="${EVAL_DATA:-$HOME/.cache/aistack-evals}"
mkdir -p "$RAW" "$DATA"
# shellcheck disable=SC1091
set -a; . "$REPO/versions.env"; set +a
OLLAMA_REF="$OLLAMA_IMAGE:$OLLAMA_TAG@$OLLAMA_DIGEST"
PYBASE_REF="$PYBASE_IMAGE:$PYBASE_TAG@$PYBASE_DIGEST"
STT_IMG="aistack-local/stt-arabic:${AISTACK_BUILD_TAG:-v2}"
TTS_IMG="aistack-local/tts-arabic:${AISTACK_BUILD_TAG:-v2}"
DOC_IMG="aistack-local/docling-arabic:${AISTACK_BUILD_TAG:-v2}"
CHAT_MODELS="${EVAL_CHAT_MODELS:-qwen3.5:2b qwen3.5:4b gemma4:e2b qwen3.5:9b}"
VLM_MODELS="${EVAL_VLM_MODELS:-qwen3.5:2b qwen3.5:4b gemma4:e2b}"
OLLAMA_VOLUMES="${EVAL_OLLAMA_VOLUMES:-aistack-evals-ollama}"
PORT_OLLAMA=18434 PORT_DOCLING=18418

say() { printf '\n== %s\n' "$*"; }
need_img() { docker image inspect "$1" >/dev/null 2>&1 || { echo "missing image $1 (build the profile first)"; exit 1; }; }
peak_mb() { docker exec "$1" sh -c 'cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo 0' | awk '{printf "%d", $1/1048576}'; }

step_env() {
  say env
  python3 - "$RAW/env.json" <<PY
import json, os, platform, subprocess, sys, time
def sh(c):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception as e: return f"? {e}"
env = {"date_utc": time.strftime("%Y-%m-%d %H:%M", time.gmtime()), "host": platform.node(),
       "cpu": sh("lscpu | sed -n 's/^Model name: *//p'"), "vcpus": os.cpu_count(),
       # /proc/meminfo, not sysconf: in an LXC guest sysconf reports the host's RAM
       "ram_gib": round(int(open("/proc/meminfo").read().split("MemTotal:")[1].split()[0]) / 2**20, 1),
       "gpu": "none", "kernel": platform.release(), "docker": sh("docker version -f '{{.Server.Version}}'"),
       "loadavg_start": os.getloadavg(), "repo_commit": sh("git -C '$REPO' rev-parse --short HEAD"),
       "images": {k: sh(f"docker image inspect -f '{{{{.Id}}}}' {v}")[:19] for k, v in
                  {"stt": "$STT_IMG", "tts": "$TTS_IMG", "docling": "$DOC_IMG", "ollama": "$OLLAMA_REF"}.items()},
       "ollama": "$OLLAMA_TAG"}
json.dump(env, open(sys.argv[1], "w"), indent=1); print(json.dumps(env, indent=1))
PY
}

step_stt_audio() {
  say "stt-audio: synthetic speech with the voice-arabic TTS (Chatterbox, built-in voice)"
  need_img "$TTS_IMG"
  docker run --rm --network none --cpus 4 --memory 8g -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$HERE/stt:/eval/stt" \
    --entrypoint python "$TTS_IMG" /eval/stt/make_audio.py /eval/stt "$@"
}

step_stt_models() {
  say "stt-models: base Whisper large-v3-turbo (CT2) for the comparison"
  need_img "$STT_IMG"
  mkdir -p "$DATA/models"
  docker run --rm -v "$DATA/models:/models" -v "$HERE/stt:/eval/stt:ro" -w /eval/stt -u "$(id -u):$(id -g)" \
    -e HF_HOME=/tmp/hf -e HF_HUB_OFFLINE=0 \
    --entrypoint python "$STT_IMG" /app/fetch_models.py /models/whisper-large-v3-turbo-ct2
}

step_fleurs() {
  say "fleurs: human-speech control clips (CC-BY-4.0), checked against stt/fleurs.lock"
  python3 "$HERE/stt/fetch_fleurs.py" "$DATA/fleurs"
}

step_stt() {
  say "stt: fine-tune vs base, same image, same settings, one container each"
  need_img "$STT_IMG"
  [ -f "$DATA/fleurs/refs.jsonl" ] || step_fleurs
  [ -f "$DATA/models/whisper-large-v3-turbo-ct2/model.bin" ] || step_stt_models
  cp "$DATA/fleurs/refs.jsonl" "$RAW/fleurs-refs.jsonl"
  local ls=$(ls "$HERE"/stt/audio/*.wav | wc -l)
  [ "$ls" -gt 0 ] || { echo "no synthetic audio in stt/audio"; exit 1; }
  for m in "whisper-v3-turbo-ar-ft=/models/whisper-ar" "whisper-v3-turbo-base=/data/models/whisper-large-v3-turbo-ct2"; do
    docker run --rm --network none --cpus 4 --memory 4g -u "$(id -u):$(id -g)" \
      -v "$HERE:/eval:ro" -v "$RAW:/out" -v "$DATA:/data:ro" -e PYTHONPATH=/eval/lib \
      --entrypoint python "$STT_IMG" /eval/stt/run_stt.py "${m#*=}" "${m%%=*}" "/out/stt-${m%%=*}.jsonl" \
      /eval/stt=synthetic /data/fleurs=fleurs
  done
}

step_ocr_docs() {
  say "ocr-docs: synthetic scans"
  docker run --rm --cpus 1 -v "$HERE/ocr:/w" -w /w "$PYBASE_REF" sh -c \
    "apt-get update -qq && apt-get install -y -qq libraqm0 fonts-noto-core >/dev/null \
     && pip install -q --root-user-action=ignore pillow==12.0.0 fonttools==4.60.1 && python make_docs.py \
     && chown -R $(id -u):$(id -g) docs"
}

ollama_up() {   # $1 = model; starts a fresh container on the volume that holds it
  docker rm -f n418-eval-ollama >/dev/null 2>&1 || true
  local vol
  for vol in $OLLAMA_VOLUMES; do
    if docker run --rm -v "$vol:/m:ro" --entrypoint sh "$OLLAMA_REF" -c "test -f /m/models/manifests/registry.ollama.ai/library/${1%%:*}/${1#*:}"; then
      break
    fi
    vol=""
  done
  if [ -z "$vol" ]; then vol="${OLLAMA_VOLUMES%% *}"; fi
  docker run -d --name n418-eval-ollama -p 127.0.0.1:$PORT_OLLAMA:11434 --cpus 4 --memory 14g \
    -e OLLAMA_NOPRUNE=1 -e OLLAMA_MAX_LOADED_MODELS=1 -e OLLAMA_NUM_PARALLEL=1 -e OLLAMA_KEEP_ALIVE=30m \
    -v "$vol:/root/.ollama" "$OLLAMA_REF" >/dev/null
  for _ in $(seq 60); do curl -sf -m2 "127.0.0.1:$PORT_OLLAMA/api/version" >/dev/null && break; sleep 1; done
  # pull only if the manifest is absent (checking `ollama list` raced the server start
  # and re-pulled a model that was already there)
  docker exec n418-eval-ollama test -f "/root/.ollama/models/manifests/registry.ollama.ai/library/${1%%:*}/${1#*:}" \
    || docker exec n418-eval-ollama ollama pull "$1"
  local want got
  want=$(awk -v m="$1" '$1==m {print $2}' "$HERE/chat/models.lock")
  [ -n "$want" ] || { echo "$1 is not in chat/models.lock"; exit 1; }
  got=$(docker exec n418-eval-ollama sh -c "cat /root/.ollama/models/manifests/registry.ollama.ai/library/${1%%:*}/${1#*:}" \
        | python3 -c 'import sys,json; print([l["digest"] for l in json.load(sys.stdin)["layers"] if l["mediaType"].endswith(".model")][0][7:])')
  [ "$got" = "$want" ] || { echo "$1: weights $got, chat/models.lock says $want — refusing"; exit 1; }
  echo "$1 weights verified ($want)"
}

step_ocr() {
  say "ocr: Tesseract alone, Docling + Tesseract (the docs-arabic profile), vision models"
  need_img "$DOC_IMG"
  docker rm -f n418-eval-docling >/dev/null 2>&1 || true
  docker run -d --name n418-eval-docling -p 127.0.0.1:$PORT_DOCLING:5001 --cpus 4 --memory 4g \
    -e DOCLING_SERVE_ENABLE_UI=false -e DOCLING_SERVE_ALLOW_EXTERNAL_PLUGINS=false \
    -e DOCLING_SERVE_MAX_SYNC_WAIT=600 -e HF_HUB_OFFLINE=1 \
    -v "${EVAL_DOCLING_MODELS:-aistack-docling-arabic-models}:/opt/app-root/src/.cache:ro" \
    -v "$HERE/ocr/docs:/docs:ro" "$DOC_IMG" >/dev/null
  for _ in $(seq 120); do curl -sf -m2 "127.0.0.1:$PORT_DOCLING/health" >/dev/null && break; sleep 2; done
  python3 "$HERE/ocr/run_ocr.py" tesseract n418-eval-docling "$RAW/ocr-tesseract.jsonl"
  echo "{\"engine\": \"tesseract-4.1.1-ara+eng\", \"cgroup_peak_mb\": $(peak_mb n418-eval-docling)}" > "$RAW/mem-ocr-tesseract.json"
  docker restart n418-eval-docling >/dev/null
  for _ in $(seq 120); do curl -sf -m2 "127.0.0.1:$PORT_DOCLING/health" >/dev/null && break; sleep 2; done
  python3 "$HERE/ocr/run_ocr.py" docling "http://127.0.0.1:$PORT_DOCLING" "$RAW/ocr-docling-tesseract.jsonl" tesseract ara,eng
  echo "{\"engine\": \"docling-tesseract\", \"cgroup_peak_mb\": $(peak_mb n418-eval-docling)}" > "$RAW/mem-ocr-docling-tesseract.json"
  docker rm -f n418-eval-docling >/dev/null
  for m in $VLM_MODELS; do
    ollama_up "$m"
    python3 "$HERE/ocr/run_ocr.py" vlm "http://127.0.0.1:$PORT_OLLAMA" "$RAW/ocr-vlm-${m/:/-}.jsonl" "$m"
    echo "{\"engine\": \"vlm-$m\", \"cgroup_peak_mb\": $(peak_mb n418-eval-ollama), \"ollama_ps\": \"$(docker exec n418-eval-ollama ollama ps | tail -n +2 | tr -s ' ' | tr -d '"')\"}" > "$RAW/mem-ocr-vlm-${m/:/-}.json"
  done
  docker rm -f n418-eval-ollama >/dev/null 2>&1 || true
}

step_chat() {
  say "chat: fixed question set, one fresh chat per question"
  for m in $CHAT_MODELS; do
    ollama_up "$m"
    python3 "$HERE/chat/run_chat.py" "http://127.0.0.1:$PORT_OLLAMA" "$m" "$RAW/chat-${m/:/-}.jsonl"
    echo "{\"model\": \"$m\", \"cgroup_peak_mb\": $(peak_mb n418-eval-ollama), \"ollama_ps\": \"$(docker exec n418-eval-ollama ollama ps | tail -n +2 | tr -s ' ' | tr -d '"')\"}" > "$RAW/mem-chat-${m/:/-}.json"
  done
  docker rm -f n418-eval-ollama >/dev/null 2>&1 || true
}

step_score() {
  say score
  python3 "$HERE/lib/arnorm.py"
  python3 "$HERE/score.py" --selftest
  python3 "$HERE/score.py"
  python3 "$HERE/report.py"
}

case "${1:-}" in
  all) step_env; step_stt; step_ocr; step_chat; step_score ;;
  env|stt|ocr|chat|score|fleurs) "step_$1" ;;
  stt-models) step_stt_models ;;
  stt-audio) shift; step_stt_audio "$@" ;;
  ocr-docs) step_ocr_docs ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
