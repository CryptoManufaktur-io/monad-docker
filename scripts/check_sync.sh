#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: check_sync.sh [options]

Options:
  --container NAME         Docker container name or ID to run curl/jq within
  --compose-service NAME   Docker Compose service name to resolve to a container
  --local-rpc URL          Local RPC URL (default: http://127.0.0.1:${RPC_PORT:-8080})
  --public-rpc URL         Public/reference RPC URL (required)
  --block-lag N            Acceptable lag in blocks (default: 2)
  --no-install             Do not install curl/jq inside the container
  --env-file PATH          Path to env file to load
  -h, --help               Show this help
USAGE
}

DEFAULT_BLOCK_LAG_THRESHOLD=2
ENV_FILE="${ENV_FILE:-}"
CONTAINER="${CONTAINER:-}"
DOCKER_SERVICE="${DOCKER_SERVICE:-}"
LOCAL_RPC="${LOCAL_RPC:-}"
PUBLIC_RPC="${PUBLIC_RPC:-}"
BLOCK_LAG_THRESHOLD="${BLOCK_LAG_THRESHOLD:-$DEFAULT_BLOCK_LAG_THRESHOLD}"
INSTALL_TOOLS="${INSTALL_TOOLS:-1}"

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER="$2"; shift 2 ;;
    --compose-service) DOCKER_SERVICE="$2"; shift 2 ;;
    --local-rpc) LOCAL_RPC="$2"; shift 2 ;;
    --public-rpc) PUBLIC_RPC="$2"; shift 2 ;;
    --block-lag) BLOCK_LAG_THRESHOLD="$2"; shift 2 ;;
    --no-install) INSTALL_TOOLS="0"; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

if [[ -n "$ENV_FILE" ]]; then
  load_env_file "$ENV_FILE"
elif [[ -f .env ]]; then
  load_env_file .env
fi

LOCAL_RPC="${LOCAL_RPC:-http://127.0.0.1:${RPC_PORT:-8080}}"
[[ -n "$PUBLIC_RPC" ]] || { echo "--public-rpc is required"; exit 2; }

resolve_container() {
  if [[ -n "$CONTAINER" || -z "$DOCKER_SERVICE" ]]; then
    return 0
  fi
  if docker compose version >/dev/null 2>&1; then
    CONTAINER="$(docker compose ps -q "$DOCKER_SERVICE" | head -n1)"
  elif command -v docker-compose >/dev/null 2>&1; then
    CONTAINER="$(docker-compose ps -q "$DOCKER_SERVICE" | head -n1)"
  fi
  [[ -n "$CONTAINER" ]]
}

rpc_call() {
  local url="$1"
  local method="$2"
  local data
  data=$(printf '{"jsonrpc":"2.0","method":"%s","params":[],"id":1}' "$method")
  if [[ -n "$CONTAINER" ]]; then
    docker exec "$CONTAINER" sh -lc "curl -sS --fail --max-time 10 -X POST -H 'Content-Type: application/json' --data '$data' '$url'"
  else
    curl -sS --fail --max-time 10 -X POST -H 'Content-Type: application/json' --data "$data" "$url"
  fi
}

jq_eval() {
  if [[ -n "$CONTAINER" ]]; then
    docker exec -i "$CONTAINER" jq -r "$1"
  else
    jq -r "$1"
  fi
}

resolve_container || { echo "failed to resolve compose service container"; exit 2; }

if [[ -n "$CONTAINER" ]]; then
  if ! docker exec "$CONTAINER" sh -lc 'command -v curl >/dev/null && command -v jq >/dev/null'; then
    if [[ "$INSTALL_TOOLS" = "1" ]]; then
      docker exec -u root "$CONTAINER" sh -lc 'apt-get update && apt-get install -y curl jq ca-certificates'
    else
      echo "curl/jq not available inside container"; exit 2
    fi
  fi
else
  command -v curl >/dev/null && command -v jq >/dev/null || { echo "curl and jq are required"; exit 2; }
fi

local_result="$(rpc_call "$LOCAL_RPC" eth_blockNumber)"
public_result="$(rpc_call "$PUBLIC_RPC" eth_blockNumber)"
local_height_hex="$(printf '%s' "$local_result" | jq_eval '.result // empty')"
public_height_hex="$(printf '%s' "$public_result" | jq_eval '.result // empty')"

[[ -n "$local_height_hex" && -n "$public_height_hex" ]] || { echo "missing block number in response"; exit 2; }

local_height_dec=$((local_height_hex))
public_height_dec=$((public_height_hex))
lag=$((public_height_dec - local_height_dec))
lag_abs=${lag#-}

syncing_result="$(rpc_call "$LOCAL_RPC" eth_syncing || true)"
syncing_flag="false"
if [[ -n "$syncing_result" ]]; then
  syncing_flag="$(printf '%s' "$syncing_result" | jq_eval '.result // false')"
fi

printf 'Local latest:  %s (%s)\n' "$local_height_dec" "$local_height_hex"
printf 'Public latest: %s (%s)\n' "$public_height_dec" "$public_height_hex"
printf 'Lag: %s blocks (threshold: %s)\n' "$lag_abs" "$BLOCK_LAG_THRESHOLD"

if [[ "$syncing_flag" != "false" ]] || (( lag > BLOCK_LAG_THRESHOLD )); then
  echo 'Final status: syncing'
  exit 1
fi

echo 'Final status: in sync'
