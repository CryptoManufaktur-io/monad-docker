# monad-docker

Docker Compose for Monad full node/RPC.

## ⚠️ Important Notes

- **Mainnet Ready**: This setup is configured for production mainnet deployment
- **Testnet Support**: Simply change `NETWORK=testnet` in `.env` to test on testnet first
- **Three Services**: Monad runs three separate services (monad-bft, monad-execution, monad-rpc) managed by supervisord
- **APT Installation**: Uses official Monad packages from Category Labs repository (v0.14.1)
- **TrieDB**: In Docker, uses a volume. For production bare-metal, use dedicated NVMe device
- **Keystore**: Automatically generated on first run (password will be displayed - **save it securely!**)

## Deployment Modes

This project uses separate YAML files for different deployment scenarios:

### File Structure

| File | Purpose |
|------|---------|
| `monad.yml` | **Base configuration** - P2P ports only, Traefik labels included |
| `monad-exposed.yml` | **Local RPC access** - Exposes RPC/WS/Metrics ports locally |
| `ext-network.yml` | **Traefik integration** - External network for reverse proxy |

### Configuration Options

Choose your deployment mode in `.env`:

```bash
# 1. Base (P2P only, no local RPC, no Traefik)
COMPOSE_FILE=monad.yml

# 2. With local RPC access (for testing/development)
COMPOSE_FILE=monad.yml:monad-exposed.yml

# 3. With Traefik (RPC via reverse proxy)
COMPOSE_FILE=monad.yml:ext-network.yml

# 4. With both local RPC and Traefik
COMPOSE_FILE=monad.yml:monad-exposed.yml:ext-network.yml
```

### Exposed Ports by Mode

| Port | Mode 1 (Base) | Mode 2 (Exposed) | Mode 3 (Traefik) | Mode 4 (Both) |
|------|---------------|------------------|------------------|---------------|
| 8000 (Consensus P2P) | ✅ | ✅ | ✅ | ✅ |
| 8001 (Peer Discovery) | ✅ | ✅ | ✅ | ✅ |
| 8545 (RPC HTTP) | ❌ | ✅ | Traefik only | ✅ + Traefik |
| 8546 (RPC WS) | ❌ | ✅ | Traefik only | ✅ + Traefik |
| 8889 (Metrics) | ❌ | ✅ | ❌ | ✅ |

## Quick Start

### 1. Clone and configure

```bash
cp default.env .env
nano .env
```

### 2. Key configuration options

```bash
# Switch between mainnet and testnet
NETWORK=mainnet  # or 'testnet' for testing

# Set your node name
NODE_NAME=full_monad_docker

# Choose deployment mode (see Deployment Modes above)
COMPOSE_FILE=monad.yml:monad-exposed.yml

# For RPC nodes, enable trace calls
ENABLE_TRACE_CALLS=true

# Configure data retention (in minutes, default: 7 days)
RETENTION_EXEC_BLOCKS=10080
```

### 3. For testnet testing

```bash
# In .env, change:
NETWORK=testnet
COMPOSE_FILE=monad.yml:monad-exposed.yml
```

### 4. Start the node

```bash
# Install Docker if needed
./ethd install

# Start the node
./ethd up

# Watch logs
./ethd logs -f monad
```

### 5. First run - Save your keystore password!

On first run, if you didn't set `KEYSTORE_PASSWORD`, one will be generated automatically. Check the logs:

```bash
./ethd logs monad | grep "Generated keystore password"
```

**Save this password securely! You'll need it if you ever need to recover your keys.**

## Switching Between Mainnet and Testnet

Simply change the `NETWORK` variable in `.env`:

```bash
# For testnet
NETWORK=testnet

# For mainnet
NETWORK=mainnet
```

The configuration will automatically fetch the correct validators and forkpoint files from:
- Mainnet: `https://bucket.monadinfra.com/config/mainnet/latest/`
- Testnet: `https://bucket.monadinfra.com/config/testnet/latest/`

## Updating Monad

To update to a new Monad version:

1. Update `MONAD_VERSION` in `.env` to the desired version tag (e.g., `0.14.1`)
2. Run `./ethd update` to rebuild the Docker image
3. Run `./ethd up` to restart the node with the new version

## Check Sync Status

```bash
# Default: checks against public RPC
./ethd check-sync

# Specify custom public RPC
./ethd check-sync --public-rpc https://monad-rpc.publicnode.com:443

# Show help
./ethd check-sync --help
```

Exit codes:
- `0`: In sync
- `1`: Still syncing
- `2`: Error (hash mismatch or RPC unreachable)

## Archive/RPC Node Configuration

### For RPC nodes serving requests:

1. Enable trace calls in `.env`:
```bash
ENABLE_TRACE_CALLS=true
```

2. Use appropriate deployment mode:
```bash
# Local RPC access for testing
COMPOSE_FILE=monad.yml:monad-exposed.yml

# Production with Traefik
COMPOSE_FILE=monad.yml:ext-network.yml
```

3. **(Optional)** Configure AWS S3 archive for historical data:
```bash
ARCHIVE_API_KEY=your-api-key-here
ARCHIVE_BUCKET=monad-mainnet-archive-us-east-1
ARCHIVE_URL=https://api.monadarchive.com
ARCHIVE_REGION=us-east-1
```

4. **(Optional)** Configure MongoDB archive (alternative to AWS):
```bash
MONGO_URL=mongodb://username:password@mongodb-host:27017
MONGO_DB_NAME=monad-archive
```

### Adjusting data retention:

Configure retention periods based on your storage capacity:

```bash
# Retention in minutes (default: 10080 = 7 days)
RETENTION_BFT_HEADERS=10080
RETENTION_BFT_BODIES=10080
RETENTION_EXEC_BLOCKS=10080
RETENTION_EXEC_RECEIPTS=10080
```

## Port Configuration

Default ports:

| Service | Port | Protocol | Description | Exposed In |
|---------|------|----------|-------------|------------|
| Consensus P2P | 8000 | TCP/UDP | BFT consensus traffic | All modes |
| Peer Discovery | 8001 | UDP | Authenticated peer discovery | All modes |
| RPC HTTP | 8545 | TCP | Ethereum JSON-RPC | monad-exposed.yml |
| RPC WebSocket | 8546 | TCP | WebSocket RPC | monad-exposed.yml |
| Metrics | 8889 | TCP | Prometheus metrics | monad-exposed.yml |

All ports can be customized in `.env`.

## Using the CLI Tool (Optional)

A CLI container is available for debugging and admin tasks. It won't start by default.

```bash
# Start bash shell with access to node data
docker compose --profile tools run --rm cli

# Run monad commands
docker compose --profile tools run --rm cli monad-keystore --help
```

**Note**: The CLI service is optional and only used for debugging. It's not required for node operation.

## Using monadd Alias

The `monadd` symlink is provided as an alias to `ethd` for convenience:

```bash
./monadd up
./monadd logs
./monadd check-sync
```

## Testing RPC Endpoints

### Test local RPC (when using monad-exposed.yml):

```bash
# Get latest block number
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Get sync status
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}'

# Get chain ID
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
```

### Test trace calls (if enabled):

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "method":"debug_traceTransaction",
    "params":["0x<transaction-hash>", {"tracer": "callTracer"}],
    "id":1
  }'
```

## Production Deployment Notes

### For bare-metal production deployment:

1. **Disable HyperThreading/SMT** in BIOS
2. **Use Ubuntu 24.04+** with kernel >= 6.8.0.60
3. **Dedicated NVMe for TrieDB**: Configure udev rule to map partition to `/dev/triedb`
4. **Firewall rules**:
   ```bash
   # Allow consensus port
   ufw allow 8000/tcp
   ufw allow 8000/udp
   ufw allow 8001/udp

   # Drop large UDP packets
   iptables -I INPUT -p udp --dport 8000 -m length --length 0:1400 -j DROP
   ```
5. **Monitor logs**: `./ethd logs -f monad`
6. **Check metrics**: `curl http://localhost:8889/metrics` (if using monad-exposed.yml)

### Docker Limitations:

- TrieDB uses a Docker volume instead of bare NVMe (performance impact)
- Supervisord manages services instead of systemd
- Suitable for testing and development; for production RPC, consider bare-metal

## Troubleshooting

### View logs:
```bash
./ethd logs -f monad
```

### Check all three services are running:
```bash
docker compose exec monad supervisorctl status
```

Expected output:
```
monad-bft                        RUNNING
monad-execution                  RUNNING
monad-rpc                        RUNNING
```

### Restart the node:
```bash
./ethd restart
```

### Reset and start fresh:
```bash
./ethd terminate  # WARNING: Deletes all data!
./ethd up
```

### Check configuration files:
```bash
docker compose exec monad cat /home/monad/monad-bft/config/node.toml
docker compose exec monad cat /home/monad/.env
```

### Individual service logs:
```bash
docker compose exec monad tail -f /home/monad/monad-bft-stdout.log
docker compose exec monad tail -f /home/monad/monad-execution-stdout.log
docker compose exec monad tail -f /home/monad/monad-rpc-stdout.log
```

## Customization

`custom.yml` is not tracked by git and can be used to override anything in the provided yml files. If you use it, add it to `COMPOSE_FILE` in `.env`:

```bash
COMPOSE_FILE=monad.yml:monad-exposed.yml:custom.yml
```

## References

- [Official Monad Full Node Installation Guide](https://docs.monad.xyz/node-ops/full-node-installation)
- [Configuring RPC with Archive Data](https://docs.monad.xyz/node-ops/archive-data/configuring-rpc)
- [Chainlink Node Ops Monad Guide](https://github.com/smartcontractkit/node-ops-wiki/blob/main/docs/Blockchains/Monad/mainnet_fn_guide.md)

## Version

Monad Docker uses a semver scheme.

This is monad-docker v1.0.0
