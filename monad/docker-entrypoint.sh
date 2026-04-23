#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

require_env() {
  local var="$1"
  if [ -z "${!var:-}" ]; then
    log "missing required environment variable: ${var}"
    exit 1
  fi
}

NETWORK="${NETWORK:-mainnet}"
NODE_ROLE="${NODE_ROLE:-fullnode}"
CONSENSUS_PORT="${CONSENSUS_PORT:-8000}"
AUTH_PORT="${AUTH_PORT:-8001}"
RPC_PORT="${RPC_PORT:-8080}"
WS_PORT="${WS_PORT:-8081}"
METRICS_PORT="${METRICS_PORT:-8889}"
NODE_NAME="${NODE_NAME:-full_monad_docker}"
BENEFICIARY_ADDRESS="${BENEFICIARY_ADDRESS:-0x0000000000000000000000000000000000000000}"
SELF_RECORD_SEQ_NUM="${SELF_RECORD_SEQ_NUM:-1}"
ENABLE_TRACE_CALLS="${ENABLE_TRACE_CALLS:-true}"
ENABLE_WEBSOCKETS="${ENABLE_WEBSOCKETS:-false}"
MONAD_BASE_DIR="/home/monad/monad-bft"
MONAD_CONFIG_DIR="${MONAD_BASE_DIR}/config"
MONAD_ENV_FILE="/home/monad/.env"
MONAD_NODE_TOML="${MONAD_CONFIG_DIR}/node.toml"
BACKUP_DIR="/opt/monad/backup"

case "$NETWORK" in
  mainnet|testnet)
    CHAIN="monad_${NETWORK}"
    ;;
  *)
    log "NETWORK must be mainnet or testnet"
    exit 1
    ;;
esac

case "$NETWORK" in
  mainnet)
    CONFIG_BASE_URL="https://bucket.monadinfra.com/config/mainnet/latest"
    : "${REMOTE_VALIDATORS_URL:=https://bucket.monadinfra.com/validators/mainnet/validators.toml}"
    : "${REMOTE_FORKPOINT_URL:=https://bucket.monadinfra.com/forkpoint/mainnet/forkpoint.toml}"
    ;;
  testnet)
    CONFIG_BASE_URL="https://bucket.monadinfra.com/config/testnet/latest"
    : "${REMOTE_VALIDATORS_URL:=https://bucket.monadinfra.com/validators/testnet/validators.toml}"
    : "${REMOTE_FORKPOINT_URL:=https://bucket.monadinfra.com/forkpoint/testnet/forkpoint.toml}"
    ;;
esac

export CHAIN

mkdir -p \
  "${MONAD_CONFIG_DIR}" \
  "${MONAD_CONFIG_DIR}/forkpoint" \
  "${MONAD_CONFIG_DIR}/validators" \
  "${MONAD_BASE_DIR}/ledger" \
  "${BACKUP_DIR}" \
  /var/log/monad

mkdir -p /dev/triedb

fetch_if_missing() {
  local url="$1"
  local dest="$2"
  if [ ! -s "$dest" ]; then
    log "downloading $(basename "$dest") from $url"
    curl -fsSL "$url" -o "$dest"
  fi
}

if [ ! -s "$MONAD_ENV_FILE" ]; then
  log "bootstrapping .env from ${CONFIG_BASE_URL}/.env.example"
  curl -fsSL "${CONFIG_BASE_URL}/.env.example" -o "$MONAD_ENV_FILE"
fi

if [ ! -s "$MONAD_NODE_TOML" ]; then
  if [ "$NODE_ROLE" = "validator" ]; then
    log "bootstrapping validator node.toml"
    curl -fsSL "${CONFIG_BASE_URL}/node.toml" -o "$MONAD_NODE_TOML"
  else
    log "bootstrapping full-node node.toml"
    curl -fsSL "${CONFIG_BASE_URL}/full-node-node.toml" -o "$MONAD_NODE_TOML"
  fi
fi

fetch_if_missing "$REMOTE_VALIDATORS_URL" "${MONAD_CONFIG_DIR}/validators/validators.toml"
fetch_if_missing "$REMOTE_FORKPOINT_URL" "${MONAD_CONFIG_DIR}/forkpoint/forkpoint.toml"

if ! grep -Eq '^KEYSTORE_PASSWORD=' "$MONAD_ENV_FILE"; then
  printf 'KEYSTORE_PASSWORD=\n' >> "$MONAD_ENV_FILE"
fi

if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
  current_pw="$(sed -n 's/^KEYSTORE_PASSWORD=//p' "$MONAD_ENV_FILE" | tail -n1)"
  if [ -n "$current_pw" ]; then
    KEYSTORE_PASSWORD="$current_pw"
  else
    KEYSTORE_PASSWORD="$(openssl rand -base64 32)"
    sed -i "s|^KEYSTORE_PASSWORD=.*$|KEYSTORE_PASSWORD='${KEYSTORE_PASSWORD}'|" "$MONAD_ENV_FILE"
    printf 'Keystore password: %s\n' "$KEYSTORE_PASSWORD" > "${BACKUP_DIR}/keystore-password-backup"
    chmod 600 "${BACKUP_DIR}/keystore-password-backup"
    log "generated KEYSTORE_PASSWORD and stored backup in ${BACKUP_DIR}/keystore-password-backup"
  fi
fi
export KEYSTORE_PASSWORD

if [ ! -f "${MONAD_CONFIG_DIR}/id-secp" ] || [ ! -f "${MONAD_CONFIG_DIR}/id-bls" ]; then
  log "generating keystores"
  if [ ! -f "${MONAD_CONFIG_DIR}/id-secp" ]; then
    monad-keystore create \
      --key-type secp \
      --keystore-path "${MONAD_CONFIG_DIR}/id-secp" \
      --password "${KEYSTORE_PASSWORD}" > "${BACKUP_DIR}/secp-backup"
  fi
  if [ ! -f "${MONAD_CONFIG_DIR}/id-bls" ]; then
    monad-keystore create \
      --key-type bls \
      --keystore-path "${MONAD_CONFIG_DIR}/id-bls" \
      --password "${KEYSTORE_PASSWORD}" > "${BACKUP_DIR}/bls-backup"
  fi
  grep 'public key' "${BACKUP_DIR}/secp-backup" "${BACKUP_DIR}/bls-backup" > /home/monad/pubkey-secp-bls || true
fi

restore_snapshot_if_requested() {
  local snapshot_flag provider restore_script_url
  snapshot_flag="$(printf '%s' "${SNAPSHOT:-false}" | tr '[:upper:]' '[:lower:]')"
  provider="${SNAPSHOT_PROVIDER:-monad-foundation}"

  if [ "$snapshot_flag" != "true" ]; then
    return 0
  fi

  if [ -e "${MONAD_BASE_DIR}/ledger/.snapshot_loaded" ]; then
    log "snapshot restore already completed earlier; skipping"
    return 0
  fi

  case "$provider" in
    monad-foundation)
      case "$NETWORK" in
        mainnet) restore_script_url="https://bucket.monadinfra.com/scripts/mainnet/restore-from-snapshot.sh" ;;
        testnet) restore_script_url="https://bucket.monadinfra.com/scripts/testnet/restore-from-snapshot.sh" ;;
      esac
      ;;
    category-labs)
      case "$NETWORK" in
        mainnet) restore_script_url="https://pub-b0d0d7272c994851b4c8af22a766f571.r2.dev/scripts/mainnet/restore_from_snapshot.sh" ;;
        testnet) restore_script_url="https://pub-b0d0d7272c994851b4c8af22a766f571.r2.dev/scripts/testnet/restore_from_snapshot.sh" ;;
      esac
      ;;
    *)
      log "invalid SNAPSHOT_PROVIDER=${provider}; expected monad-foundation or category-labs"
      exit 1
      ;;
  esac

  log "restoring TrieDB snapshot using provider=${provider} network=${NETWORK}"
  log "running ${restore_script_url}"

  if ! command -v aria2c >/dev/null 2>&1; then
    log "aria2 is required for snapshot restore"
    exit 1
  fi

  curl -fsSL "${restore_script_url}" | bash
  touch "${MONAD_BASE_DIR}/ledger/.snapshot_loaded"
  log "snapshot restore completed"
}

PUBLIC_IP="${PUBLIC_IP:-}"
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="$(curl -fsS --max-time 10 ifconfig.me || true)"
fi
require_env NODE_NAME
require_env BENEFICIARY_ADDRESS

python3 - "$MONAD_NODE_TOML" "$BENEFICIARY_ADDRESS" "$NODE_NAME" "$PUBLIC_IP" "$CONSENSUS_PORT" "$AUTH_PORT" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
beneficiary = sys.argv[2]
node_name = sys.argv[3]
public_ip = sys.argv[4]
consensus_port = sys.argv[5]
auth_port = sys.argv[6]
text = path.read_text()

def replace_scalar(key, value):
    global text
    pattern = rf'(?m)^\s*{re.escape(key)}\s*=\s*.*$'
    repl = f'{key} = {value}'
    if re.search(pattern, text):
        text = re.sub(pattern, repl, text, count=1)
    else:
        text += f'\n{repl}\n'

def ensure_in_section(section, key, value):
    global text
    sec_pat = rf'(?ms)^\[{re.escape(section)}\]\n(.*?)(?=^\[|\Z)'
    m = re.search(sec_pat, text)
    line = f'{key} = {value}'
    if m:
      body = m.group(1)
      if re.search(rf'(?m)^\s*{re.escape(key)}\s*=\s*.*$', body):
          new_body = re.sub(rf'(?m)^\s*{re.escape(key)}\s*=\s*.*$', line, body, count=1)
      else:
          new_body = body + ('' if body.endswith('\n') else '\n') + line + '\n'
      text = text[:m.start(1)] + new_body + text[m.end(1):]
    else:
      text += f'\n[{section}]\n{line}\n'

replace_scalar('beneficiary', f'"{beneficiary}"')
replace_scalar('node_name', f'"{node_name}"')
ensure_in_section('fullnode_raptorcast', 'enable_client', 'true')
ensure_in_section('statesync', 'expand_to_group', 'true')
if public_ip:
    ensure_in_section('peer_discovery', 'self_address', f'"{public_ip}:{consensus_port}"')
    ensure_in_section('peer_discovery', 'self_auth_port', auth_port)
path.write_text(text)
PY

if [ -n "$PUBLIC_IP" ]; then
  log "generating name-record signature for ${PUBLIC_IP}"
  NAME_RECORD_OUTPUT="$(monad-sign-name-record \
    --address "${PUBLIC_IP}:${CONSENSUS_PORT}" \
    --authenticated-udp-port "${AUTH_PORT}" \
    --keystore-path "${MONAD_CONFIG_DIR}/id-secp" \
    --password "${KEYSTORE_PASSWORD}" \
    --self-record-seq-num "${SELF_RECORD_SEQ_NUM}")"
  export NAME_RECORD_OUTPUT SELF_RECORD_SEQ_NUM
  python3 - "$MONAD_NODE_TOML" <<'PY'
import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
out = os.environ['NAME_RECORD_OUTPUT']
seq = os.environ['SELF_RECORD_SEQ_NUM']
match = re.search(r'([0-9a-fA-F]{80,})', out)
if not match:
    print('warning: could not extract self_name_record_sig from monad-sign-name-record output', file=sys.stderr)
    sys.exit(0)
sig = match.group(1)

def ensure(section, key, value):
    global text
    sec_pat = rf'(?ms)^\[{re.escape(section)}\]\n(.*?)(?=^\[|\Z)'
    m = re.search(sec_pat, text)
    line = f'{key} = {value}'
    if m:
        body = m.group(1)
        if re.search(rf'(?m)^\s*{re.escape(key)}\s*=\s*.*$', body):
            new_body = re.sub(rf'(?m)^\s*{re.escape(key)}\s*=\s*.*$', line, body, count=1)
        else:
            new_body = body + ('' if body.endswith('\n') else '\n') + line + '\n'
        text = text[:m.start(1)] + new_body + text[m.end(1):]
    else:
        text += f'\n[{section}]\n{line}\n'

ensure('peer_discovery', 'self_record_seq_num', seq)
ensure('peer_discovery', 'self_name_record_sig', f'"{sig}"')
path.write_text(text)
PY
fi

RETENTION_LEDGER="${RETENTION_LEDGER:-600}"
RETENTION_WAL="${RETENTION_WAL:-300}"
RETENTION_FORKPOINT="${RETENTION_FORKPOINT:-300}"
RETENTION_VALIDATORS="${RETENTION_VALIDATORS:-43200}"

cat > "$MONAD_ENV_FILE" <<ENVEOF
CHAIN=${CHAIN}
KEYSTORE_PASSWORD='${KEYSTORE_PASSWORD}'
REMOTE_VALIDATORS_URL=${REMOTE_VALIDATORS_URL}
REMOTE_FORKPOINT_URL=${REMOTE_FORKPOINT_URL}
RETENTION_LEDGER=${RETENTION_LEDGER}
RETENTION_WAL=${RETENTION_WAL}
RETENTION_FORKPOINT=${RETENTION_FORKPOINT}
RETENTION_VALIDATORS=${RETENTION_VALIDATORS}
ENVEOF

restore_snapshot_if_requested

EXECUTION_EXTRA_FLAGS="${EXECUTION_EXTRA_FLAGS:-}"
if [ "${ENABLE_TRACE_CALLS:-true}" = "true" ]; then
  EXECUTION_EXTRA_FLAGS="${EXECUTION_EXTRA_FLAGS} --trace_calls"
fi
export EXECUTION_EXTRA_FLAGS

RPC_EXTRA_FLAGS="${RPC_EXTRA_FLAGS:-}"
if [ "${ENABLE_WEBSOCKETS:-false}" = "true" ]; then
  RPC_EXTRA_FLAGS="${RPC_EXTRA_FLAGS} --ws-enabled --ws-port ${WS_PORT}"
fi
if [ -n "${MONGO_URL:-}" ]; then
  RPC_EXTRA_FLAGS="${RPC_EXTRA_FLAGS} --mongo-url ${MONGO_URL} --mongo-db-name ${MONGO_DB_NAME:-archive-db} --use-eth-get-logs-index"
fi
if [ -n "${ARCHIVE_API_KEY:-}" ] && [ -n "${ARCHIVE_BUCKET:-}" ]; then
  RPC_EXTRA_FLAGS="${RPC_EXTRA_FLAGS} --s3-bucket ${ARCHIVE_BUCKET} --region ${ARCHIVE_REGION:-us-east-2} --archive-url ${ARCHIVE_URL:-https://9df09fanz1.execute-api.us-east-2.amazonaws.com/prod} --archive-api-key ${ARCHIVE_API_KEY}"
fi
export RPC_EXTRA_FLAGS

log "startup summary"
log "network=${NETWORK} role=${NODE_ROLE} rpc_port=${RPC_PORT} ws_port=${WS_PORT} metrics_port=${METRICS_PORT}"
log "node.toml prepared at ${MONAD_NODE_TOML}"
log "execution flags: ${EXECUTION_EXTRA_FLAGS:-<none>}"
log "rpc flags: ${RPC_EXTRA_FLAGS:-<none>}"

if [ "${ENABLE_WEBSOCKETS}" = "true" ]; then
  log "WebSockets enabled on port ${WS_PORT}; this requires execution-events host setup or monad-rpc may exit"
fi

exec "$@"
