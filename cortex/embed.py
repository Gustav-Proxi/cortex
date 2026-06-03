"""Embeddings via Ollama (nomic-embed-text), fully local.

nomic-embed-text needs task prefixes:
  - documents are stored with  "search_document: <text>"
  - queries are embedded with  "search_query: <text>"
Getting this wrong silently tanks retrieval quality, so it is enforced here.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Iterable

from . import config


class EmbedError(RuntimeError):
    pass


def _post(path: str, payload: dict) -> dict:
    url = f"{config.OLLAMA_HOST}{path}"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as e:  # connection refused, model missing, etc.
        raise EmbedError(
            f"Ollama request to {url} failed: {e}. "
            "Is Ollama running and is the model pulled? Try: ollama pull "
            f"{config.EMBED_MODEL}"
        ) from e


def _embed_one(text: str) -> list[float]:
    out = _post("/api/embeddings", {"model": config.EMBED_MODEL, "prompt": text})
    vec = out.get("embedding")
    if not vec:
        raise EmbedError(f"No embedding returned for model {config.EMBED_MODEL}: {out}")
    if len(vec) != config.EMBED_DIM:
        raise EmbedError(
            f"Embedding dim {len(vec)} != configured {config.EMBED_DIM}. "
            "Set CORTEX_EMBED_DIM to match the model."
        )
    return vec


def embed_documents(texts: Iterable[str]) -> list[list[float]]:
    return [_embed_one(f"search_document: {t}") for t in texts]


def embed_query(text: str) -> list[float]:
    return _embed_one(f"search_query: {text}")
