# Intuition L3 Replica Node

A self-hosted RPC node for the Intuition L3 (Arbitrum Nitro on Base).

Two ways to run it:

- **Production** — deploy via [Coolify](https://coolify.io), [Dokploy](https://dokploy.com), or any Docker-based PaaS. Includes a status dashboard, nginx gateway with optional API key protection, and automatic snapshot download.
- **Local** — run a single Docker container for a personal RPC at `localhost:8545`. See [local-rpc.md](local-rpc.md).

---

## Quick Start (PaaS)

1. Create a new **Docker Compose** project in your PaaS (Coolify, Dokploy, etc.)
2. Point it to this repository
3. Add environment variable: `BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY`
4. Set your domain (e.g. `rpc.yourdomain.com`) on the **gateway** service
5. Deploy

Your node will be available at:

| Endpoint | URL |
|---|---|
| Dashboard | `https://rpc.yourdomain.com/` |
| RPC (HTTP) | `https://rpc.yourdomain.com/http` |
| RPC (WS) | `wss://rpc.yourdomain.com/ws` |

## Quick Start (Docker Compose)

```bash
git clone https://github.com/intuition-box/RPC.git
cd RPC
cp .env.example .env
# Edit .env and set BASE_RPC_URL
docker compose up -d
```

Open `http://localhost` to see the status dashboard.

---

## Architecture

The production setup runs three services:

```
                 +-----------+
  Browser -----> |  gateway   | :80
                 |  (nginx)   |
                 +-----+------+
                       |
          +------+-----+-----+--------+
          |      |           |         |
     /    |  /http/KEY  /ws/KEY  /api/status
          |      |           |         |
   dashboard  nitro:8545  nitro:8546  init:9000
                    |
               Base RPC
           (parent chain)
```

### gateway (nginx)

The entry point for all traffic. It serves the static dashboard, proxies RPC requests to the Nitro node, and handles API key validation.

When API keys are configured, the gateway extracts the key from the URL path (`/http/KEY`) and validates it against a key map file before forwarding the request to Nitro. Requests without a valid key receive a `401` response. The dashboard and status API remain public.

The gateway runs a custom entrypoint that generates the nginx key map on startup from configured keys, then starts nginx.

### nitro (Arbitrum Nitro)

The actual blockchain node. It syncs the Intuition L3 chain by reading sequencer batches from Base, connecting to the sequencer feed for real-time blocks, and forwarding user transactions to the sequencer.

Based on the official `public.ecr.aws/i6b2w2n6/nitro-node:v3.7.1` image with `nodeConfig.json` baked in. Runs in Watchtower mode (passive validation, no staking).

### init (lifecycle manager)

Handles first-time setup and ongoing monitoring. On fresh deploys, it downloads the ~32 GB chain snapshot from S3, extracts it, and writes a `.ready` marker file. After setup, it enters a monitoring loop — polling the Nitro node and the official RPC to track sync status, which it writes to a JSON file served to the dashboard.

Also reads Nitro's container logs (via Docker socket) to report detailed progress during the assertion validation and batch scanning phases.

---

## API Key Protection

The gateway supports three authentication modes, selected automatically based on configuration:

### Open access (default)

No `API_KEY` env var set, no keys in `keys.json`. All requests pass through — anyone can query `/http` and `/ws` without a key.

### Single key

Set `API_KEY` in your environment variables. Only requests with this key in the URL are accepted:

```
https://rpc.yourdomain.com/http/YOUR_KEY
wss://rpc.yourdomain.com/ws/YOUR_KEY
```

Works like Alchemy or Infura — paste the full URL into any web3 library.

### Multi-key (CLI)

For operators serving multiple users. Manage keys from the gateway container:

```bash
docker exec <gateway> rpc-keys add "alice"
#   Key created for "alice":
#   3f6f895b44dfdf87f131ade3fe49e7d8
#
#   HTTP: https://rpc.yourdomain.com/http/3f6f895b44dfdf87f131ade3fe49e7d8
#   WS:   wss://rpc.yourdomain.com/ws/3f6f895b44dfdf87f131ade3fe49e7d8

docker exec <gateway> rpc-keys list       # all keys + request counts
docker exec <gateway> rpc-keys stats      # global request stats
docker exec <gateway> rpc-keys stats alice # per-user stats
docker exec <gateway> rpc-keys revoke alice
docker exec <gateway> rpc-keys rotate alice
```

Keys are stored in `/data/keys.json` on a persistent volume. When a key is added, revoked, or rotated, the CLI regenerates the nginx key map and reloads nginx with zero downtime.

Request stats are parsed from the nginx access log — no database needed.

### How it works internally

1. nginx extracts the key from the URL using a `map` directive: `/http/KEY` → `KEY`
2. The key is validated against `/etc/nginx/keys.map` (a generated file listing valid keys)
3. If valid, the request is rewritten to `/` and proxied to Nitro
4. If invalid, nginx returns `401 {"error":"Invalid or missing API key"}`
5. The dashboard (`/`) and status API (`/api/status`) are always public

The key check happens entirely in nginx — no external service, no database lookup, no added latency.

---

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BASE_RPC_URL` | Yes | -- | Base mainnet RPC URL (Alchemy, Infura, etc.) |
| `API_KEY` | No | -- | Single API key for simple auth |
| `DOMAIN` | No | auto-detected | Domain shown in CLI output (auto-detected on Coolify) |
| `SNAPSHOT_URL` | No | pre-configured | Override S3 snapshot URL |

---

## Getting a Base RPC URL (Alchemy)

The node needs a Base mainnet RPC endpoint to read the parent chain.

1. Go to [dashboard.alchemy.com](https://dashboard.alchemy.com/) and sign up
2. Click **Create New App**
3. Select chain **Base**, network **Mainnet**
4. Copy the HTTP endpoint URL: `https://base-mainnet.g.alchemy.com/v2/YOUR_KEY`
5. Set it as `BASE_RPC_URL`

### Which Alchemy plan do you need?

| | Free | Pay As You Go |
|---|---|---|
| **Cost** | $0/mo | < $1 for initial sync, < $1/mo ongoing |
| **Monthly compute units** | 30M | Unlimited (pay per use) |
| **Throughput** | 25 req/s | 300 req/s |

**Recommendation**: Use Pay As You Go. A full sync costs less than $1 and ongoing usage is under $1/month. The Free tier works for ongoing operation but the 25 req/s limit makes initial sync very slow.

---

## Node Lifecycle

The dashboard shows real-time progress through these phases:

1. **Downloading** — Fetches the ~32 GB chain snapshot from S3 ([details](docs/downloading.md))
2. **Extracting** — Unpacks to ~43 GB datadir ([details](docs/extracting.md))
3. **Starting** — Nitro node boots and connects to Base ([details](docs/starting.md))
4. **Scanning** — Validates assertions and scans sequencer batches ([details](docs/scanning.md))
5. **Syncing** — Catches up to chain head ([details](docs/syncing.md))
6. **Synced** — Following chain in real-time ([details](docs/synced.md))

On subsequent deploys, the datadir volume persists — the node skips straight to Starting.

---

## Network Details

| Parameter | Value |
|---|---|
| Chain ID | `1155` |
| Parent Chain | Base (`8453`) |
| Node Software | Arbitrum Nitro v3.7.1 |

## Minimum Requirements

| Resource | Minimum |
|---|---|
| CPU | 2 cores |
| RAM | 2 GB |
| Disk | 100 GB |
| Network | Stable connection |

### Example: Hetzner CPX32

A good budget option at ~$10/month:

| | |
|---|---|
| CPU | 4 vCPU |
| RAM | 8 GB |
| Disk | 160 GB |
| Price | ~$10.49/mo |

## Key Contracts (on Base)

| Contract | Address |
|---|---|
| Bridge | `0x98EC528e10d54c3Db77c08021644DBe48e994726` |
| Inbox | `0x9F82973d054809dD9cae4836d70ce70DcE1403B0` |
| Sequencer Inbox | `0xFC239694C97b06BF2409C88EA199f7110f39A9bF` |
| Rollup | `0x6B78C90257A7a12a3E91EbF3CAFcc7E518FAcD38` |
