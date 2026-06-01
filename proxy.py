from __future__ import annotations

import asyncio
import json
import logging
import os
import time

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("obsidian-ollama-proxy")

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

OLLAMA_BASE = os.getenv("OLLAMA_BASE", "http://127.0.0.1:11434")
OLLAMA_API_KEY = os.getenv("OLLAMA_API_KEY", "")
CHAT_MODEL = os.getenv("CHAT_MODEL", "qwen2.5:7b")
EMBED_MODEL = os.getenv("EMBED_MODEL", "mxbai-embed-large")
INFERENCE_PATHS = frozenset(
    {
        "api/generate",
        "api/chat",
        "api/embeddings",
        "v1/chat/completions",
        "v1/embeddings",
    }
)
_pull_locks: dict[str, asyncio.Lock] = {}


def _authorized(request: Request) -> bool:
    if not OLLAMA_API_KEY:
        return True
    auth = request.headers.get("authorization", "")
    return auth == f"Bearer {OLLAMA_API_KEY}"


def _reject_unauthorized() -> JSONResponse:
    return JSONResponse(status_code=401, content={"error": "invalid or missing API key"})


def _model_available(model_names: set[str], target: str) -> bool:
    if target in model_names:
        return True
    prefix = f"{target}:"
    return any(name == target or name.startswith(prefix) for name in model_names)


async def _list_model_names(client: httpx.AsyncClient) -> set[str]:
    resp = await client.get(f"{OLLAMA_BASE}/api/tags")
    resp.raise_for_status()
    return {m.get("name", "") for m in resp.json().get("models", [])}


async def _pull_model(client: httpx.AsyncClient, model: str) -> None:
    lock = _pull_locks.setdefault(model, asyncio.Lock())
    async with lock:
        names = await _list_model_names(client)
        if _model_available(names, model):
            return
        logger.info("Pulling model on first request: %s", model)
        resp = await client.post(
            f"{OLLAMA_BASE}/api/pull",
            json={"name": model},
            timeout=httpx.Timeout(3600.0),
        )
        resp.raise_for_status()
        names = await _list_model_names(client)
        if model == EMBED_MODEL and _model_available(names, f"{EMBED_MODEL}:latest"):
            await client.post(
                f"{OLLAMA_BASE}/api/copy",
                json={"source": f"{EMBED_MODEL}:latest", "destination": EMBED_MODEL},
                timeout=60.0,
            )


def _model_from_body(path: str, body: bytes) -> str | None:
    if path not in INFERENCE_PATHS or not body:
        return None
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return None
    model = payload.get("model")
    return model if isinstance(model, str) and model else None


async def _ensure_model(client: httpx.AsyncClient, model: str | None) -> None:
    if not model:
        return
    names = await _list_model_names(client)
    if _model_available(names, model):
        return
    await _pull_model(client, model)


@app.get("/startup")
async def startup():
    return {"status": "ok"}


@app.get("/status")
async def status():
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(f"{OLLAMA_BASE}/api/tags")
            resp.raise_for_status()
            tags = resp.json().get("models", [])
            model_names = {m.get("name", "") for m in tags}
            required = [CHAT_MODEL, EMBED_MODEL]
            missing = [name for name in required if not _model_available(model_names, name)]
            if missing:
                return {
                    "status": "starting",
                    "ollama": "reachable",
                    "missing_models": missing,
                    "available_models": sorted(model_names),
                }
            return {"status": "ok", "ollama": "reachable", "models": sorted(model_names)}
    except Exception as exc:
        logger.exception("Health check failed")
        return JSONResponse(
            status_code=503,
            content={"status": "error", "detail": str(exc)},
        )


@app.post("/warmup")
async def warmup(request: Request):
    if not _authorized(request):
        return _reject_unauthorized()

    started = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(3600.0)) as client:
            await _ensure_model(client, CHAT_MODEL)
            resp = await client.post(
                f"{OLLAMA_BASE}/api/generate",
                json={
                    "model": CHAT_MODEL,
                    "prompt": "Reply with OK.",
                    "stream": False,
                },
            )
            resp.raise_for_status()
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        logger.info("Warmup completed model=%s latency_ms=%s", CHAT_MODEL, elapsed_ms)
        return {"status": "ok", "model": CHAT_MODEL, "latency_ms": elapsed_ms}
    except Exception as exc:
        logger.exception("Warmup failed")
        return JSONResponse(status_code=503, content={"status": "error", "detail": str(exc)})


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
async def proxy(path: str, request: Request):
    if request.method == "OPTIONS":
        return Response(status_code=204)

    if path not in ("status", "startup") and not _authorized(request):
        return _reject_unauthorized()

    started = time.perf_counter()
    url = f"{OLLAMA_BASE}/{path}"
    body = await request.body()
    headers = dict(request.headers)
    headers.pop("host", None)
    headers.pop("authorization", None)

    model = _model_from_body(path, body)

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(3600.0)) as client:
            if model:
                await _ensure_model(client, model)
            resp = await client.request(
                method=request.method,
                url=url,
                content=body,
                headers=headers,
                params=request.query_params,
            )
            if (
                resp.status_code == 404
                and model
                and b"not found" in resp.content.lower()
            ):
                await _pull_model(client, model)
                resp = await client.request(
                    method=request.method,
                    url=url,
                    content=body,
                    headers=headers,
                    params=request.query_params,
                )
    except Exception as exc:
        logger.exception("Proxy request failed path=%s", path)
        return JSONResponse(status_code=502, content={"error": str(exc)})

    elapsed_ms = int((time.perf_counter() - started) * 1000)
    logger.info(
        "request path=%s method=%s status=%s latency_ms=%s",
        path,
        request.method,
        resp.status_code,
        elapsed_ms,
    )

    return Response(
        content=resp.content,
        status_code=resp.status_code,
        headers=dict(resp.headers),
    )
