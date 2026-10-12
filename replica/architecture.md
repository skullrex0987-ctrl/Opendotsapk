# LocalMind Architecture — v1.6.1

## Stack

| Layer | Choice | Why |
| --- | --- | --- |
| Mobile | Flutter (Dart) | Single codebase, proven for AI apps, good performance |
| State | Riverpod | Reactive, testable, works well with async model loading |
| Inference | llama.cpp FFI | Fast local inference, supports GGUF, Vision, ONNX |
| Storage | SQLite + sqlite-vec | Offline-first, fast local search, vector embeddings |
| Network | dio + http | Resumable downloads, progress tracking |
| Persistence | shared_preferences | Simple model selection, settings |
| Crypto | pointycastle | Encrypted chat history, local key management |
| UI | Material 3 + custom theme | Modern design system, dark mode native |

## Database Schema (SQLite)

```sql
-- Users (local-only, no cloud)
CREATE TABLE users (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(8)))),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  name TEXT
);

-- Chat sessions
CREATE TABLE chat_sessions (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(8)))),
  user_id TEXT NOT NULL DEFAULT 'local',
  title TEXT NOT NULL DEFAULT 'New Chat',
  model_id TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Messages
CREATE TABLE messages (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(8)))),
  session_id TEXT NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
  content TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  thinking_mode INTEGER NOT NULL DEFAULT 0
);

-- Model downloads
CREATE TABLE model_downloads (
  model_id TEXT PRIMARY KEY,
  status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'downloading', 'completed', 'failed')),
  downloaded_bytes INTEGER NOT NULL DEFAULT 0,
  total_bytes INTEGER NOT NULL,
  started_at TEXT,
  completed_at TEXT
);

-- Embeddings index (sqlite-vec)
CREATE VIRTUAL TABLE embedding_index USING vec0(
  embedding float[384]
);
CREATE TABLE embedding_chunks (
  chunk_id TEXT PRIMARY KEY,
  session_id TEXT REFERENCES chat_sessions(id),
  content TEXT NOT NULL,
  indexed_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_embedding ON embedding_chunks(chunk_id);
```

## API / Services

### Model Manager Service
- `download(modelId)` → Stream<Progress>
- `isInstalled(modelId)` → bool
- `delete(modelId)` → void
- `activeLlmId()` / `setActiveLlmId(id)`
- `activeVisionId()` / `setActiveVisionId(id)`

### LLM Service (llama.cpp FFI)
- `initialize(modelPath, mmprojPath)` → bool
- `chat(prompt, history)` → Stream<String>
- `stop()` → void
- `benchmark()` → BenchmarkResult

### Embedding Service (ONNX)
- `encode(text)` → List<double>
- `search(query, limit)` → List<Document>
- `upsert(sessionId, chunks)` → void

### Document Service
- `ingest(path)` → List<Chunk>
- `supports(type)` → bool

## Key Constraints

1. **Offline-first** — Everything works without network after models are downloaded
2. **RAM budget** — Max ~2GB per model; Qwen3.5 0.8B is the sweet spot
3. **Model download resume** — Range headers, partial file tracking
4. **No cloud API keys by default** — FreeLLM as fallback only
5. **Privacy** — All data stays on device; no telemetry

## Build Order

1. **Vertical slice:** Chat with Qwen2.5 0.5B, download from HuggingFace, stream response
2. **Must-haves:** Multi-model selection, Vision with Qwen3.5, Settings
3. **Should-haves:** Memory search (embeddings), Performance benchmarks
4. **Could-haves:** Agent Skills, Multi-turn with thinking mode

## Next Step
`/replica-design` — build the design system: colors, type scale, spacing, components.
