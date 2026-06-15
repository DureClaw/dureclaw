#!/usr/bin/env python3
"""DureClaw 시그널 수집기 — 버스(work 채널)를 구독해 센서 시그널을 CSV로 기록.
   linux-builder(수집/학습 노드)에서 실행. Pi Zero의 거리 시그널을 데이터셋화.

Env: STATE_SERVER(host:port), OAH_SECRET, WORK_KEY, OUT(csv 경로), DURATION(초), AGENT_NAME
"""
import socket, base64, os, json, time, threading, struct, sys, re, csv

HP = os.environ.get("STATE_SERVER", "100.108.196.12:4000").replace("ws://", "").replace("http://", "")
HOST, PORT = HP.split(":"); PORT = int(PORT)
TOKEN = os.environ.get("OAH_SECRET", "")
WK = os.environ.get("WORK_KEY", "WK-2a56b4f1")
NAME = os.environ.get("AGENT_NAME", "collector@linux-builder")
OUT = os.environ.get("OUT", os.path.expanduser("~/dureclaw-signals.csv"))
DURATION = float(os.environ.get("DURATION", "120"))

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

def _recvn(n):
    d = b""
    while len(d) < n:
        c = sock.recv(n - len(d))
        if not c: raise Exception("closed")
        d += c
    return d

def recv_frame():
    b1 = _recvn(1)[0]; b2 = _recvn(1)[0]; ln = b2 & 0x7f
    if ln == 126: ln = struct.unpack(">H", _recvn(2))[0]
    elif ln == 127: ln = struct.unpack(">Q", _recvn(8))[0]
    data = _recvn(ln) if ln else b""
    op = b1 & 0x0f
    if op == 8: return None
    if op in (9, 10): return ""
    return data.decode(errors="replace")

def join():
    joinref[0] = nref()
    send_frame(json.dumps([joinref[0], joinref[0], "work:" + WK, "phx_join",
               {"agent_name": NAME, "role": "observer", "machine": "linux-builder"}]))

def heartbeat():
    while True:
        time.sleep(15)
        try: send_frame(json.dumps([None, nref(), "phoenix", "heartbeat", {}]))
        except Exception: return

DIST = re.compile(r"(\d+(?:\.\d+)?)\s*cm")
COLOR = re.compile(r"(RED|YELLOW|GREEN)", re.I)

def main():
    connect(); join()
    threading.Thread(target=heartbeat, daemon=True).start()
    new = not os.path.exists(OUT)
    f = open(OUT, "a", newline=""); w = csv.writer(f)
    if new: w.writerow(["ts", "agent", "distance_cm", "color"])
    print(f"[collector] {NAME} → work:{WK}, 기록 {OUT}, {DURATION:.0f}s 동안 수집...")
    sock.settimeout(2.0)
    t_end = time.time() + DURATION; n = 0
    while time.time() < t_end:
        try: msg = recv_frame()
        except socket.timeout: continue
        except Exception: break
        if msg is None: break
        if not msg: continue
        try: _, _, _topic, event, p = json.loads(msg)
        except Exception: continue
        if event != "task.result": continue
        out = (p or {}).get("output", "") or ""
        frm = (p or {}).get("from", "")
        dm = DIST.search(out); cm = COLOR.search(out)
        if dm:  # 거리 시그널만 데이터셋화
            ts = (p or {}).get("ts", "") or time.strftime("%Y-%m-%dT%H:%M:%S")
            w.writerow([ts, frm, float(dm.group(1)), (cm.group(1).lower() if cm else "")])
            f.flush(); n += 1
            print(f"  [{n}] {frm} dist={dm.group(1)}cm color={cm.group(1) if cm else '-'}")
    f.close()
    print(f"[collector] 완료 — {n} 시그널 기록 → {OUT}")

if __name__ == "__main__":
    main()
