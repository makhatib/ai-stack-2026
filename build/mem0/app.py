"""aistack-mem0 — the self-hosted Mem0 REST surface Hermes' Mem0 plugin speaks.

WHY THIS IS NOT THE UPSTREAM `server/` (NOM-413).  The upstream server bundles a
dashboard, JWT user accounts, a second database, request logging and PostHog
telemetry.  Hermes needs five routes and one API key.  This file is the five
routes over the `mem0ai` library, so the thing that runs is the thing we read.

  GET  /health
  POST /memories            {messages, user_id, agent_id, metadata, infer}
  GET  /memories            ?user_id=...
  GET/PUT/DELETE /memories/{id}
  POST /search              {query, filters, top_k}

AUTH.  One key, read from a FILE (AISTACK_MEM0_KEY_FILE), sent as `X-API-Key`
(the header the plugin sends).  Compared in constant time.  No key file -> the
process refuses to start; there is no "auth disabled" mode.

MODELS.  The LLM and embedder are OpenAI-compatible calls to LiteLLM
(`agent` and `embed` aliases), so spend, rate and trace policy live in one place
and Mem0 holds a LiteLLM key, never a provider key.
"""
import hmac
import logging
import os
import sys
from typing import Any, Dict, List, Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

os.environ.setdefault("MEM0_TELEMETRY", "False")
os.environ.setdefault("MEM0_DIR", "/data/.mem0")

from mem0 import Memory  # noqa: E402

log = logging.getLogger("aistack-mem0")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


def _secret(env_file_var: str) -> str:
    path = os.environ.get(env_file_var, "")
    if not path:
        sys.exit(f"{env_file_var} is not set; refusing to start without a secret")
    try:
        value = open(path).read().strip()
    except OSError as e:
        sys.exit(f"cannot read {path}: {e}")
    if not value:
        sys.exit(f"{path} is empty; refusing to start")
    return value


API_KEY = _secret("AISTACK_MEM0_KEY_FILE")
LLM_KEY = _secret("AISTACK_MEM0_LITELLM_KEY_FILE")
DB_PASSWORD = _secret("AISTACK_MEM0_DB_PASSWORD_FILE")
LITELLM_URL = os.environ.get("AISTACK_LITELLM_URL", "http://litellm:4000/v1")
DIMS = int(os.environ.get("AISTACK_EMBED_DIMS", "1024"))

CONFIG = {
    "vector_store": {
        "provider": "pgvector",
        "config": {
            "host": os.environ.get("POSTGRES_HOST", "postgres"),
            "port": 5432,
            "dbname": "mem0",
            "user": "mem0",
            "password": DB_PASSWORD,
            "collection_name": "memories",
            "embedding_model_dims": DIMS,
        },
    },
    "llm": {"provider": "openai", "config": {
        "model": os.environ.get("AISTACK_MEM0_LLM", "agent"),
        "openai_base_url": LITELLM_URL, "api_key": LLM_KEY, "temperature": 0.1}},
    "embedder": {"provider": "openai", "config": {
        "model": os.environ.get("AISTACK_MEM0_EMBEDDER", "embed"),
        "openai_base_url": LITELLM_URL, "api_key": LLM_KEY, "embedding_dims": DIMS}},
    "history_db_path": "/data/history.db",
}

_memory: Optional[Memory] = None


def memory() -> Memory:
    # Lazy: the first call opens the pgvector collection, so /health answers
    # even while Postgres is still starting.
    global _memory
    if _memory is None:
        _memory = Memory.from_config(CONFIG)
    return _memory


def auth(x_api_key: str = Header(default="")):
    if not hmac.compare_digest(x_api_key.encode(), API_KEY.encode()):
        raise HTTPException(status_code=401, detail="invalid or missing X-API-Key")


class Message(BaseModel):
    role: str
    content: str


class MemoryCreate(BaseModel):
    messages: List[Message]
    user_id: Optional[str] = None
    agent_id: Optional[str] = None
    run_id: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None
    infer: Optional[bool] = None


class MemoryUpdate(BaseModel):
    text: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None


class SearchRequest(BaseModel):
    query: str
    filters: Optional[Dict[str, Any]] = None
    top_k: Optional[int] = None
    threshold: Optional[float] = None


app = FastAPI(title="aistack-mem0", docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/memories", dependencies=[Depends(auth)])
def add_memory(body: MemoryCreate):
    if not any([body.user_id, body.agent_id, body.run_id]):
        raise HTTPException(400, "at least one of user_id, agent_id, run_id is required")
    params = {k: v for k, v in body.model_dump().items() if v is not None and k != "messages"}
    return memory().add(messages=[m.model_dump() for m in body.messages], **params)


@app.get("/memories", dependencies=[Depends(auth)])
def list_memories(user_id: Optional[str] = None, agent_id: Optional[str] = None,
                  run_id: Optional[str] = None, top_k: Optional[int] = None):
    filters = {k: v for k, v in {"user_id": user_id, "agent_id": agent_id, "run_id": run_id}.items() if v}
    if not filters:
        raise HTTPException(400, "at least one of user_id, agent_id, run_id is required")
    return memory().get_all(filters=filters, **({"top_k": top_k} if top_k else {}))


@app.get("/memories/{memory_id}", dependencies=[Depends(auth)])
def get_memory(memory_id: str):
    return memory().get(memory_id)


@app.put("/memories/{memory_id}", dependencies=[Depends(auth)])
def update_memory(memory_id: str, body: MemoryUpdate):
    params: Dict[str, Any] = {"memory_id": memory_id}
    if body.text is not None:
        params["data"] = body.text
    if body.metadata is not None:
        params["metadata"] = body.metadata
    return memory().update(**params)


@app.delete("/memories/{memory_id}", dependencies=[Depends(auth)])
def delete_memory(memory_id: str):
    memory().delete(memory_id=memory_id)
    return {"message": "Memory deleted successfully"}


@app.post("/search", dependencies=[Depends(auth)])
def search(body: SearchRequest):
    params: Dict[str, Any] = {}
    if body.top_k is not None:
        params["top_k"] = body.top_k
    if body.threshold is not None:
        params["threshold"] = body.threshold
    return memory().search(query=body.query, filters=body.filters or {}, **params)
