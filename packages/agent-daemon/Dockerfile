# DureClaw agent daemon — runs on any platform Bun supports.
# Build context is the repo root:
#   docker build -f packages/agent-daemon/Dockerfile -t dureclaw-agent .
# Multi-arch (Linux x86, Pi 64/32-bit) is selected per-service via `platform:`.
FROM oven/bun:1-slim

WORKDIR /app

# Install deps first for layer caching.
COPY packages/agent-daemon/package.json ./
RUN bun install

# Daemon source.
COPY packages/agent-daemon/src ./src

# No coding backend is bundled — a containerized node connects, registers
# presence and routes inference remotely (preferred_model) or runs [SHELL]/eval
# tasks. Override AGENT_BACKEND/STATE_SERVER/etc. via the environment.
ENV PROJECT_DIR=/app
CMD ["bun", "run", "src/index.ts"]
