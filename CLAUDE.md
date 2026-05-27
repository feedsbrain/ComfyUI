# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running ComfyUI

```bash
python main.py
```

Common flags:
- `--listen 0.0.0.0` — expose to the network (default: `127.0.0.1:8188`)
- `--cpu` — run without GPU
- `--preview-method auto` — enable latent previews
- `--front-end-version Comfy-Org/ComfyUI_frontend@latest` — use latest frontend
- `--enable-manager` — enable ComfyUI-Manager
- `--disable-api-nodes` — disable paid external API nodes

## Installing Dependencies

```bash
pip install -r requirements.txt
pip install -r tests-unit/requirements.txt  # for unit tests
```

## Linting

```bash
ruff check .           # runs on all Python files (see pyproject.toml for rule config)
pylint comfy_api_nodes  # only comfy_api_nodes is linted with pylint
```

Ruff ignores: `E501`, `E722`, `E731`, `E712`, `E402`, `E741`. Notebooks and generated stubs are excluded.

## Tests

```bash
# Unit tests (fast, no GPU needed)
python -m pytest tests-unit

# Execution tests
python -m pytest tests/execution -v --skip-timing-checks

# Inference tests (require a running ComfyUI and GPU)
pytest tests/inference

# Save baseline images for quality regression
pytest tests/inference --output_dir tests/inference/baseline
```

Tests are configured in `pytest.ini` — `testpaths` covers both `tests/` and `tests-unit/`. Use `-m "not inference"` or `-m "not execution"` to skip slow tests.

## Database Migrations (Alembic)

```bash
# After updating app/database/models.py:
alembic revision --autogenerate -m "your message"
```

---

## Architecture Overview

### Entry Points

- **`main.py`** — CLI entry point. Parses args, initializes DB, sets up logging, then hands off to `server.py`.
- **`server.py`** — aiohttp web server (`PromptServer`). Manages HTTP routes, WebSocket connections, and the execution queue. All client communication (queue status, progress, previews) flows through WebSocket.
- **`execution.py`** — Prompt executor. Takes a validated prompt (graph), topologically sorts nodes, executes them, and manages caching. This is the core runtime loop.

### Node System

Nodes are the fundamental building blocks. Two styles co-exist:

**V1 (legacy, still widely used):**
```python
class MyNode:
    @classmethod
    def INPUT_TYPES(s): return {"required": {...}}
    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "execute"
    CATEGORY = "my_category"
    def execute(self, ...): return (tensor,)

NODE_CLASS_MAPPINGS = {"MyNode": MyNode}
NODE_DISPLAY_NAME_MAPPINGS = {"MyNode": "My Node"}
```

**V3 (new API, used in `comfy_api_nodes/`):**
```python
from comfy_api.latest import IO, ComfyExtension

class MyNode(IO.ComfyNode):
    @classmethod
    def define_schema(cls):
        return IO.Schema(
            node_id="MyNode",
            display_name="My Node",
            category="my_category",
            inputs=[...],
            outputs=[...],
        )
    @classmethod
    def execute(cls, **kwargs): return IO.NodeOutput(result_tensor)
```

Custom nodes register via `NODE_CLASS_MAPPINGS` (V1) or `comfy_entrypoint` returning a `ComfyExtension` (V3). Both are loaded from the `custom_nodes/` directory at startup in `nodes.py`.

### Core Packages

| Package | Purpose |
|---|---|
| `comfy/` | Model infrastructure: model loading (`sd.py`, `model_detection.py`), VRAM management (`model_management.py`), samplers, VAE, CLIP, ControlNet, LoRA |
| `comfy_execution/` | Graph execution engine: `graph.py` (DAG resolution, `DynamicPrompt`), `caching.py` (output caching strategies), `validation.py`, `progress.py` |
| `comfy_api/` | Versioned node API (`latest/`, `v0_0_1/`, etc.), feature flags, I/O type definitions (`_io.py`) |
| `comfy_api_nodes/` | Partner/paid API nodes (OpenAI, Runway, Luma, etc.) — each `nodes_*.py` maps to a provider, with shared utilities in `util/` |
| `comfy_extras/` | Built-in extended nodes (audio, video, samplers, controlnet, etc.) |
| `app/` | Application services: user management, model file manager, custom node manager, SQLite DB via Alembic, frontend version management |
| `api_server/` | Internal REST routes (`/internal/*`) for frontend use only — not a stable public API |
| `nodes.py` | Registers all built-in nodes; loads custom nodes and comfy_extras at startup |
| `folder_paths.py` | Central registry mapping model type names → filesystem paths (e.g., `checkpoints`, `loras`, `vae`) |

### Execution Flow

1. Client sends a prompt (JSON graph) via HTTP POST `/prompt`.
2. `server.py` validates and enqueues it.
3. `execution.py` (`PromptExecutor.execute`) resolves the DAG via `comfy_execution/graph.py`.
4. Nodes are executed in dependency order; outputs are cached by `comfy_execution/caching.py` — only changed subgraphs re-execute.
5. Progress and preview images are sent back to clients over WebSocket in real time.

### Memory & Model Management

`comfy/model_management.py` handles VRAM state detection (`VRAMState` enum) and decides whether/when to offload models to CPU. Models are wrapped in `ModelPatcher` (`comfy/model_patcher.py`) which enables LoRA patching and hooks without mutating original weights.

### Partner API Nodes (`comfy_api_nodes/`)

Each file (`nodes_openai.py`, `nodes_runway.py`, etc.) implements one or more V3 `IO.ComfyNode` subclasses. The helper functions `sync_op` / `poll_op` in `comfy_api_nodes/util/client.py` route calls through the Comfy proxy API. Category convention: `"api node/<media>/<Provider>"`.

PRs touching `comfy_api_nodes/` automatically get the API node checklist template appended.

### Frontend

The frontend is a separate repository ([ComfyUI_frontend](https://github.com/Comfy-Org/ComfyUI_frontend)) compiled to `web/`. It communicates with the backend exclusively over HTTP and WebSocket. The `web/` directory in this repo is updated fortnightly; use `--front-end-version Comfy-Org/ComfyUI_frontend@latest` to run the latest.
