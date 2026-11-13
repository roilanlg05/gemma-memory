# gemma-memory

The memory backend for the **Gemma** personal agent.
Designed to run on its own machine (a small Linux box / the home PC), separate from the Mac that hosts the LLM. Talks HTTP only.

Two containers, one network:

```
┌── gemma-memory ─────────────────────────────────────────┐
│                                                          │
│  memory     :8081 (host)                                 │
│    Swift 6 + Hummingbird 2 + GRDB 6 + AsyncHTTPClient    │
│    Persists to /data/memory.sqlite (volume)              │
│    Talks to embedder (internal) and MODEL_URL (Mac)      │
│                                                          │
│  embedder   (internal, not host-exposed)                 │
│    Python 3.11 + FastAPI + sentence-transformers         │
│    Model: BAAI/bge-m3 (1024-dim multilingual)            │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

## Quick start

```bash
cp .env.example .env       # edit MEMORY_BEARER_TOKEN to a long random string
docker compose up -d --build
```

First boot pulls a Swift 6 image, compiles SQLite with `SQLITE_ENABLE_SNAPSHOT`, fetches the BGE-M3 weights (~570MB). 5-10 min once. After that, `up`/`down` is seconds.

Health-check:

```bash
curl -s http://localhost:8081/healthz   # {"status":"ok"}
curl -s http://localhost:8081/readyz    # 200 once embedder is alive
TOKEN=$(grep MEMORY_BEARER_TOKEN .env | cut -d= -f2)
curl -s -X POST http://localhost:8081/v1/memory/save \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"kind":"preference","label":"sushi","body":"like"}'
```

## Configuration

All via environment in `docker-compose.yml`:

| Var | Default | Purpose |
|---|---|---|
| `MEMORY_BEARER_TOKEN` | _(required)_ | Shared secret for `Authorization: Bearer …` on every `/v1/*` route. |
| `MEMORY_DB_PATH` | `/data/memory.sqlite` | SQLite file inside the container; mounted via `./docker-data/memory`. |
| `EMBEDDER_URL` | `http://embedder:8000` | Internal compose DNS. |
| `EMBED_MODEL` | `BAAI/bge-m3` | Model identifier shared by the sidecar and memory service. |
| `EMBED_MODEL_REVISION` | `5617a9f61b028005a4858fdac845db406aefb181` | Immutable model commit. Set it explicitly when changing models. |
| `EMBED_DIM` | `1024` | Expected vector dimension in the memory service. |
| `MODEL_URL` | `http://host.docker.internal:8080` | The Mac running `mlx_vlm.server`. On Linux hosts, add `extra_hosts: ["host.docker.internal:host-gateway"]` (already set in compose). When the model is on a different machine, change to its Tailscale IP. |
| `IDLE_MS` | `180000` | Sleep consolidation idle trigger. |
| `POST_TURN_MS` | `15000` | Post-turn reflection arm. |

### Rebuilding the semantic index

On an existing database, unversioned vectors remain in their original space. The service uses text search until its configured model matches an active version. For a model change, keep the running service on its current embedder and start a separate sidecar for the new version. Run the index commands with access to the same database and the target sidecar. Set `EMBEDDER_URL`, `EMBED_MODEL`, `EMBED_MODEL_REVISION`, and `EMBED_DIM` for that target in the command environment.

```sh
memory-service embedding-index status
memory-service embedding-index rebuild
memory-service embedding-index activate <activation-revision-from-status>
```

Rebuild leaves the active index available. Activation checks that the staged sources still match the database and that the activation revision has not changed. If the source set changed, retry during a period with fewer writes. After activation, point the running service at the new embedder with the same version settings. The service falls back to text search if the sidecar reports a different identity or is unavailable.

## HTTP API (prefix `/v1`, bearer auth)

| Method | Path | Body / Query | Returns |
|---|---|---|---|
| POST | `/v1/transcript/append` | `{threadId, role, text, turnIndex}` | `{}` |
| GET | `/v1/conversation/window` | `?threadId=&maxTurns=&maxChars=` | `{turns:[{role,text}]}` |
| POST | `/v1/memory/save` | `{kind, label, body?, extra?, sourceRef?}` | `{id, mergedInto?}` |
| POST | `/v1/memory/forget` | `{id?} | {label?}` | `{removed:int}` |
| POST | `/v1/memory/recall` | `{query, scope?, limit?}` | `{core:[Node], recall:[Node]}` |
| GET | `/v1/memory/expand` | `?topic=` | `{transcript:[{role,text}], summaryLabel?}` |
| POST | `/v1/consolidation/turn-end` | `{threadId}` | `{}` |
| POST | `/v1/consolidation/reflect` | `{}` | `{cycleId}` |
| GET | `/v1/consolidation/state` | — | `{lastCycle?, nodeCount, transcriptCount, isRunning}` |
| GET | `/v1/nodes` | `?limit=&offset=&kind=` | `{nodes:[Node], total}` |
| GET | `/v1/transcript/recent` | `?limit=` | `{rows:[TranscriptRow]}` |
| GET | `/healthz` | — | `{"status":"ok"}` (public) |
| GET | `/readyz` | — | `200` if embedder reachable; `503` otherwise |

Errors: `{"error":{"code":"…","message":"…"}}` with the matching HTTP status.

## Development (without Docker)

Run natively on macOS while iterating:

```bash
# Terminal 1 — embedder
cd embedder
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000

# Terminal 2 — memory service
cd memory-service
MEMORY_BEARER_TOKEN="dev-token" \
MEMORY_DB_PATH="$HOME/Library/Application Support/Gemma/memory-native/memory.sqlite" \
EMBEDDER_URL="http://127.0.0.1:8000" \
MODEL_URL="http://127.0.0.1:8080" \
MEMORY_PORT=8081 \
swift run -c release memory-service
```

Footprint native: memory-service ≈ 200 MB, embedder ≈ 1 GB. Compose adds ~2-4 GB of Docker VM overhead on macOS; on Linux hosts that overhead is gone.

## Testing

```bash
cd memory-service && swift test           # 94 tests (handlers + core)
cd embedder && .venv/bin/pytest -q        # smoke + ES↔EN cosine
```

## Deploying to the i3 (or anywhere Linux)

`docker compose up -d` is the entire deploy. The compose file expects:

- `./docker-data/memory/` writable for the SQLite file
- A reachable model URL (`MODEL_URL` env) — typically the Tailscale IP of the Mac that runs `mlx_vlm.server`

When the model itself migrates, only `MODEL_URL` changes.

## How the agent client connects

The macOS / iOS Gemma client points a `MemoryClient` at this service's base URL plus the bearer token. No source-level dependency. Settings → Memory Service → fill `Base URL` + `Bearer token`. Restart of either side is not required; the client picks up the new URL via `@AppStorage` onChange.

## License

Internal / personal. Not for distribution yet.
