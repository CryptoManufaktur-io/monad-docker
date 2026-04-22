# monad-docker

Docker compose for Monad full node.

Meant to be used with [central-proxy-docker](https://github.com/CryptoManufaktur-io/central-proxy-docker) for traefik
and Prometheus remote write; use `:ext-network.yml` in `COMPOSE_FILE` inside `.env` in that case.

## Quick setup

Run `cp default.env .env`, then `nano .env`, and update values like NETWORK, NODE_NAME, and SNAPSHOT.

If you want the RPC ports exposed locally, use `monad-exposed.yml` in `COMPOSE_FILE` inside `.env`.

- `./ethd install` brings in docker-ce, if you don't have Docker installed already.
- `./ethd up`

To update the software, run `./ethd update` and then `./ethd up`

## Upgrading Monad

To upgrade to a new Monad version:

1. Update `MONAD_VERSION` in `.env` to the desired version tag (e.g., `0.14.1`).
2. Run `./ethd update` to rebuild the Docker image with the new binary.
3. Run `./ethd up` to start the node with the new version.

The Monad binaries are installed from the official Category Labs APT repository during `docker compose build`.

## Check sync

`./ethd check-sync` compares the local node status with a public Monad RPC.

Defaults used when no flags are provided:
- Compose service: `monad`
- Local RPC: `http://127.0.0.1:${RPC_PORT:-8545}`

Usage:
- `./ethd check-sync --public-rpc https://monad-rpc.publicnode.com:443`
- `./ethd check-sync --compose-service monad --public-rpc https://monad-rpc.example.com:443`

## CLI

An image with the monad binaries is available, e.g:

- `docker compose run --rm --profile tools cli monad --version`

## Version

Monad Docker uses a semver scheme.

This is monad-docker v1.0.0
