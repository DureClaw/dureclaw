#!/usr/bin/env bash
# mesh.sh — DureClaw 자체 사설망(self-hosted Tailscale) 도구
#
# 공식 Tailscale 계정 대신, 오픈소스 제어 서버 Headscale 을 DureClaw 서버에서 직접 운영하고
# 노드는 공식 Tailscale 클라이언트(오픈소스)를 그 제어 서버에 붙인다.
#
#   서버 쪽
#     mesh.sh install                       Headscale 바이너리 설치 (~/.dureclaw/mesh/bin)
#     mesh.sh init --url http://10.0.0.5:8080 [--public-derp]
#                                           사내망·폐쇄망 모드 (HTTP, 노드끼리 직접 연결. --public-derp 는
#                                           인터넷 허용 시 Tailscale 공개 중계 추가)
#     mesh.sh init --domain mesh.example.com --email ops@example.com
#                                           지점 간 모드 (HTTPS 자동 인증서 + 내장 중계 DERP)
#     mesh.sh start | stop | status | nodes
#     mesh.sh join-code [--ttl 24h] [--reusable] [--bus ws://100.64.0.1:4000]
#                                           노드 연결 코드 출력 (제어 서버 주소 + 일회용 가입 키 + 버스 주소)
#   노드 쪽
#     mesh.sh join <코드> [--hostname NAME] [--force]
#                                           Tailscale 클라이언트 설치(없으면) → 자체 망 합류 → 버스 주소 출력
#     mesh.sh decode <코드>                  코드 내용 확인 (키는 일부만 표시)
#
# 환경 변수: MESH_DIR (기본 ~/.dureclaw/mesh), HEADSCALE_VERSION (기본 0.29.4)
set -euo pipefail

HEADSCALE_VERSION="${HEADSCALE_VERSION:-0.29.4}"
MESH_DIR="${MESH_DIR:-$HOME/.dureclaw/mesh}"
BIN="$MESH_DIR/bin/headscale"
CONF="$MESH_DIR/config.yaml"
PIDFILE="$MESH_DIR/headscale.pid"
LOG="$MESH_DIR/headscale.log"
MESH_USER="dureclaw"
CODE_PREFIX="dcj1:"
# 유닉스 소켓 경로는 OS 한계(macOS 104자)가 있다 — 설치 경로가 길면 /tmp 아래 짧은 경로로
SOCK="$MESH_DIR/run/headscale.sock"
if [[ ${#SOCK} -gt 100 ]]; then
  SOCK="/tmp/dc-mesh-$(id -u)-$(printf '%s' "$MESH_DIR" | cksum | cut -d' ' -f1).sock"
fi

die() { echo "mesh: $*" >&2; exit 1; }
info() { echo "→ $*" >&2; }

hs() { "$BIN" -c "$CONF" "$@"; }

_os_arch() {
  local os arch
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) die "지원하지 않는 OS: $(uname -s)" ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) die "지원하지 않는 CPU: $(uname -m)" ;; esac
  echo "${os}_${arch}"
}

# ── 서버: 설치 ───────────────────────────────────────────────────────────────
cmd_install() {
  mkdir -p "$MESH_DIR/bin"
  if [[ -x "$BIN" ]] && "$BIN" version 2>/dev/null | grep -q "v$HEADSCALE_VERSION"; then
    info "Headscale v$HEADSCALE_VERSION 이미 설치됨 ($BIN)"; return
  fi
  local url="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_$(_os_arch)"
  info "Headscale v$HEADSCALE_VERSION 내려받는 중… ($url)"
  curl -fsSL "$url" -o "$BIN.tmp"
  chmod +x "$BIN.tmp" && mv "$BIN.tmp" "$BIN"
  "$BIN" version | head -1 >&2
}

# ── 서버: 설정 ───────────────────────────────────────────────────────────────
cmd_init() {
  local url="" domain="" email="" listen="" force=0 public_derp=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url) url="$2"; shift 2 ;;
      --domain) domain="$2"; shift 2 ;;
      --email) email="$2"; shift 2 ;;
      --listen) listen="$2"; shift 2 ;;
      --force) force=1; shift ;;
      --public-derp) public_derp=1; shift ;;
      *) die "알 수 없는 옵션: $1" ;;
    esac
  done
  [[ -n "$url" || -n "$domain" ]] || die "--url (사내망) 또는 --domain (지점 간) 중 하나가 필요합니다"
  [[ -f "$CONF" && $force -eq 0 ]] && die "이미 설정이 있습니다: $CONF (다시 만들려면 --force)"
  mkdir -p "$MESH_DIR/lib" "$MESH_DIR/run"

  local server_url tls derp_enabled derp_urls="[]" derp_paths="[]"
  if [[ -n "$domain" ]]; then
    # 지점 간: HTTPS(Let's Encrypt 자동) + 내장 DERP 중계·STUN. 외부 Tailscale 중계에 의존하지 않는다.
    [[ -n "$email" ]] || die "--domain 에는 인증서 발급용 --email 이 필요합니다"
    server_url="https://$domain"
    listen="${listen:-0.0.0.0:443}"
    tls="acme_url: https://acme-v02.api.letsencrypt.org/directory
acme_email: \"$email\"
tls_letsencrypt_hostname: \"$domain\"
tls_letsencrypt_cache_dir: $MESH_DIR/lib/cache
tls_letsencrypt_challenge_type: HTTP-01
tls_letsencrypt_listen: \":http\""
    derp_enabled=true
  else
    # 사내망·폐쇄망: HTTP, 중계 없음 — 노드끼리 같은 망에서 직접 연결. 외부 의존 0.
    server_url="$url"
    listen="${listen:-0.0.0.0:$(echo "$url" | sed -nE 's#^https?://[^/:]+:([0-9]+).*#\1#p')}"
    [[ "$listen" == "0.0.0.0:" ]] && listen="0.0.0.0:8080"
    tls='tls_cert_path: ""
tls_key_path: ""'
    derp_enabled=false
    # 내장 DERP 는 HTTPS 필수라 사내망 HTTP 모드에선 켤 수 없고, Headscale 은 DERP 항목이 최소 1개
    # 있어야 시작한다 → 실제로 쓰지 않는 자리표시 지역 하나만 둔다. 노드끼리는 같은 망에서 직접 연결.
    local host; host="$(echo "$url" | sed -nE 's#^https?://([^/:]+).*#\1#p')"
    cat > "$MESH_DIR/derp-lan.yaml" <<DERP
regions:
  900:
    regionid: 900
    regioncode: dureclaw-lan
    regionname: DureClaw LAN (no relay, direct only)
    nodes:
      - name: 900a
        regionid: 900
        hostname: $host
        stunport: -1
        stunonly: false
        derpport: 443
DERP
    derp_paths="[$MESH_DIR/derp-lan.yaml]"
    if [[ $public_derp -eq 1 ]]; then
      # 인터넷이 허용되면 Tailscale 공개 중계로 NAT 너머 연결을 돕는다 (트래픽은 종단 간 암호화)
      derp_urls="[https://controlplane.tailscale.com/derpmap/default]"
    fi
  fi

  cat > "$CONF" <<EOF
# DureClaw 자체 사설망 — Headscale v$HEADSCALE_VERSION 설정 (mesh.sh init 이 생성)
server_url: $server_url
listen_addr: $listen
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false

noise:
  private_key_path: $MESH_DIR/lib/noise_private.key

# DureClaw 서버의 키리스 자동 승인 범위(100.64.0.0/10)와 같은 대역
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential

derp:
  server:
    enabled: $derp_enabled
    region_id: 999
    region_code: "dureclaw"
    region_name: "DureClaw Embedded DERP"
    verify_clients: true
    stun_listen_addr: "0.0.0.0:3478"
    private_key_path: $MESH_DIR/lib/derp_server_private.key
    automatically_add_embedded_derp_region: true
  # 기본은 외부(Tailscale 사) 중계 목록을 쓰지 않는다 — 자체 망은 외부 의존 없이 동작 (--public-derp 로 추가)
  urls: $derp_urls
  paths: $derp_paths
  auto_update_enabled: false
  update_frequency: 24h

disable_check_updates: true

node:
  expiry: 0

database:
  type: sqlite
  sqlite:
    path: $MESH_DIR/lib/db.sqlite
    write_ahead_log: true

$tls

log:
  level: info
  format: text

policy:
  mode: database
  path: ""

# 노드의 DNS 설정은 건드리지 않는다 (사내 DNS 유지)
dns:
  magic_dns: false
  override_local_dns: false
  base_domain: dureclaw.mesh
  nameservers:
    global: []

unix_socket: $SOCK
unix_socket_permission: "0770"

logtail:
  enabled: false
taildrop:
  enabled: true
EOF
  hs configtest >/dev/null 2>&1 || { hs configtest; die "설정 검사 실패"; }
  info "설정 생성: $CONF ($server_url)"
}

# ── 서버: 실행 ───────────────────────────────────────────────────────────────
_running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

cmd_start() {
  [[ -x "$BIN" ]] || die "Headscale 이 설치되지 않았습니다 — mesh.sh install"
  [[ -f "$CONF" ]] || die "설정이 없습니다 — mesh.sh init"
  if _running; then info "이미 실행 중 (pid $(cat "$PIDFILE"))"; return; fi
  nohup "$BIN" -c "$CONF" serve >>"$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 30); do
    [[ -S "$SOCK" ]] && hs users list >/dev/null 2>&1 && { info "Headscale 실행 중 (pid $(cat "$PIDFILE"), 로그 $LOG)"; return; }
    _running || { tail -n 20 "$LOG" >&2; die "Headscale 이 시작 직후 종료됐습니다"; }
    sleep 1
  done
  tail -n 20 "$LOG" >&2; die "Headscale 응답 대기 시간 초과"
}

cmd_stop() {
  if _running; then kill "$(cat "$PIDFILE")"; rm -f "$PIDFILE"; info "Headscale 중지"; else info "실행 중이 아님"; fi
}

cmd_status() {
  if _running; then
    echo "running pid=$(cat "$PIDFILE") url=$(sed -n 's/^server_url: //p' "$CONF")"
  else
    echo "stopped"; return 1
  fi
}

cmd_nodes() { hs nodes list; }

_user_id() {
  hs users list -o json 2>/dev/null | python3 -c '
import json,sys
users=json.load(sys.stdin) or []
for u in users:
    if u.get("name")==sys.argv[1]:
        print(u["id"]); break' "$MESH_USER"
}

# ── 서버: 노드 연결 코드 ─────────────────────────────────────────────────────
cmd_join_code() {
  local ttl="24h" reusable="" bus="" login=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ttl) ttl="$2"; shift 2 ;;
      --reusable) reusable="--reusable"; shift ;;
      --bus) bus="$2"; shift 2 ;;
      --login) login="$2"; shift 2 ;;
      *) die "알 수 없는 옵션: $1" ;;
    esac
  done
  _running || die "Headscale 이 실행 중이 아닙니다 — mesh.sh start"
  local uid; uid="$(_user_id)"
  if [[ -z "$uid" ]]; then hs users create "$MESH_USER" >/dev/null; uid="$(_user_id)"; fi
  [[ -n "$uid" ]] || die "Headscale 사용자 생성 실패"
  local key
  key="$(hs preauthkeys create --user "$uid" --expiration "$ttl" $reusable -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')"
  [[ -n "$key" ]] || die "가입 키 발급 실패"
  login="${login:-$(sed -n 's/^server_url: //p' "$CONF")}"
  if [[ -z "$bus" ]]; then
    local ip; ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    [[ "$ip" == 100.* ]] && bus="ws://$ip:4000"
  fi
  python3 - "$login" "$key" "$bus" "$CODE_PREFIX" <<'PY'
import base64, json, sys
login, key, bus, prefix = sys.argv[1:5]
payload = {"v": 1, "login": login, "key": key}
if bus: payload["bus"] = bus
print(prefix + base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode().rstrip("="))
PY
}

# ── 노드: 코드 해석·합류 ─────────────────────────────────────────────────────
_decode() {
  local code="$1"
  [[ "$code" == "$CODE_PREFIX"* ]] || die "노드 연결 코드 형식이 아닙니다 (dcj1: 로 시작)"
  python3 - "${code#"$CODE_PREFIX"}" <<'PY'
import base64, json, sys
s = sys.argv[1]; s += "=" * (-len(s) % 4)
d = json.loads(base64.urlsafe_b64decode(s))
print(d.get("login", "")); print(d.get("key", "")); print(d.get("bus", ""))
PY
}

cmd_decode() {
  local out; out="$(_decode "${1:-}")"
  local login key bus; login="$(sed -n 1p <<<"$out")"; key="$(sed -n 2p <<<"$out")"; bus="$(sed -n 3p <<<"$out")"
  echo "login-server: $login"
  echo "auth key    : ${key:0:10}… (${#key}자)"
  echo "bus         : ${bus:-(없음 — 서버 주소를 따로 지정)}"
}

_tailscale_bin() {
  command -v tailscale 2>/dev/null && return
  for p in /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale /opt/homebrew/bin/tailscale; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 0   # 못 찾으면 빈 출력 — 함수 끝이 [[ ]] && 로 끝나 1 을 돌리면 set -e 로 죽는다
}

_sudo() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

cmd_join() {
  local code="" hostname="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostname) hostname="$2"; shift 2 ;;
      --force) force=1; shift ;;
      -*) die "알 수 없는 옵션: $1" ;;
      *) code="$1"; shift ;;
    esac
  done
  [[ -n "$code" ]] || die "사용법: mesh.sh join <노드 연결 코드>"
  local out login key bus
  out="$(_decode "$code")"; login="$(sed -n 1p <<<"$out")"; key="$(sed -n 2p <<<"$out")"; bus="$(sed -n 3p <<<"$out")"
  [[ -n "$login" && -n "$key" ]] || die "코드에 제어 서버 주소나 가입 키가 없습니다"

  local ts; ts="$(_tailscale_bin || true)"
  if [[ -z "$ts" ]]; then
    [[ "$(uname -s)" == "Linux" ]] || die "Tailscale 클라이언트를 먼저 설치하세요: https://tailscale.com/download"
    info "Tailscale 클라이언트 설치 중 (오픈소스 공식 클라이언트)…"
    curl -fsSL https://tailscale.com/install.sh | sh >&2
    ts="$(_tailscale_bin)"
  fi

  # 이미 다른 망(예: 공식 Tailscale 계정)에 로그인돼 있으면 덮어쓰기 전에 멈춘다
  local current
  current="$("$ts" status --json 2>/dev/null | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(d.get("BackendState",""))
except Exception: print("")' || true)"
  if [[ "$current" == "Running" && $force -eq 0 ]]; then
    local cur_url
    cur_url="$("$ts" debug prefs 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("ControlURL",""))
except Exception: print("")' || true)"
    if [[ "$cur_url" != "$login" ]]; then
      die "이 컴퓨터는 이미 다른 사설망(${cur_url:-알 수 없음})에 연결돼 있습니다. 자체 망으로 옮기려면 --force (기존 망 연결이 끊깁니다)"
    fi
  fi

  hostname="${hostname:-$(hostname -s 2>/dev/null || hostname)}"
  info "자체 망 합류: $login (hostname=$hostname)"
  local extra=()
  [[ $force -eq 1 ]] && extra+=(--force-reauth)
  _sudo "$ts" up --login-server="$login" --authkey="$key" --hostname="$hostname" \
    --accept-dns=false --reset "${extra[@]}" >&2
  local ip; ip="$("$ts" ip -4 2>/dev/null | head -1)"
  [[ "$ip" == 100.* ]] || die "합류 후 사설망 IP 를 받지 못했습니다"
  info "합류 완료 — 이 노드의 사설망 IP: $ip"
  if [[ -n "$bus" ]]; then echo "PHOENIX=$bus"; fi
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  init) shift; cmd_init "$@" ;;
  start) shift; cmd_start ;;
  stop) shift; cmd_stop ;;
  status) shift; cmd_status ;;
  nodes) shift; cmd_nodes ;;
  join-code) shift; cmd_join_code "$@" ;;
  join) shift; cmd_join "$@" ;;
  decode) shift; cmd_decode "$@" ;;
  *) sed -n '2,24p' "$0"; exit 1 ;;
esac
