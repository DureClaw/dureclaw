#!/usr/bin/env python3
"""거리 신호등 + DureClaw 버스 트래픽 + 마스터 브레인 판단.
   Pi(로컬 핸드): HC-SR04 측정 + LED 점등 / 버스로 측정값 push(트래픽)
   마스터 브레인(원격): 거리→신호색 판단(pi)."""
import socket, base64, os, json, time, threading, struct, statistics, sys, re, urllib.request
import RPi.GPIO as GPIO

HP = os.environ.get("STATE_SERVER", "192.168.0.2:4000").replace("ws://","").replace("http://","")
HOST, PORT = HP.split(":"); PORT = int(PORT)
TOKEN = os.environ.get("OAH_SECRET", "")
WK = os.environ.get("WORK_KEY", "WK-2a56b4f1")
NAME = os.environ.get("AGENT_NAME", "sensor@pi-zero")
BRAIN = os.environ.get("BRAIN_URL", "http://192.168.0.2:4111")
BRAIN_TOKEN = os.environ.get("BRAIN_TOKEN", "")

TRIG, ECHO = 23, 24
RED, YEL, GRN = 19, 26, 20
GPIO.setmode(GPIO.BCM); GPIO.setwarnings(False)
GPIO.setup(TRIG, GPIO.OUT); GPIO.setup(ECHO, GPIO.IN)
for p in (RED, YEL, GRN): GPIO.setup(p, GPIO.OUT, initial=GPIO.LOW)
GPIO.output(TRIG, False); time.sleep(0.1)

# ── WS (raw frames) ──
sock=None; ref=[0]; joinref=[None]; lock=threading.Lock()
def nref(): ref[0]+=1; return str(ref[0])
def connect():
    global sock
    s=socket.create_connection((HOST,PORT),timeout=10)
    key=base64.b64encode(os.urandom(16)).decode()
    path="/socket/websocket?vsn=2.0.0"+(("&token="+TOKEN) if TOKEN else "")
    s.sendall((f"GET {path} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf=b""
    while b"\r\n\r\n" not in buf:
        c=s.recv(1024); buf+=c
        if not c: raise Exception("closed")
    if b"101" not in buf.split(b"\r\n")[0]: raise Exception("WS fail")
    sock=s
def send_frame(text):
    p=text.encode(); n=len(p); hdr=bytearray([0x81]); mask=os.urandom(4)
    if n<126: hdr.append(0x80|n)
    elif n<65536: hdr.append(0x80|126); hdr+=struct.pack(">H",n)
    else: hdr.append(0x80|127); hdr+=struct.pack(">Q",n)
    hdr+=mask; m=bytes(b^mask[i%4] for i,b in enumerate(p))
    with lock: sock.sendall(bytes(hdr)+m)
def push(event,payload): send_frame(json.dumps([joinref[0],nref(),"work:"+WK,event,payload]))
def join():
    joinref[0]=nref()
    send_frame(json.dumps([joinref[0],joinref[0],"work:"+WK,"phx_join",{
        "agent_name":NAME,"role":"sensor","machine":"pi-zero",
        "capabilities":["edge","sensor","gpio","hc-sr04","os:linux","arch:armv6l"],
        "preferred_model":"pi/remote","version":"0.5.0-hc"}]))
def heartbeat():
    while True:
        time.sleep(15)
        try: send_frame(json.dumps([None,nref(),"phoenix","heartbeat",{}]))
        except: return

# ── sensor + actuator ──
def ping():
    GPIO.output(TRIG,True); time.sleep(1e-5); GPIO.output(TRIG,False)
    t0=time.time()
    while GPIO.input(ECHO)==0:
        if time.time()-t0>0.02: return None
    s=time.time()
    while GPIO.input(ECHO)==1:
        if time.time()-s>0.04: return None
    return (time.time()-s)*17150.0
def measure():
    xs=[d for d in (ping() for _ in range(6)) if d and 1<d<400]
    return statistics.median(xs) if len(xs)>=2 else None
def light(c):
    for p in (RED,YEL,GRN): GPIO.output(p,GPIO.LOW)
    if c: GPIO.output({"red":RED,"yellow":YEL,"green":GRN}[c],GPIO.HIGH)

def brain_decide(d):
    """마스터 브레인(pi)이 거리→신호색 판단."""
    prompt=(f"You control a proximity traffic light. Distance to object = {d:.0f} cm. "
            f"Rule: under 15cm=red(STOP), 15-40cm=yellow(SLOW), over 40cm=green(GO). "
            f"Reply with ONLY one word: red, yellow, or green.")
    try:
        h={"Content-Type":"application/json"}
        if BRAIN_TOKEN: h["Authorization"]="Bearer "+BRAIN_TOKEN
        req=urllib.request.Request(BRAIN.rstrip("/")+"/brain/exec",
            data=json.dumps({"prompt":prompt}).encode(),headers=h)
        with urllib.request.urlopen(req,timeout=30) as r:
            out=json.loads(r.read()).get("output","").lower()
        m=re.search(r"red|yellow|green",out)
        return m.group(0) if m else None
    except Exception as e:
        return None

def local_rule(d):
    return "red" if d<15 else "yellow" if d<40 else "green"

def main():
    connect(); join()
    threading.Thread(target=heartbeat,daemon=True).start()
    print(f"[hc] joined work:{WK} as {NAME}, brain={BRAIN}")
    n=int(sys.argv[1]) if len(sys.argv)>1 else 12
    try:
        for i in range(n):
            d=measure()
            if d is None:
                print(f"[{i+1}/{n}] no-echo"); time.sleep(0.5); continue
            color=brain_decide(d); src="brain"
            if color is None: color=local_rule(d); src="local"
            light(color)
            print(f"[{i+1}/{n}] {d:6.1f}cm -> {color:<6} ({src})")
            push("task.result",{"task_id":f"hc-{int(time.time())}-{i}","to":"http@controller",
                 "from":NAME,"status":"done","exit_code":0,"backend":"remote-pi",
                 "output":f"HC-SR04 거리 {d:.0f}cm → 신호 {color.upper()} (판단: {src})"})
    finally:
        light(None); GPIO.cleanup()
        try: push("task.result",{"task_id":"hc-end","to":"http@controller","from":NAME,
                  "status":"done","exit_code":0,"output":"신호등 세션 종료"})
        except: pass
    print("done")

main()
