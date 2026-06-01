#!/usr/bin/env bash
set -euo pipefail

MODELS_ROOT="${OLLAMA_MODELS_ROOT:-/root/.ollama}"
PERSIST_ROOT="${OLLAMA_PERSIST_ROOT:-/mnt/ollama-persist}"
PERSIST_MODELS="${PERSIST_MODELS:-0}"
PREFETCH_MODELS="${PREFETCH_MODELS:-0}"
CHAT_MODEL="${CHAT_MODEL:-qwen2.5:7b}"
EMBED_MODEL="${EMBED_MODEL:-mxbai-embed-large}"

OLLAMA_PID=""

clean_partial_files() {
  local root="$1"
  find "${root}" \( -name '*-partial' -o -name '*-partial-*' \) -print -delete 2>/dev/null || true
}

persist_has_models() {
  local root="$1"
  clean_partial_files "${root}"

  local manifests_dir="${root}/models/manifests"
  local blobs_dir="${root}/models/blobs"
  [[ -d "${manifests_dir}" && -n "$(ls -A "${manifests_dir}" 2>/dev/null)" \
    && -d "${blobs_dir}" && -n "$(ls -A "${blobs_dir}" 2>/dev/null)" ]]
}

use_runtime_home() {
  export HOME=/root
  export OLLAMA_MODELS="${MODELS_ROOT}/models"
  mkdir -p "${OLLAMA_MODELS}/blobs" "${OLLAMA_MODELS}/manifests"
}

stop_ollama() {
  if [[ -n "${OLLAMA_PID}" ]] && kill -0 "${OLLAMA_PID}" 2>/dev/null; then
    kill "${OLLAMA_PID}" 2>/dev/null || true
    wait "${OLLAMA_PID}" 2>/dev/null || true
  fi
  OLLAMA_PID=""
}

start_ollama() {
  stop_ollama
  ollama serve &
  OLLAMA_PID=$!

  for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      echo "Ollama is ready (OLLAMA_MODELS=${OLLAMA_MODELS})."
      return 0
    fi
    if [[ "$i" -eq 60 ]]; then
      echo "Ollama failed to start within 60 seconds." >&2
      exit 1
    fi
    sleep 1
  done
}

model_present() {
  local model="$1"
  ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${model}" \
    || ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -q "^${model}"
}

ensure_model() {
  local model="$1"
  if model_present "${model}"; then
    echo "${model} already available."
    return 0
  fi
  echo "Pulling ${model}..."
  ollama pull "${model}"
}

ensure_embed_alias() {
  if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -q "^${EMBED_MODEL}:latest$"; then
    if ! model_present "${EMBED_MODEL}"; then
      echo "Creating ${EMBED_MODEL} alias..."
      ollama cp "${EMBED_MODEL}:latest" "${EMBED_MODEL}" 2>/dev/null || true
    fi
  fi
}

sync_runtime_to_persist() {
  if [[ "${PERSIST_MODELS}" != "1" ]]; then
    return 0
  fi
  echo "Saving models to GCS (background)..."
  mkdir -p "${PERSIST_ROOT}"
  clean_partial_files "${MODELS_ROOT}"
  rsync -a "${MODELS_ROOT}/" "${PERSIST_ROOT}/"
  clean_partial_files "${PERSIST_ROOT}"
}

pull_required_models() {
  ensure_model "${EMBED_MODEL}"
  ensure_embed_alias
  ensure_model "${CHAT_MODEL}"
  sync_runtime_to_persist &
}

prefetch_models() {
  case "${PREFETCH_MODELS}" in
    1|true|yes)
      pull_required_models
      ;;
    background)
      pull_required_models &
      ;;
    *)
      echo "Skipping startup model pull; models load on first request."
      ;;
  esac
}

mkdir -p "${MODELS_ROOT}"

if [[ "${PERSIST_MODELS}" == "1" ]] && persist_has_models "${PERSIST_ROOT}"; then
  echo "Hydrating models from GCS into fast storage (one-time per cold start)..."
  clean_partial_files "${PERSIST_ROOT}"
  rsync -a "${PERSIST_ROOT}/" "${MODELS_ROOT}/"
  clean_partial_files "${MODELS_ROOT}"
fi

use_runtime_home
start_ollama
prefetch_models

echo "Starting proxy on port ${PORT:-8080}..."
cd /app
exec uvicorn proxy:app --host 0.0.0.0 --port "${PORT:-8080}"
