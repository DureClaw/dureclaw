#!/usr/bin/env python3
"""마스터 1회 정책 판단(brain) → Pi 로컬 스킬 결정화 → 결정론 루프 + 속도 로그.
   '로컬 핸드·원격 브레인'을 '한 번 배우고(brain), 이후 결정론적으로(edge)'로 최적화."""
import socket, base64, os, json, time, threading, struct, statistics, sys, re, urllib.request
import RPi.GPIO as GPIO

HP=os.environ.get("STATE_SERVER","192.168.0.2:4000").replace("ws://","").replace("http://","")
HOST,PORT=HP.split(":"); PORT=int(PORT)
TOKEN=os.environ.get("OAH_SECRET",""); WK=os.environ.get("WORK_KEY","WK-2a56b4f1")
NAME=os.environ.get("AGENT_NAME","sensor@pi-zero")
BRAIN=os.environ.get("BRAIN_URL","http://192.168.0.2:4111")
BRAIN_TOKEN=os.environ.get("BRAIN_TOKEN","")
SKILL_DIR=os.path.expanduser("~/.dureclaw/skills"); SKILL_FILE=SKILL_DIR+"/proximity-light.json"

TRIG,ECHO=23,24; RED,YEL,GRN=19,26,20
GPIO.setmode(GPIO.BCM); GPIO.setwarnings(False)
GPIO.setup(TRIG,GPIO.OUT); GPIO.setup(ECHO,GPIO.IN)
for p in (RED,YEL,GRN): GPIO.setup(p,GPIO.OUT,initial=GPIO.LOW)
GPIO.output(TRIG,False); time.sleep(0.1)

# ── WS push (bus traffic) ──
sock=None; ref=[0]; joinref=[None]; lock=threading.Lock()
def nref(): ref[0]+=1; return str(ref[0])
def connect():
    global sock
    s=socket.create_connection((HOST,PORT),timeout=10)
    key=base64.b64encode(os.urandom(16)).decode()
    path="/socket/websocket?vsn=2.0.0"+(("&token="+TOKEN) if TOKEN else "")
    s.sendall((f"GET {path} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf=b""
    while b"\r\n\r\n" not in buf:
        c=s.recv(1024); buf+=c
        if not c: raise Exception("closed")
    sock=s
def send_frame(t):
    p=t.encode(); n=len(p); h=bytearray([0x81]); m=os.urandom(4)
    h.append(0x80|n) if n<126 else (h.append(0x80|126) or h.__iadd__(struct.pack(">H",n)))
    h+=m; mm=bytes(b^m[i%4] for i,b in enumerate(p))
    with lock: sock.sendall(bytes(h)+mm)
def push(ev,pl): send_frame(json.dumps([joinref[0],nref(),"work:"+WK,ev,pl]))
def join():
    joinref[0]=nref()
    send_frame(json.dumps([joinref[0],joinref[0],"work:"+WK,"phx_join",{"agent_name":NAME,"role":"sensor","machine":"pi-zero","capabilities":["edge","sensor","gpio","hc-sr04","skill:proximity-light","arch:armv6l"],"preferred_model":"skill/local","version":"0.5.1-skill"}]))
def hb():
    while True:
        time.sleep(15)
        try: send_frame(json.dumps([None,nref(),"phoenix","heartbeat",{}]))
        except: return

# ── sensor + LED ──
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

# ── brain (느린 1회 정책 판단) ──
def brain_call(prompt):
    h={"Content-Type":"application/json"}
    if BRAIN_TOKEN: h["Authorization"]="Bearer "+BRAIN_TOKEN
    req=urllib.request.Request(BRAIN.rstrip("/")+"/brain/exec",data=json.dumps({"prompt":prompt}).encode(),headers=h)
    with urllib.request.urlopen(req,timeout=40) as r:
        return json.loads(r.read()).get("output","")

def master_calibrate():
    prompt=("You are calibrating a proximity traffic-light controller. Pick distance thresholds in cm. "
            "Reply with ONLY compact JSON (no prose): {\"red_cm\": <int>, \"yellow_cm\": <int>, \"rationale\": \"<short why>\"}. "
            "Constraints: red_cm < yellow_cm; red is the close STOP zone (~10-15cm), yellow the SLOW zone (~30-40cm), green beyond.")
    t=time.time(); out=brain_call(prompt); ms=(time.time()-t)*1000
    m=re.search(r"\{.*\}",out,re.S)
    pol=json.loads(m.group(0)) if m else {"red_cm":15,"yellow_cm":40,"rationale":"fallback default"}
    pol["red_cm"]=int(pol["red_cm"]); pol["yellow_cm"]=int(pol["yellow_cm"])
    return pol, ms

# ── 결정화된 스킬(결정론적, 빠름) ──
def skill(d, pol):
    return "red" if d<pol["red_cm"] else "yellow" if d<pol["yellow_cm"] else "green"

def main():
    recal = "--recalibrate" in sys.argv
    n = next((int(a) for a in sys.argv[1:] if a.isdigit()), 12)
    connect(); join(); threading.Thread(target=hb,daemon=True).start()

    # ── 1단계: 스킬 로드 or 마스터 보정 ──
    if os.path.exists(SKILL_FILE) and not recal:
        pol=json.load(open(SKILL_FILE)); cal_ms=0.0
        print(f"[SKILL] 로컬 스킬 로드(결정론) red<{pol['red_cm']} yellow<{pol['yellow_cm']}  | brain 호출 0회")
    else:
        print("[CALIBRATE] 마스터 브레인에 1회 정책 판단 요청...")
        pol, cal_ms = master_calibrate()
        os.makedirs(SKILL_DIR,exist_ok=True); json.dump(pol,open(SKILL_FILE,"w"),ensure_ascii=False,indent=2)
        print(f"[CALIBRATE] 마스터 판단 {cal_ms:.0f}ms → red<{pol['red_cm']}cm yellow<{pol['yellow_cm']}cm")
        print(f"           근거: {pol.get('rationale','')}")
        push("task.result",{"task_id":f"policy-{int(time.time())}","to":"http@controller","from":NAME,"status":"done","exit_code":0,"output":f"[정책 결정화] 마스터 {cal_ms:.0f}ms → 스킬 red<{pol['red_cm']} yellow<{pol['yellow_cm']} | {pol.get('rationale','')}"})

    # ── 벤치: brain-매판단(옛 방식) 2회 측정 ──
    bench=[]
    for _ in range(2):
        d=measure() or 30
        t=time.time(); _=brain_call(f"Distance {d:.0f}cm. Reply one word red/yellow/green. red<{pol['red_cm']} yellow<{pol['yellow_cm']}.")
        bench.append((time.time()-t)*1000)
    brain_ms=statistics.mean(bench)

    # ── 2단계: 결정론적 루프(스킬, 빠름) + 측정 로그 ──
    locs=[]
    for i in range(n):
        d=measure()
        if d is None: print(f"[{i+1}/{n}] no-echo"); time.sleep(0.2); continue
        t=time.perf_counter(); color=skill(d,pol); us=(time.perf_counter()-t)*1e6
        locs.append(us); light(color)
        print(f"[{i+1}/{n}] {d:6.1f}cm -> {color:<6} (skill {us:.1f}µs)")
        push("task.result",{"task_id":f"hc-{int(time.time())}-{i}","to":"http@controller","from":NAME,"status":"done","exit_code":0,"backend":"skill-local","output":f"거리 {d:.0f}cm → {color.upper()} (로컬 스킬 {us:.1f}µs)"})
        time.sleep(0.15)

    # ── 속도 개선 로그 ──
    loc_ms=statistics.mean(locs)/1000 if locs else 0
    sp = brain_ms/loc_ms if loc_ms else float('inf')
    print("\n===== 처리 속도 개선 =====")
    print(f"  옛 방식 (brain 매 판단)   : {brain_ms:8.1f} ms/판단")
    print(f"  새 방식 (로컬 스킬 결정론) : {loc_ms*1000:8.1f} µs/판단  ({loc_ms:.4f} ms)")
    print(f"  속도 향상                 : 약 {sp:,.0f}x")
    print(f"  마스터 1회 보정 비용       : {cal_ms:.0f} ms (N회에 분할 상각, 캐시 후 0)")
    push("task.result",{"task_id":f"speedup-{int(time.time())}","to":"http@controller","from":NAME,"status":"done","exit_code":0,"output":f"[속도개선] brain {brain_ms:.0f}ms → 스킬 {loc_ms*1000:.1f}µs/판단 (~{sp:,.0f}x), 1회보정 {cal_ms:.0f}ms 상각"})
    light(None); GPIO.cleanup(); print("done")

main()
