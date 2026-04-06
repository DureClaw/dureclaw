#!/usr/bin/env python3
"""
oah-agent — Raspberry Pi Zero W (armv6l) Python Phoenix client
Phoenix 5-tuple protocol: [join_ref, ref, topic, event, payload]

환경변수:
  PHOENIX       WS URL (예: ws://192.168.1.10:4000)  ← 구버전 호환
  STATE_SERVER  WS URL (JS daemon과 동일 변수명)
  ROLE          에이전트 역할 (기본: builder)
  NAME          에이전트 이름 (기본: {ROLE}@{hostname})
  WK            Work Key (없으면 자동 발견)
  PROJECT_DIR   작업 디렉토리 (기본: $HOME)
  AGENT_BACKEND AI 백엔드 강제 지정 (claude|opencode|aider|auto)
"""

import asyncio
import json
import os
import platform
import signal
import socket
import subprocess
import sys
import time
from urllib.request import urlopen, Request
from urllib.error import URLError

# ─── websockets 임포트 (pip3 install websockets) ───────────────────────────────
try:
    import websockets
except ImportError:
    print("→ websockets 설치 중... (pip3 install websockets)")
    subprocess.run([sys.executable, "-m", "pip", "install", "--quiet", "websockets"],
                   check=True)
    import websockets

# ─── 설정 ─────────────────────────────────────────────────────────────────────

HOSTNAME = socket.gethostname().split(".")[0]

# PHOENIX env (setup-agent.sh에서 설정) 또는 STATE_SERVER (JS daemon 호환)
_phoenix_raw = (
    os.environ.get("PHOENIX") or
    os.environ.get("STATE_SERVER") or
    "ws://localhost:4000"
)
WS_BASE = _phoenix_raw.rstrip("/")
HTTP_BASE = WS_BASE.replace("wss://", "https://").replace("ws://", "http://")

ROLE = os.environ.get("ROLE") or os.environ.get("AGENT_ROLE") or "builder"
NAME = os.environ.get("NAME") or os.environ.get("AGENT_NAME") or f"{ROLE}@{HOSTNAME}"
WK   = os.environ.get("WK")  or os.environ.get("WORK_KEY") or ""
PROJECT_DIR = os.environ.get("PROJECT_DIR") or os.path.expanduser("~")
AGENT_BACKEND = os.environ.get("AGENT_BACKEND") or "auto"

HEARTBEAT_INTERVAL = 30   # seconds
MAX_RECONNECT_DELAY = 30  # seconds
WK_POLL_RETRIES = 30
WK_POLL_INTERVAL = 2      # seconds

# ─── AI 백엔드 자동 탐지 ──────────────────────────────────────────────────────

def detect_backend() -> str:
    if AGENT_BACKEND != "auto":
        return AGENT_BACKEND
    for cmd in ("claude", "opencode", "aider"):
        try:
            subprocess.run(["which", cmd], capture_output=True, check=True)
            return cmd
        except subprocess.CalledProcessError:
            pass
    return "none"

DETECTED_BACKEND = detect_backend()

# ─── 헬퍼 ─────────────────────────────────────────────────────────────────────

_ref_counter = 0

def next_ref() -> str:
    global _ref_counter
    _ref_counter += 1
    return str(_ref_counter)

def http_get(path: str, timeout: int = 5):
    url = f"{HTTP_BASE}{path}"
    try:
        req = Request(url, headers={"Accept": "application/json"})
        with urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None

def http_post(path: str, body: dict | None = None, timeout: int = 5):
    url = f"{HTTP_BASE}{path}"
    data = json.dumps(body or {}).encode()
    try:
        req = Request(url, data=data, headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
        }, method="POST")
        with urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None

# ─── Work Key 자동 발견 ────────────────────────────────────────────────────────

async def discover_work_key() -> str:
    if WK:
        return WK

    if ROLE == "orchestrator":
        resp = http_post("/api/work-keys")
        if resp and "work_key" in resp:
            wk = resp["work_key"]
            print(f"[wk] created new Work Key: {wk}")
            return wk

    print(f"[wk] polling for Work Key ({WK_POLL_RETRIES}회 × {WK_POLL_INTERVAL}s)...")
    for i in range(WK_POLL_RETRIES):
        resp = http_get("/api/work-keys/latest")
        if resp and "work_key" in resp:
            wk = resp["work_key"]
            print(f"[wk] discovered: {wk}")
            return wk
        await asyncio.sleep(WK_POLL_INTERVAL)

    raise RuntimeError("Work Key를 찾을 수 없습니다. PHOENIX 서버에 Work Key가 없거나 오케스트레이터가 아직 시작하지 않았습니다.")

# ─── 실행 중인 태스크 추적 ─────────────────────────────────────────────────────

active_tasks: dict[str, asyncio.subprocess.Process] = {}  # task_id → process

# ─── Phoenix 채널 클라이언트 ──────────────────────────────────────────────────

class PhoenixAgent:
    def __init__(self, work_key: str):
        self.work_key = work_key
        self.topic = f"work:{work_key}"
        self.join_ref = "1"
        self.ws = None
        self._heartbeat_task: asyncio.Task | None = None
        self._send_lock = asyncio.Lock()

    async def send(self, msg: list):
        async with self._send_lock:
            if self.ws:
                await self.ws.send(json.dumps(msg))

    async def send_event(self, event: str, payload: dict):
        ref = next_ref()
        await self.send([self.join_ref, ref, self.topic, event, payload])

    async def join(self):
        ref = next_ref()
        self.join_ref = ref
        msg = [ref, ref, self.topic, "phx_join", {
            "agent_name": NAME,
            "role": ROLE,
            "machine": "rpi-zero-w",
            "capabilities": ["python3", "shell"] + (
                [DETECTED_BACKEND] if DETECTED_BACKEND != "none" else []
            ),
        }]
        await self.send(msg)
        print(f"[daemon] sent phx_join → {self.topic}")

    async def heartbeat_loop(self):
        while True:
            await asyncio.sleep(HEARTBEAT_INTERVAL)
            if self.ws:
                ref = next_ref()
                await self.send([None, ref, "phoenix", "heartbeat", {}])

    async def handle_message(self, raw: str):
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            return

        if not isinstance(msg, list) or len(msg) < 5:
            return

        _join_ref, _ref, topic, event, payload = msg[0], msg[1], msg[2], msg[3], msg[4]

        if event == "phx_reply":
            status = payload.get("status") if isinstance(payload, dict) else None
            if status == "ok":
                print(f"[daemon] joined channel {topic} ✅")
                # 서버가 PROJECT_DIR을 알려줄 경우 적용
                resp = (payload.get("response") or {}) if isinstance(payload, dict) else {}
                server_dir = resp.get("project_dir") if isinstance(resp, dict) else None
                if server_dir and os.path.isdir(server_dir):
                    global PROJECT_DIR
                    PROJECT_DIR = server_dir
                    print(f"[daemon] PROJECT_DIR set to {PROJECT_DIR}")
            elif status == "error":
                print(f"[daemon] phx_join error: {payload}")
            return

        if event in ("presence_state", "presence_diff"):
            return  # noisy, skip

        if event == "task.assign":
            p = payload if isinstance(payload, dict) else {}
            to = p.get("to")
            if not to or to == NAME or to == "broadcast":
                asyncio.create_task(self.handle_task_assign(p))

        elif event == "task.cancel":
            task_id = payload.get("task_id") if isinstance(payload, dict) else None
            if task_id and task_id in active_tasks:
                proc = active_tasks.pop(task_id)
                try:
                    proc.send_signal(signal.SIGTERM)
                except ProcessLookupError:
                    pass
                print(f"[task] {task_id} cancelled")
                await self.send_event("task.result", {
                    "task_id": task_id,
                    "from": NAME,
                    "status": "cancelled",
                    "output": "Task cancelled by request",
                    "exit_code": -1,
                })
        else:
            print(f"[event] {event} on {topic}")

    async def handle_task_assign(self, payload: dict):
        task_id = payload.get("task_id") or f"task-{int(time.time() * 1000)}"

        # role 필터
        task_role = payload.get("role")
        if task_role and task_role != ROLE:
            print(f"[task] {task_id} is for role '{task_role}', I'm '{ROLE}' — ignoring")
            return

        instructions: str = payload.get("instructions") or ""
        print(f"[task] {task_id}: {instructions[:80]}")

        if instructions.lstrip().startswith("[SHELL]"):
            await self.handle_shell_task(task_id, payload)
        else:
            await self.handle_ai_task(task_id, payload)

    async def handle_shell_task(self, task_id: str, payload: dict):
        instructions: str = payload.get("instructions") or ""
        cmd = instructions.lstrip()
        # [SHELL] prefix 제거
        if cmd.upper().startswith("[SHELL]"):
            cmd = cmd[7:].lstrip()

        print(f"[shell] {task_id}: {cmd[:80]}")
        output = ""
        exit_code = 0

        try:
            proc = await asyncio.create_subprocess_shell(
                cmd,
                cwd=PROJECT_DIR,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            active_tasks[task_id] = proc
            stdout, _ = await proc.communicate()
            exit_code = proc.returncode or 0
            output = stdout.decode(errors="replace").strip()
        except Exception as e:
            output = str(e)
            exit_code = 1
        finally:
            active_tasks.pop(task_id, None)

        await self.send_event("task.result", {
            "task_id": task_id,
            "to": payload.get("from"),
            "from": NAME,
            "role": ROLE,
            "status": "done" if exit_code == 0 else "blocked",
            "output": output,
            "exit_code": exit_code,
            "sys": {
                "machine": HOSTNAME,
                "agent": NAME,
                "role": ROLE,
                "cwd": PROJECT_DIR,
                "os": platform.system().lower(),
            },
        })

    async def handle_ai_task(self, task_id: str, payload: dict):
        instructions: str = payload.get("instructions") or ""
        backend = DETECTED_BACKEND

        if backend == "none":
            await self.send_event("task.result", {
                "task_id": task_id,
                "to": payload.get("from"),
                "from": NAME,
                "role": ROLE,
                "status": "blocked",
                "output": "No AI backend available. Install claude, opencode, or aider.",
                "exit_code": 1,
            })
            return

        print(f"[ai] {task_id} via {backend}: {instructions[:60]}")
        output = ""
        exit_code = 0

        try:
            # AI 백엔드별 커맨드 구성
            if backend == "claude":
                cmd_args = ["claude", "--print", "--no-markdown", instructions]
            elif backend == "opencode":
                cmd_args = ["opencode", "run", "--message", instructions,
                            "--cwd", PROJECT_DIR]
            elif backend == "aider":
                cmd_args = ["aider", "--message", instructions,
                            "--yes", "--no-git",
                            "--working-dir", PROJECT_DIR]
            else:
                cmd_args = [backend, instructions]

            proc = await asyncio.create_subprocess_exec(
                *cmd_args,
                cwd=PROJECT_DIR,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            active_tasks[task_id] = proc
            stdout, _ = await proc.communicate()
            exit_code = proc.returncode or 0
            output = stdout.decode(errors="replace").strip()
        except Exception as e:
            output = str(e)
            exit_code = 1
        finally:
            active_tasks.pop(task_id, None)

        await self.send_event("task.result", {
            "task_id": task_id,
            "to": payload.get("from"),
            "from": NAME,
            "role": ROLE,
            "status": "done" if exit_code == 0 else "blocked",
            "output": output[-4000:] if len(output) > 4000 else output,
            "exit_code": exit_code,
        })

    async def run(self):
        delay = 1
        ws_url = f"{WS_BASE}/socket/websocket?vsn=2.0.0"

        while True:
            try:
                print(f"[daemon] connecting → {ws_url}")
                async with websockets.connect(ws_url, ping_interval=None) as ws:
                    self.ws = ws
                    delay = 1  # 연결 성공 시 재설정

                    await self.join()

                    self._heartbeat_task = asyncio.create_task(self.heartbeat_loop())

                    async for raw in ws:
                        await self.handle_message(raw)

            except (websockets.ConnectionClosed, OSError, ConnectionRefusedError) as e:
                print(f"[daemon] disconnected: {e}")
            except Exception as e:
                print(f"[daemon] error: {e}")
            finally:
                if self._heartbeat_task:
                    self._heartbeat_task.cancel()
                    self._heartbeat_task = None
                self.ws = None

            print(f"[daemon] reconnect in {delay}s...")
            await asyncio.sleep(delay)
            delay = min(delay * 2, MAX_RECONNECT_DELAY)

# ─── 진입점 ───────────────────────────────────────────────────────────────────

async def main():
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print(f" oah-agent  {NAME}  [Python/RPi]")
    print(f" server  →  {WS_BASE}")
    print(f" backend →  {DETECTED_BACKEND}")
    print(f" dir     →  {PROJECT_DIR}")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    work_key = await discover_work_key()
    print(f"[daemon] work key: {work_key}")

    agent = PhoenixAgent(work_key)
    await agent.run()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[daemon] shutdown")
