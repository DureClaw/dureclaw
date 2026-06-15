#!/usr/bin/env python3
"""합성 거리 시그널 피더 (Mac/로컬) — 버스로 거리값을 push. serialplot/수집기 데모용.
   실 Pi 센서가 불안정할 때의 신뢰성 있는 대체 소스. 사인파 + 가끔 이상치.

Env: STATE_SERVER(host:port), OAH_SECRET, WORK_KEY, AGENT_NAME, N(횟수), HZ(주기)
"""
import socket, base64, os, json, time, threading, struct, math, random, sys

HP = os.environ.get("STATE_SERVER", "127.0.0.1:4000").replace("ws://", "").replace("http://", "")
HOST, PORT = HP.split(":"); PORT = int(PORT)
TOKEN = os.environ.get("OAH_SECRET", "")
WK = os.environ.get("WORK_KEY", "WK-2a56b4f1")
NAME = os.environ.get("AGENT_NAME", "sensor@sim")
N = int(os.environ.get("N", "100000"))
PERIOD = 1.0 / float(os.environ.get("HZ", "4"))

sock = None; ref = [0]; joinref = [None]; lock = threading.Lock()
def nref(): ref[0] += 1; return str(ref[0])

def connect():
    global sock
    s = socket.create_connection((HOST, PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    path = "/socket/websocket?vsn=2.0.0" + (("&token=" + TOKEN) if TOKEN else "")
    s.sendall((f"GET {path} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        c = s.recv(1024); buf += c
        if not c: raise Exception("closed")
    sock = s

def send_frame(text):
    p = text.encode(); n = len(p); h = bytearray([0x81]); m = os.urandom(4)
    if n < 126: h.append(0x80 | n)
    elif n < 65536: h.append(0x80 | 126); h += struct.pack(">H", n)
    else: h.append(0x80 | 127); h += struct.pack(">Q", n)
    h += m; mm = bytes(b ^ m[i % 4] for i, b in enumerate(p))
    with lock: sock.sendall(bytes(h) + mm)

def push(ev, pl): send_frame(json.dumps([joinref[0], nref(), "work:" + WK, ev, pl]))
def join():
    joinref[0] = nref()
    send_frame(json.dumps([joinref[0], joinref[0], "work:" + WK, "phx_join",
        {"agent_name": NAME, "role": "sensor", "machine": "sim",
         "capabilities": ["sensor", "sim", "distance"], "preferred_model": "sim", "version": "sim-1"}]))
def heartbeat():
    while True:
        time.sleep(15)
        try: send_frame(json.dumps([None, nref(), "phoenix", "heartbeat", {}]))
        except Exception: return

def color(d): return "red" if d < 12 else "yellow" if d < 35 else "green"

def main():
    connect(); join()
    threading.Thread(target=heartbeat, daemon=True).start()
    print(f"[sim] {NAME} → work:{WK}, {1/PERIOD:.0f}Hz 합성 거리 push (Ctrl+C 종료)")
    for i in range(N):
        # 사인파 베이스(20~120cm) + 노이즈, 2%로 이상치(근접/원거리)
        base = 70 + 50 * math.sin(i / 12.0)
        d = max(3, base + random.uniform(-4, 4))
        if random.random() < 0.02:
            d = random.choice([random.uniform(3, 8), random.uniform(180, 260)])
        c = color(d)
        push("task.result", {"task_id": f"sim-{int(time.time())}-{i}", "to": "http@controller",
             "from": NAME, "status": "done", "exit_code": 0, "backend": "sim",
             "output": f"거리 {d:.0f}cm → {c.upper()} (합성 시그널)"})
        if i % 10 == 0: print(f"  [{i}] {d:.0f}cm {c}")
        time.sleep(PERIOD)

if __name__ == "__main__":
    main()
