#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-my-gcp-project-id}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-obsidian-ollama}"
MODELS_BUCKET="${MODELS_BUCKET:-${PROJECT_ID}-ollama-models}"
PERSIST_MODELS="${PERSIST_MODELS:-0}"
PREFETCH_MODELS="${PREFETCH_MODELS:-0}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/obsidian-ai/ollama-cloudrun:latest"

if [[ -z "${OLLAMA_API_KEY:-}" ]]; then
  OLLAMA_API_KEY="$(openssl rand -hex 32)"
  echo "Generated OLLAMA_API_KEY (paste into Obsidian Copilot model API key): ${OLLAMA_API_KEY}"
fi

gcloud config set project "${PROJECT_ID}"

gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com

gcloud artifacts repositories create obsidian-ai \
  --repository-format=docker \
  --location="${REGION}" \
  2>/dev/null || true

VOLUME_ARGS=(
  --add-volume=name=ollama-models,type=in-memory,size-limit=7Gi
  --add-volume-mount=volume=ollama-models,mount-path=/root/.ollama
)

ENV_VARS="OLLAMA_API_KEY=${OLLAMA_API_KEY},CHAT_MODEL=qwen2.5:7b,EMBED_MODEL=mxbai-embed-large,OLLAMA_MODELS_ROOT=/root/.ollama,OLLAMA_KEEP_ALIVE=-1,PERSIST_MODELS=${PERSIST_MODELS},PREFETCH_MODELS=${PREFETCH_MODELS}"

if [[ "${PERSIST_MODELS}" == "1" ]]; then
  gcloud services enable storage.googleapis.com

  if ! gcloud storage buckets describe "gs://${MODELS_BUCKET}" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://${MODELS_BUCKET}" \
      --location="${REGION}" \
      --uniform-bucket-level-access
    echo "Created models bucket: gs://${MODELS_BUCKET}"
  fi

  PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
  RUNTIME_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

  gcloud storage buckets add-iam-policy-binding "gs://${MODELS_BUCKET}" \
    --member="serviceAccount:${RUNTIME_SA}" \
    --role="roles/storage.objectAdmin" \
    --quiet >/dev/null

  VOLUME_ARGS+=(
    --add-volume=name=ollama-persist,type=cloud-storage,bucket="${MODELS_BUCKET}",mount-options=implicit-dirs
    --add-volume-mount=volume=ollama-persist,mount-path=/mnt/ollama-persist
  )
  ENV_VARS="${ENV_VARS},OLLAMA_PERSIST_ROOT=/mnt/ollama-persist"
fi

gcloud builds submit --config cloudbuild.yaml .

gcloud run deploy "${SERVICE}" \
  --image "${IMAGE}" \
  --region "${REGION}" \
  --execution-environment=gen2 \
  --gpu=1 \
  --gpu-type=nvidia-l4 \
  --no-gpu-zonal-redundancy \
  --no-cpu-throttling \
  --cpu=4 \
  --memory=16Gi \
  --min-instances=0 \
  --max-instances=1 \
  --concurrency=1 \
  --timeout=3600 \
  --startup-probe=timeoutSeconds=10,periodSeconds=30,failureThreshold=40,httpGet.port=8080,httpGet.path=/startup \
  --allow-unauthenticated \
  "${VOLUME_ARGS[@]}" \
  --set-env-vars "${ENV_VARS}"

SERVICE_URL="$(gcloud run services describe "${SERVICE}" --region "${REGION}" --format='value(status.url)')"

echo
echo "Deployment complete."
echo "Service URL:    ${SERVICE_URL}"
echo "Ollama API key: ${OLLAMA_API_KEY}"
echo "PERSIST_MODELS: ${PERSIST_MODELS} (0 = fast in-memory only, models load on first request)"
echo "PREFETCH_MODELS: ${PREFETCH_MODELS} (0 = lazy load on first API call)"
if [[ "${PERSIST_MODELS}" == "1" ]]; then
  echo "Models bucket:  gs://${MODELS_BUCKET}"
fi
echo
echo "Obsidian Copilot model settings:"
echo "  Provider:  Ollama"
echo "  Base URL:  ${SERVICE_URL}"
echo "  API key:   ${OLLAMA_API_KEY}"
echo
echo "Test:"
echo "  curl -H \"Authorization: Bearer ${OLLAMA_API_KEY}\" ${SERVICE_URL}/api/tags"
