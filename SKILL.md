---
name: obsidian-copilot-cloudrun
description: >-
  End-to-end setup for Obsidian Copilot with the obsidian-cloudrun-ollama GCP
  deployment. Covers Obsidian install, Copilot plugin, Cloud Run deploy, and
  custom Ollama model configuration. Use when setting up Obsidian with this
  repo, configuring Copilot models, or troubleshooting vault QA / chat.
---

# Obsidian + Copilot + Cloud Run Ollama

Private AI chat and vault QA in Obsidian, backed by Ollama on GCP Cloud Run.

**What you need:** Obsidian (desktop or mobile), a GCP project with billing, `gcloud` CLI, and ~15 minutes for first deploy.

## Checklist

```
- [ ] 1. Install Obsidian and create a vault
- [ ] 2. Install and enable Copilot for Obsidian
- [ ] 3. Deploy obsidian-cloudrun-ollama to Cloud Run
- [ ] 4. Add chat + embedding models in Copilot
- [ ] 5. Enable vault QA and verify
```

---

## 1. Setup Obsidian

1. Download Obsidian from [obsidian.md](https://obsidian.md) (macOS, Windows, Linux, iOS, Android).
2. Open Obsidian → **Create new vault** (or open an existing one).
3. Pick a local folder for your notes. Copilot reads notes in this vault only.

No account required for local vaults.

---

## 2. Add the Copilot plugin

1. **Settings** (gear icon) → **Community plugins**.
2. If prompted, turn **Safe mode** off.
3. Click **Browse**, search **Copilot for Obsidian** (author: Logan Yang).
4. **Install** → **Enable**.
5. Confirm **Copilot** appears in the left ribbon (chat icon).

You do **not** need a Copilot Plus license for custom Ollama models. Skip API keys for OpenAI/Anthropic unless you also want cloud models.

---

## 3. Deploy this repo

### Prerequisites

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`)
- GCP project with billing enabled
- GPU quota for **NVIDIA L4** in your region (default: `us-central1`)

### Deploy

```bash
cd obsidian-cloudrun-ollama
chmod +x deploy.sh start.sh
PROJECT_ID=your-gcp-project-id ./deploy.sh
```

Optional: set `OLLAMA_API_KEY` yourself instead of auto-generating:

```bash
PROJECT_ID=your-gcp-project-id OLLAMA_API_KEY=your-secret ./deploy.sh
```

The script enables APIs, builds the container, creates a GCS bucket for models, and deploys Cloud Run with an L4 GPU.

### Save these values from deploy output

| Value | Example | Used for |
|-------|---------|----------|
| `SERVICE_URL` | `https://obsidian-ollama-xxxxxx.run.app` | Copilot **Base URL** |
| `OLLAMA_API_KEY` | 64-char hex string | Copilot **API key** on each model |

Copy them to a password manager or `.env` (see `.env.example`). **Do not commit `.env`.**

### Verify deployment

```bash
curl -H "Authorization: Bearer ${OLLAMA_API_KEY}" "${SERVICE_URL}/api/tags"
```

First deploy may take **2–5 minutes** while models download to GCS. After idle cold starts, wait 1–2 minutes or call:

```bash
curl -X POST -H "Authorization: Bearer ${OLLAMA_API_KEY}" "${SERVICE_URL}/warmup"
```

---

## 4. Add models in Obsidian Copilot

Open **Settings → Copilot → Model** (or **Basic → Add Model** depending on plugin version).

Add **two** custom models. Use the **same** Base URL and API key for both.

### Chat model

| Field | Value |
|-------|-------|
| Provider | **Ollama** |
| Model name | `qwen2.5:7b` |
| Base URL | Your `SERVICE_URL` (no trailing slash) |
| API key | Your `OLLAMA_API_KEY` |

Set this as the **default chat model** in Copilot.

### Embedding model (required for vault QA)

| Field | Value |
|-------|-------|
| Provider | **Ollama** |
| Model name | `mxbai-embed-large` |
| Base URL | Same `SERVICE_URL` |
| API key | Same `OLLAMA_API_KEY` |

Use the exact name `mxbai-embed-large` — not `mxbai-embed-large:latest`.

Copilot sends `Authorization: Bearer <API key>` automatically for Ollama models, matching standard Ollama client auth.

### Mobile

Use the **identical** Base URL and API key on iOS/Android. The Cloud Run service is public HTTPS; the API key is the gate.

---

## 5. Enable vault features and test

In **Settings → Copilot**:

1. Turn on **Vault QA**, **Semantic search**, and **Index vault** (wording may vary by version).
2. Select the embedding model you added (`mxbai-embed-large`).
3. Run **Reindex vault** (first index can take a while on large vaults).

**Smoke test:**

1. Open Copilot chat → ask a question about a note in your vault.
2. If you see **model not found**, wait for cold start or run `POST /warmup`, then retry.
3. Test vault QA with a question only answerable from your notes.

---

## Defaults reference

| Setting | Value |
|---------|-------|
| Chat model | `qwen2.5:7b` |
| Embedding model | `mxbai-embed-large` |
| Region | `us-central1` |
| Service name | `obsidian-ollama` |
| Readiness endpoint | `GET /status` (no auth) |

For architecture, cost, and troubleshooting, see [README.md](../../../README.md).

## Common issues

| Symptom | Fix |
|---------|-----|
| Model not found after idle | Wait 1–2 min or `POST /warmup`; models load from GCS on cold start |
| 401 Unauthorized | Wrong API key; must match deploy output exactly |
| Vault QA empty / bad results | Confirm embedding model is set and vault is indexed |
| CORS errors | Should not occur with Cloud Run HTTPS; check Base URL has no typo or trailing `/` |
| Deploy fails on GPU | Request L4 quota in GCP Console for your region |
