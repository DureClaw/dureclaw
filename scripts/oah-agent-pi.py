#!/usr/bin/env python3
"""
DureClaw edge agent for Raspberry Pi Zero (armv6) — stdlib only, no Bun/Node.

"Local hands, remote brain": the Pi runs the agent loop and real on-device work
(sensors via vcgencmd, GPIO, [SHELL]) locally, but delegates LLM inference to a
remote ollama over HTTP. It registers presence on the Phoenix bus exactly like a
full agent-daemon, so it shows up in the fleet and can participate in tasks and
peer evaluation.

Env: STATE_SERVER (host:port), OAH_SECRET, WORK_KEY, AGENT_NAME, AGENT_ROLE,
     AGENT_MACHINE, OLLAMA_REMOTE_URL, OLLAMA_MODEL
"""
import socket, base64, os, json, time, threading, subprocess, struct, urllib.request, re

HP = os.environ.get("STATE_SERVER", "192.168.0.2:4000").replace("ws://", "").replace("http://", "")
HOST, PORT = HP.split(":"); PORT = int(PORT)
TOKEN = os.environ.get("OAH_SECRET", "")
WK = os.environ.get("WORK_KEY", "WK-2a56b4f1")
NAME = os.environ.get("AGENT_NAME", "executor@pi-zero")
ROLE = os.environ.get("AGENT_ROLE", "executor")
MACHINE = os.environ.get("AGENT_MACHINE", "pi-zero")
OLLAMA = os.environ.get("OLLAMA_REMOTE_URL", "")
MODEL = os.environ.get("OLLAMA_MODEL", "solar:latest")
CAPS = ["edge", "sensor", "gpio", "camera", "os:linux", "arch:armv6l"]

sock = None
ref = [0]
joinref = [None]
lock = threading.Lock()


def nref():
    ref[0] += 1
    return str(ref[0])


def connect():
    global sock
    s = socket.create_connection((HOST, PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    path = "/socket/websocket?vsn=2.0.0" + (("&token=" + TOKEN) if TOKEN else "")
    req = (f"GET {path} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\n"
           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    s.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(1024)
        if not chunk:
            raise Exception("closed during handshake")
        buf += chunk
    if b"101" not in buf.split(b"\r\n")[0]:
        raise Exception("WS upgrade failed: " + buf[:80].decode(errors="replace"))
    sock = s
    print("[pi] WebSocket connected")


def send_frame(text):
    payload = text.encode()
    n = len(payload)
    hdr = bytearray([0x81])  # FIN + text
    mask = os.urandom(4)
    if n < 126:
        hdr.append(0x80 | n)
    elif n < 65536:
        hdr.append(0x80 | 126); hdr += struct.pack(">H", n)
    else:
        hdr.append(0x80 | 127); hdr += struct.pack(">Q", n)
    hdr += mask
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    with lock:
        sock.sendall(bytes(hdr) + masked)


def _recvn(n):
    d = b""
    while len(d) < n:
        c = sock.recv(n - len(d))
        if not c:
            raise Exception("closed")
        d += c
    return d


def recv_frame():
    b1 = _recvn(1)[0]
    b2 = _recvn(1)[0]
    ln = b2 & 0x7f
    if ln == 126:
        ln = struct.unpack(">H", _recvn(2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", _recvn(8))[0]
    data = _recvn(ln) if ln else b""
    op = b1 & 0x0f
    if op == 8:  # close
        return None
    if op in (9, 10):  # ping/pong — ignore
        return ""
    return data.decode(errors="replace")


def push(event, payload):
    send_frame(json.dumps([joinref[0], nref(), "work:" + WK, event, payload]))


def join():
    joinref[0] = nref()
    send_frame(json.dumps([joinref[0], joinref[0], "work:" + WK, "phx_join", {
        "agent_name": NAME, "role": ROLE, "machine": MACHINE,
        "capabilities": CAPS, "preferred_model": "remote", "version": "0.4.0-pi"}]))
    print(f"[pi] joined work:{WK} as {NAME}")


def heartbeat():
    while True:
        time.sleep(15)
        try:
            send_frame(json.dumps([None, nref(), "phoenix", "heartbeat", {}]))
        except Exception:
            return


def remote_gen(prompt):
    if not OLLAMA:
        return ""
    req = urllib.request.Request(
        OLLAMA.rstrip("/") + "/api/generate",
        data=json.dumps({"model": MODEL, "prompt": prompt, "stream": False}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read()).get("response", "")


def parse_score(s):
    m = re.search(r"([01](?:\.\d+)?|0?\.\d+)", s)
    if not m:
        return None
    v = float(m.group(1))
    return min(1.0, max(0.0, v / 100 if v > 1 else v))


def _grp(pat, s, default=""):
    m = re.search(pat, s)
    return m.group(1).strip() if m else default


def handle(p):
    tid = p.get("task_id", "")
    instr = p.get("instructions", "")
    frm = p.get("from", "http@controller")
    up = instr.strip().upper()
    try:
        if up.startswith("[SHELL]"):
            cmd = instr.strip()[7:].strip()
            out = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30).stdout
            push("task.result", {"task_id": tid, "to": frm, "from": NAME, "status": "done",
                                 "output": out.strip()[:1500], "exit_code": 0})
        elif up.startswith("[GRADE]"):
            goal = _grp(r"GOAL:\s*([\s\S]*?)\nRESULT:", instr)
            result = _grp(r"RESULT:\s*([\s\S]*)$", instr)
            graded = _grp(r"GRADED_AGENT:\s*(.+)", instr, "?")
            evalid = _grp(r"EVAL_ID:\s*(.+)", instr) or None
            raw = remote_gen(f"You are grading a result. Reply with ONLY one number 0.00-1.00.\n"
                             f"GOAL:\n{goal}\n\nRESULT:\n{result[:1500]}\n\nScore:")
            sc = parse_score(raw) or 0
            print(f"[pi] graded {graded} -> {sc}")
            push("task.result", {"task_id": tid, "to": frm, "from": NAME, "status": "done",
                                 "score": sc, "graded": graded, "evaluator": NAME,
                                 "eval_id": evalid, "goal": goal[:200],
                                 "output": f"pi-graded {graded}: {sc}"})
        else:  # [EVAL] / generic → remote inference
            goal = re.sub(r"^\s*\[eval\]\s*", "", instr, flags=re.I)
            out = remote_gen(goal)
            push("task.result", {"task_id": tid, "to": frm, "from": NAME, "status": "done",
                                 "output": out.strip()[:1500], "exit_code": 0, "backend": "remote-pi"})
    except Exception as e:
        push("task.result", {"task_id": tid, "to": frm, "from": NAME, "status": "blocked",
                              "output": str(e), "exit_code": 1})


def main():
    while True:
        try:
            connect(); join()
            threading.Thread(target=heartbeat, daemon=True).start()
            while True:
                msg = recv_frame()
                if msg is None:
                    break
                if not msg:
                    continue
                try:
                    _, _, _topic, event, p = json.loads(msg)
                except Exception:
                    continue
                if event == "task.assign":
                    to = p.get("to")
                    if not to or to == NAME or to == "broadcast":
                        threading.Thread(target=handle, args=(p,), daemon=True).start()
        except Exception as e:
            print("[pi] error:", e)
            time.sleep(3)


if __name__ == "__main__":
    main()
