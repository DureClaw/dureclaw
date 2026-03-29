#!/usr/bin/env bash
# open-agent-harness: Local RAG Stack Setup
# Sets up Qdrant + Ollama + Python deps for agent semantic search
set -euo pipefail

QDRANT_PORT="${QDRANT_PORT:-6333}"
QDRANT_STORAGE="${QDRANT_STORAGE:-$(pwd)/qdrant_storage}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " open-agent-harness | RAG Stack Setup"
echo " Qdrant port : $QDRANT_PORT"
echo " Storage dir : $QDRANT_STORAGE"
echo " Embed model : $EMBED_MODEL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Check Docker ─────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "[setup] Docker not found. Install from https://docs.docker.com/get-docker/"
  exit 1
fi

# ─── Check Ollama ─────────────────────────────────────────────────────────────
if ! command -v ollama &>/dev/null; then
  echo "[setup] Installing Ollama..."
  curl -fsSL https://ollama.ai/install.sh | sh
fi

# Start Ollama in background if not running
if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
  echo "[setup] Starting Ollama daemon..."
  ollama serve &>/tmp/ollama.log &
  sleep 3
fi

# Pull embedding model
echo "[setup] Pulling embedding model: $EMBED_MODEL"
ollama pull "$EMBED_MODEL"

# ─── Start Qdrant ─────────────────────────────────────────────────────────────
mkdir -p "$QDRANT_STORAGE"

# Check if already running
if curl -sf "http://localhost:${QDRANT_PORT}/healthz" &>/dev/null; then
  echo "[setup] Qdrant already running on port $QDRANT_PORT"
else
  echo "[setup] Starting Qdrant..."
  docker run -d \
    --name oah-qdrant \
    --restart unless-stopped \
    -p "${QDRANT_PORT}:6333" \
    -v "${QDRANT_STORAGE}:/qdrant/storage" \
    qdrant/qdrant:latest

  echo "[setup] Waiting for Qdrant..."
  for i in $(seq 1 15); do
    if curl -sf "http://localhost:${QDRANT_PORT}/healthz" &>/dev/null; then
      echo "[setup] Qdrant ready"
      break
    fi
    sleep 2
    echo "[setup] waiting... ($((i*2))s)"
  done
fi

# ─── Python dependencies ──────────────────────────────────────────────────────
echo "[setup] Installing Python RAG dependencies..."
pip3 install --break-system-packages --quiet \
  qdrant-client \
  llama-index \
  llama-index-vector-stores-qdrant \
  llama-index-embeddings-ollama \
  llama-index-readers-file

# ─── Verify ───────────────────────────────────────────────────────────────────
echo ""
echo "[setup] Verification:"
echo -n "  Qdrant: "
curl -sf "http://localhost:${QDRANT_PORT}/healthz" && echo "OK" || echo "FAIL"
echo -n "  Ollama: "
curl -sf "http://localhost:11434/api/tags" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"OK ({len(d.get('models',[]))} models)\")" 2>/dev/null || echo "FAIL"

echo ""
echo "[setup] RAG stack ready. Usage:"
echo "  python scripts/index_repo.py --repo /path/to/repo --collection code_cells"
echo "  python scripts/index_repo.py --repo https://github.com/org/repo --collection mfg_standards"
echo ""
echo "Collections:"
echo "  code_cells       → code-expert agent"
echo "  mfg_standards    → mfg-expert agent"
echo "  curriculum_refs  → curriculum-expert agent"
echo "  visual_patterns  → visual-feedback agent"
echo "  exec_history     → executor agent"
echo "  misconception_db → learner-simulator agent"
