#!/usr/bin/env python3
"""
open-agent-harness: Repository RAG Indexer

Indexes a GitHub repository (or local path) into Qdrant for semantic search.
Supports code cells, markdown docs, and arbitrary text files.

Usage:
    python scripts/index_repo.py --repo /path/to/repo \
        --collection code_cells \
        --qdrant-url http://localhost:6333

    python scripts/index_repo.py --repo https://github.com/org/repo \
        --collection code_cells \
        --qdrant-url http://localhost:6333 \
        --clone-dir /tmp/repo_cache

Collections (by agent):
    code_cells      — code expert (notebooks, .py, .ts, .js)
    mfg_standards   — manufacturing AI expert (PDFs, specs, standards)
    curriculum_refs — curriculum expert (syllabi, learning objectives)
    visual_patterns — visual feedback agent (rendered notebook layouts)
    exec_history    — executor agent (cell outputs, error patterns)
    misconception_db— learner simulator (confusion points, misconceptions)
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Generator

# ─── Dependency check ─────────────────────────────────────────────────────────

def check_deps():
    missing = []
    try:
        import qdrant_client  # noqa: F401
    except ImportError:
        missing.append("qdrant-client")

    if missing:
        print(f"[indexer] Missing dependencies: {', '.join(missing)}")
        print("[indexer] Install with: pip install qdrant-client")
        sys.exit(1)

    # Verify Ollama is reachable
    import urllib.request
    try:
        urllib.request.urlopen("http://localhost:11434/api/tags", timeout=3)
    except Exception:
        print("[indexer] Ollama not reachable at http://localhost:11434")
        print("[indexer] Start with: ollama serve")
        sys.exit(1)

# ─── File chunking ─────────────────────────────────────────────────────────────

SUPPORTED_EXTENSIONS = {
    ".py", ".ts", ".js", ".tsx", ".jsx",
    ".md", ".txt", ".rst",
    ".ipynb",
    ".yaml", ".yml", ".json", ".toml",
    ".ex", ".exs",  # Elixir
    ".sh", ".bash",
}

IGNORE_DIRS = {
    ".git", "node_modules", "__pycache__", ".venv", "venv",
    ".next", "dist", "build", "coverage", ".mypy_cache",
    "qdrant_storage",
}


def iter_files(root: Path) -> Generator[Path, None, None]:
    for path in root.rglob("*"):
        if any(part in IGNORE_DIRS for part in path.parts):
            continue
        if path.is_file() and path.suffix in SUPPORTED_EXTENSIONS:
            yield path


def chunk_text(text: str, max_chars: int = 1500, overlap: int = 200) -> list[str]:
    """Split text into overlapping chunks."""
    if len(text) <= max_chars:
        return [text]
    chunks = []
    start = 0
    while start < len(text):
        end = start + max_chars
        chunk = text[start:end]
        # Try to break at a newline
        if end < len(text):
            nl = chunk.rfind("\n")
            if nl > max_chars // 2:
                chunk = text[start:start + nl]
                end = start + nl
        chunks.append(chunk)
        start = end - overlap
    return chunks


def extract_notebook_cells(ipynb_path: Path) -> list[dict]:
    """Extract cells from a Jupyter notebook as structured chunks."""
    try:
        with open(ipynb_path) as f:
            nb = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"[indexer] skip {ipynb_path}: {e}")
        return []

    cells = []
    for i, cell in enumerate(nb.get("cells", [])):
        cell_type = cell.get("cell_type", "unknown")
        source = "".join(cell.get("source", []))
        if not source.strip():
            continue

        outputs = []
        for out in cell.get("outputs", []):
            if "text" in out:
                outputs.append("".join(out["text"]))
            elif "data" in out and "text/plain" in out["data"]:
                outputs.append("".join(out["data"]["text/plain"]))

        cells.append({
            "type": cell_type,
            "index": i,
            "source": source,
            "outputs": "\n".join(outputs)[:500],  # cap output
        })
    return cells


def build_documents(repo_root: Path, collection: str) -> list[dict]:
    """Build a list of document dicts {text, metadata} for indexing."""
    docs = []

    for fpath in iter_files(repo_root):
        rel = fpath.relative_to(repo_root)
        file_id = hashlib.md5(str(rel).encode()).hexdigest()[:8]

        if fpath.suffix == ".ipynb":
            cells = extract_notebook_cells(fpath)
            for cell in cells:
                text = f"# {rel} [cell {cell['index']}] ({cell['type']})\n\n{cell['source']}"
                if cell["outputs"]:
                    text += f"\n\n## Output\n{cell['outputs']}"
                for chunk in chunk_text(text):
                    docs.append({
                        "text": chunk,
                        "metadata": {
                            "source": str(rel),
                            "file_id": file_id,
                            "cell_index": cell["index"],
                            "cell_type": cell["type"],
                            "collection": collection,
                        }
                    })
        else:
            try:
                text = fpath.read_text(errors="replace")
            except OSError:
                continue
            if not text.strip():
                continue

            header = f"# {rel}\n\n"
            for chunk in chunk_text(header + text):
                docs.append({
                    "text": chunk,
                    "metadata": {
                        "source": str(rel),
                        "file_id": file_id,
                        "collection": collection,
                    }
                })

    return docs


# ─── Qdrant indexing ──────────────────────────────────────────────────────────

def embed_text(text: str, ollama_url: str, model: str) -> list[float]:
    """Call Ollama embeddings API directly (no llama-index dependency)."""
    import urllib.request
    import json as _json

    data = _json.dumps({"model": model, "prompt": text}).encode()
    req = urllib.request.Request(
        f"{ollama_url}/api/embeddings",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        result = _json.loads(resp.read())
    return result["embedding"]


def embed_batch(texts: list[str], ollama_url: str, model: str) -> list[list[float]]:
    """Embed a batch of texts sequentially via Ollama REST API."""
    embeddings = []
    for text in texts:
        try:
            embeddings.append(embed_text(text, ollama_url, model))
        except Exception as e:
            print(f"[indexer] embedding error: {e}")
            embeddings.append([])
    return embeddings


def index_documents(
    docs: list[dict],
    collection: str,
    qdrant_url: str,
    ollama_url: str,
    embed_model: str,
    batch_size: int = 16,
):
    from qdrant_client import QdrantClient
    from qdrant_client.models import Distance, VectorParams, PointStruct
    import uuid

    client = QdrantClient(url=qdrant_url)

    # Create or recreate collection
    existing = [c.name for c in client.get_collections().collections]
    if collection not in existing:
        # Probe embedding dimension with a test string
        print(f"[indexer] probing embedding dimension for '{embed_model}'...")
        test_vec = embed_text("test", ollama_url, embed_model)
        dim = len(test_vec)
        print(f"[indexer] creating collection '{collection}' (dim={dim})")
        client.create_collection(
            collection_name=collection,
            vectors_config=VectorParams(size=dim, distance=Distance.COSINE),
        )
    else:
        print(f"[indexer] collection '{collection}' exists — appending")

    total = len(docs)
    indexed = 0

    for i in range(0, total, batch_size):
        batch = docs[i:i + batch_size]
        texts = [d["text"] for d in batch]
        embeddings = embed_batch(texts, ollama_url, embed_model)

        points = [
            PointStruct(
                id=str(uuid.uuid4()),
                vector=list(emb),  # ensure plain list
                payload={**doc["metadata"], "text": doc["text"]},
            )
            for doc, emb in zip(batch, embeddings)
            if emb  # skip empty embeddings from errors
        ]

        if points:
            client.upsert(collection_name=collection, points=points)
        indexed += len(points)
        pct = int(indexed / total * 100)
        print(f"[indexer] indexed {indexed}/{total} ({pct}%)", end="\r")

    print(f"\n[indexer] done — {indexed} chunks in '{collection}'")


# ─── Git clone helper ─────────────────────────────────────────────────────────

def ensure_local_repo(repo: str, clone_dir: str | None) -> Path:
    """If repo is a URL, clone it. Otherwise return as Path."""
    if repo.startswith("http://") or repo.startswith("https://") or repo.startswith("git@"):
        if not clone_dir:
            import tempfile
            clone_dir = tempfile.mkdtemp(prefix="oah_repo_")
        dest = Path(clone_dir)
        if (dest / ".git").exists():
            print(f"[indexer] repo already cloned at {dest}, pulling...")
            subprocess.run(["git", "-C", str(dest), "pull", "--ff-only"], check=False)
        else:
            print(f"[indexer] cloning {repo} → {dest}")
            subprocess.run(["git", "clone", "--depth=1", repo, str(dest)], check=True)
        return dest
    else:
        return Path(repo)


# ─── CLI ──────────────────────────────────────────────────────────────────────

def main():
    check_deps()

    parser = argparse.ArgumentParser(description="Index a repo into Qdrant for OAH agents")
    parser.add_argument("--repo", required=True, help="Local path or git URL to index")
    parser.add_argument("--collection", required=True,
                        choices=["code_cells", "mfg_standards", "curriculum_refs",
                                 "visual_patterns", "exec_history", "misconception_db"],
                        help="Qdrant collection name (agent-specific)")
    parser.add_argument("--qdrant-url", default="http://localhost:6333")
    parser.add_argument("--ollama-url", default="http://localhost:11434")
    parser.add_argument("--embed-model", default="nomic-embed-text",
                        help="Ollama embedding model name")
    parser.add_argument("--clone-dir", default=None,
                        help="Directory to clone repo into (if URL given)")
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--dry-run", action="store_true",
                        help="Print document count without indexing")
    args = parser.parse_args()

    repo_path = ensure_local_repo(args.repo, args.clone_dir)
    print(f"[indexer] scanning {repo_path} → collection '{args.collection}'")

    docs = build_documents(repo_path, args.collection)
    print(f"[indexer] found {len(docs)} chunks")

    if args.dry_run:
        print("[indexer] dry-run — exiting without indexing")
        return

    if len(docs) == 0:
        print("[indexer] no documents found — check --repo path and file extensions")
        sys.exit(1)

    index_documents(
        docs=docs,
        collection=args.collection,
        qdrant_url=args.qdrant_url,
        ollama_url=args.ollama_url,
        embed_model=args.embed_model,
        batch_size=args.batch_size,
    )


if __name__ == "__main__":
    main()
