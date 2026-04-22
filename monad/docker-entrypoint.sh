#!/usr/bin/env bash
set -euo pipefail

echo "=================================================="
echo "  Monad Full Node Docker Container"
echo "  Network: ${NETWORK}"
echo "=================================================="

# Set configuration URLs based on network
if [ "${NETWORK}" = "mainnet" ]; then
    CONFIG_BASE_URL="https://bucket.monadinfra.com/config/mainnet/latest"
else
    CONFIG_BASE_URL="https://bucket.monadinfra.com/config/testnet/latest"
fi

echo "Configuration URL: ${CONFIG_BASE_URL}"

# Initialize directories
mkdir -p /home/monad/monad-bft/config/validators
mkdir -p /home/monad/monad-bft/config/forkpoint
mkdir -p /home/monad/monad-bft/ledger
mkdir -p /home/monad/.monad-keystore

# Check if this is first run
if [ ! -f /home/monad/.initialized ]; then
    echo "First run detected. Initializing node..."

    # Generate keystore if it doesn't exist
    if [ ! -f /home/monad/.monad-keystore/bls.key ] || [ ! -f /home/monad/.monad-keystore/secp.key ]; then
        echo "Generating keystore..."

        # Generate a random keystore password if not provided
        if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
            KEYSTORE_PASSWORD=$(openssl rand -base64 32)
            echo "=================================================="
            echo "⚠️  GENERATED KEYSTORE PASSWORD (SAVE THIS!):"
            echo "    ${KEYSTORE_PASSWORD}"
            echo "=================================================="
        fi

        # Create keystore for BLS and SECP
        echo "${KEYSTORE_PASSWORD}" | monad-keystore create --keystore /home/monad/.monad-keystore --key-type bls
        echo "${KEYSTORE_PASSWORD}" | monad-keystore create --keystore /home/monad/.monad-keystore --key-type secp

        echo "Keystore created successfully"
    fi

    # Initialize TrieDB (in Docker, we use a volume instead of raw device)
    if [ ! -f /triedb/.initialized ]; then
        echo "Initializing TrieDB..."
        # Note: In production, this should be a dedicated NVMe device
        # For Docker testing, we just mark it as initialized
        touch /triedb/.initialized
    fi

    # Download and extract snapshot if provided (for fast sync)
    if [ -n "${SNAPSHOT:-}" ]; then
        # Only download if ledger data doesn't already exist
        if [ -d "/home/monad/monad-bft/ledger/blocks" ] || [ -d "/home/monad/monad-bft/ledger/db" ]; then
            echo ""
            echo "Existing ledger data detected, skipping snapshot download"
        else
            echo ""
            echo "Snapshot URL provided: ${SNAPSHOT}"
            echo "Downloading snapshot for fast sync..."

        # Use aria2c for faster multi-connection download if available
        if command -v aria2c &> /dev/null; then
            echo "Using aria2c for faster download (multi-connection)..."
            aria2c -x 16 -s 16 -k 1M --file-allocation=none --allow-overwrite=true -d /tmp -o monad-snapshot "$SNAPSHOT"
        else
            echo "aria2c not found, falling back to curl..."
            curl -L -o /tmp/monad-snapshot "$SNAPSHOT"
        fi

        echo "Download complete, extracting snapshot..."

        # Detect file type and extract accordingly
        # Monad snapshots are typically .tar.zst format
        if file /tmp/monad-snapshot | grep -q "Zstandard compressed"; then
            echo "Detected Zstandard compression, extracting with zstd..."
            zstd -c -d /tmp/monad-snapshot | tar -x -C /home/monad/monad-bft/
        elif file /tmp/monad-snapshot | grep -q "LZ4 compressed"; then
            echo "Detected LZ4 compression, extracting with lz4..."
            lz4 -c -d /tmp/monad-snapshot | tar -x -C /home/monad/monad-bft/
        elif file /tmp/monad-snapshot | grep -q "gzip compressed"; then
            echo "Detected gzip compression, extracting with tar..."
            tar -xzf /tmp/monad-snapshot -C /home/monad/monad-bft/
        else
            echo "Unknown compression format, trying tar directly..."
            tar -xf /tmp/monad-snapshot -C /home/monad/monad-bft/
        fi

        rm -f /tmp/monad-snapshot
        echo "Snapshot extraction complete"

        # Download and extract second part if specified
        if [ -n "${SNAPSHOT_PART:-}" ]; then
            echo ""
            echo "Downloading snapshot part 2: ${SNAPSHOT_PART}"

            if command -v aria2c &> /dev/null; then
                aria2c -x 16 -s 16 -k 1M --file-allocation=none --allow-overwrite=true -d /tmp -o monad-snapshot-part2 "$SNAPSHOT_PART"
            else
                curl -L -o /tmp/monad-snapshot-part2 "$SNAPSHOT_PART"
            fi

            echo "Extracting snapshot part 2..."

            if file /tmp/monad-snapshot-part2 | grep -q "Zstandard compressed"; then
                zstd -c -d /tmp/monad-snapshot-part2 | tar -x -C /home/monad/monad-bft/
            elif file /tmp/monad-snapshot-part2 | grep -q "LZ4 compressed"; then
                lz4 -c -d /tmp/monad-snapshot-part2 | tar -x -C /home/monad/monad-bft/
            elif file /tmp/monad-snapshot-part2 | grep -q "gzip compressed"; then
                tar -xzf /tmp/monad-snapshot-part2 -C /home/monad/monad-bft/
            else
                tar -xf /tmp/monad-snapshot-part2 -C /home/monad/monad-bft/
            fi

            rm -f /tmp/monad-snapshot-part2
            echo "Snapshot part 2 extraction complete"
        fi
        fi  # Close the ledger data check
    else
        echo ""
        echo "No snapshot URL provided, will sync from genesis/checkpoint"
    fi

    # Fetch remote configuration files
    echo ""
    echo "Fetching configuration files from ${CONFIG_BASE_URL}..."

    # Download validators configuration
    if [ -n "${VALIDATORS_REMOTE_URL:-}" ]; then
        echo "Downloading validators from ${VALIDATORS_REMOTE_URL}..."
        curl -fsSL "${VALIDATORS_REMOTE_URL}" -o /home/monad/monad-bft/config/validators/validators.json
    else
        curl -fsSL "${CONFIG_BASE_URL}/validators.json" -o /home/monad/monad-bft/config/validators/validators.json || \
            echo "Warning: Could not download validators.json"
    fi

    # Download forkpoint configuration
    if [ -n "${FORKPOINT_REMOTE_URL:-}" ]; then
        echo "Downloading forkpoint from ${FORKPOINT_REMOTE_URL}..."
        curl -fsSL "${FORKPOINT_REMOTE_URL}" -o /home/monad/monad-bft/config/forkpoint/forkpoint.json
    else
        curl -fsSL "${CONFIG_BASE_URL}/forkpoint.json" -o /home/monad/monad-bft/config/forkpoint/forkpoint.json || \
            echo "Warning: Could not download forkpoint.json"
    fi

    echo "Configuration files downloaded"
fi

# Get public IP
PUBLIC_IP=$(curl -s --max-time 10 ifconfig.me || echo "127.0.0.1")
echo ""
echo "Public IP: ${PUBLIC_IP}"

# Create/Update node.toml configuration
echo "Creating node.toml configuration..."
cat > /home/monad/monad-bft/config/node.toml <<EOF
# Monad Node Configuration
# Network: ${NETWORK}

# Node identification
node_name = "${NODE_NAME}"
beneficiary = "${BENEFICIARY_ADDRESS}"

# Network configuration
[network]
listen_addr = "0.0.0.0:${CONSENSUS_PORT}"
public_addr = "${PUBLIC_IP}:${CONSENSUS_PORT}"
auth_port = ${AUTH_PORT}

# Full node raptorcast settings
[fullnode_raptorcast]
enable_client = true

# State sync settings (for catching up after snapshot)
[statesync]
expand_to_group = true

# Peer discovery (optional: add bootstrap peers)
${BOOTSTRAP_PEERS:+bootstrap_peers = "${BOOTSTRAP_PEERS}"}
EOF

echo "node.toml created"

# Create .env file for Monad services
echo "Creating environment configuration..."
cat > /home/monad/.env <<EOF
# Monad Environment Configuration
KEYSTORE_PASSWORD=${KEYSTORE_PASSWORD:-}
NETWORK=${NETWORK}

# Retention settings (in minutes)
RETENTION_BFT_HEADERS=${RETENTION_BFT_HEADERS:-10080}
RETENTION_BFT_BODIES=${RETENTION_BFT_BODIES:-10080}
RETENTION_EXEC_BLOCKS=${RETENTION_EXEC_BLOCKS:-10080}
RETENTION_EXEC_RECEIPTS=${RETENTION_EXEC_RECEIPTS:-10080}

# Archive configuration (optional)
${ARCHIVE_API_KEY:+ARCHIVE_API_KEY=${ARCHIVE_API_KEY}}
${ARCHIVE_BUCKET:+ARCHIVE_BUCKET=${ARCHIVE_BUCKET}}
${MONGO_URL:+MONGO_URL=${MONGO_URL}}
${MONGO_DB_NAME:+MONGO_DB_NAME=${MONGO_DB_NAME}}

# Remote configuration URLs
${VALIDATORS_REMOTE_URL:+VALIDATORS_REMOTE_URL=${VALIDATORS_REMOTE_URL}}
${FORKPOINT_REMOTE_URL:+FORKPOINT_REMOTE_URL=${FORKPOINT_REMOTE_URL}}
EOF

echo ".env created"

# Export extra flags for execution client (for RPC nodes)
export EXECUTION_EXTRA_FLAGS="${EXECUTION_EXTRA_FLAGS:-}"
if [ "${ENABLE_TRACE_CALLS}" = "true" ]; then
    export EXECUTION_EXTRA_FLAGS="${EXECUTION_EXTRA_FLAGS} --trace_calls"
fi

# If archive configuration is provided, add flags
if [ -n "${ARCHIVE_API_KEY:-}" ] && [ -n "${ARCHIVE_BUCKET:-}" ]; then
    export EXECUTION_EXTRA_FLAGS="${EXECUTION_EXTRA_FLAGS} --s3-bucket ${ARCHIVE_BUCKET} --region ${ARCHIVE_REGION:-us-east-1} --archive-url ${ARCHIVE_URL} --archive-api-key ${ARCHIVE_API_KEY}"
fi

if [ -n "${MONGO_URL:-}" ]; then
    export EXECUTION_EXTRA_FLAGS="${EXECUTION_EXTRA_FLAGS} --mongo-url ${MONGO_URL} --mongo-db-name ${MONGO_DB_NAME:-monad-archive} --use-eth-get-logs-index"
fi

# Mark as initialized
touch /home/monad/.initialized

echo ""
echo "=================================================="
echo "  Initialization complete!"
echo "=================================================="
echo "Starting Monad services:"
echo "  - monad-bft (consensus)"
echo "  - monad-execution (execution layer)"
echo "  - monad-rpc (RPC server)"
echo "=================================================="

# Execute the command (supervisord)
exec "$@"
