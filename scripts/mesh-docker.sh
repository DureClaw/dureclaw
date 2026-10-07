#!/usr/bin/env bash
# mesh-docker.sh — docker-compose.mesh.yml 로 DureClaw 서버 + 자체 사설망(Headscale) 운영
#
#   MESH_URL=http://<이 서버 LAN IP>:8080 scripts/mesh-docker.sh up
#   scripts/mesh-docker.sh code [--ttl 1h] [--reusable]   노드 연결 코드
#   scripts/mesh-docker.sh nodes                           합류한 노드
#   scripts/mesh-docker.sh down
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE=(docker compose -f docker-compose.mesh.yml)
export MESH_DIR="$PWD/mesh-data"
export MESH_CONTAINER_DIR=/var/lib/dureclaw-mesh
export MESH_HS="${COMPOSE[*]} exec -T headscale headscale -c $MESH_CONTAINER_DIR/config.yaml"
MESH="scripts/mesh.sh"

_bus() {
  local ip
  ip="$("${COMPOSE[@]}" exec -T mesh-node tailscale ip -4 2>/dev/null | tr -d '\r' | head -1 || true)"
  [[ "$ip" == 100.* ]] || { echo "mesh-docker: 서버가 아직 사설망에 합류하지 않았습니다" >&2; exit 1; }
  echo "ws://$ip:4000"
}

case "${1:-}" in
  up)
    if [[ ! -f "$MESH_DIR/config.yaml" ]]; then
      url="${MESH_URL:-}"
      if [[ -z "$url" ]]; then
        ip="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)"
        [[ -n "$ip" ]] || { echo "MESH_URL=http://<서버 LAN IP>:8080 을 지정하세요" >&2; exit 1; }
        url="http://$ip:8080"
      fi
      if [[ -n "${MESH_DOMAIN:-}" ]]; then
        bash "$MESH" init --domain "$MESH_DOMAIN" --email "${MESH_EMAIL:?MESH_DOMAIN 에는 MESH_EMAIL 필요}"
      else
        bash "$MESH" init --url "$url"
      fi
    fi
    login="$(sed -n 's/^server_url: //p' "$MESH_DIR/config.yaml")"
    export MESH_PORT="$(echo "$login" | sed -nE 's#^https?://[^/:]+:([0-9]+).*#\1#p')"
    MESH_PORT="${MESH_PORT:-8080}"
    "${COMPOSE[@]}" up -d headscale
    for _ in $(seq 1 30); do $MESH_HS users list >/dev/null 2>&1 && break; sleep 1; done
    # 서버 다리(mesh-node)용 가입 키 → 합류 → 버스 서버
    key="$(bash "$MESH" join-code --ttl 10m | sed 's/^dcj1://' | python3 -c 'import base64,json,sys; s=sys.stdin.read().strip(); s+="="*(-len(s)%4); print(json.loads(base64.urlsafe_b64decode(s))["key"])')"
    TS_AUTHKEY="$key" MESH_LOGIN_URL="$login" "${COMPOSE[@]}" up -d mesh-node
    for _ in $(seq 1 60); do _bus >/dev/null 2>&1 && break; sleep 2; done
    "${COMPOSE[@]}" up -d dureclaw
    bus="$(_bus)"
    echo ""
    echo "━━━ 자체 사설망 준비 완료 — 버스: $bus"
    echo " 노드 연결 코드 (24시간 · 여러 대):"
    echo "   $(bash "$MESH" join-code --ttl 24h --reusable --bus "$bus")"
    echo " 노드: JOIN=<코드> bash <(curl -fsSL https://dureclaw.baryon.ai/agent)"
    ;;
  code) shift; bash "$MESH" join-code --bus "$(_bus)" "$@" ;;
  nodes) $MESH_HS nodes list ;;
  down) "${COMPOSE[@]}" down ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
