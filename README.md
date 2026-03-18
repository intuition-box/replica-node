# Intuition L3 Replica Node

One-click deployable replica node for the Intuition L3 (Arbitrum Nitro on Base).

Deploy via [Coolify](https://coolify.io), Docker Compose, or any Docker-based PaaS.

> **Just need a personal local RPC?** See [local-rpc.md](local-rpc.md) — single Docker command, no dashboard or API keys.

## Quick Start (Coolify)

1. Create a new **Docker Compose** project in Coolify
2. Point it to this repository
3. Add environment variable: `BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY`
4. Set your domain (e.g. `rpc.yourdomain.com`)
5. Deploy

Coolify handles SSL. Your node will be available at:
- `https://rpc.yourdomain.com/` -- Status dashboard
- `https://rpc.yourdomain.com/http` -- JSON-RPC endpoint
- `https://rpc.yourdomain.com/ws` -- WebSocket endpoint

## Quick Start (Docker Compose)

```bash
git clone https://github.com/intuition-box/l3-node.git
cd l3-node
cp .env.example .env
# Edit .env and set BASE_RPC_URL
docker compose up -d
```

Open `http://localhost` to see the status dashboard.

## Getting a Base RPC URL (Alchemy)

The node needs a Base mainnet RPC endpoint to read the parent chain. Here's how to get one:

1. Go to [dashboard.alchemy.com](https://dashboard.alchemy.com/) and sign up
2. Click **Create New App**
3. Select chain **Base**, network **Mainnet**
4. Copy the HTTP endpoint URL: `https://base-mainnet.g.alchemy.com/v2/YOUR_KEY`
5. Set it as `BASE_RPC_URL`

### Which Alchemy plan do you need?

| | Free | Pay As You Go |
|---|---|---|
| **Cost** | $0/mo | ~$5 for initial sync, ~$1/mo ongoing |
| **Monthly compute units** | 30M | Unlimited (pay per use) |
| **Throughput** | 25 req/s | 300 req/s |

**The Free tier works fine for ongoing operation** (~1-2M CU/month used, well under the 30M limit).

The main consideration is **initial sync speed**:
- During first sync, the node scans thousands of sequencer batches on Base. This uses ~5-10M compute units total (within the free budget) but the Free tier's 25 req/s rate limit makes it slower.
- Pay As You Go gives 300 req/s, making sync ~10x faster, for a one-time cost of ~$5.
- After sync, the Free tier handles ongoing polling easily.

**Recommendation**: Start on Free. If sync feels too slow, temporarily switch to Pay As You Go (~$5 total), then switch back.

## Network Details

| Parameter | Value |
|---|---|
| Chain ID | `1155` |
| Parent Chain | Base (`8453`) |
| Node Software | Arbitrum Nitro v3.7.1 |
| RPC Port | `8545` (HTTP) |
| WS Port | `8546` (WebSocket) |

## Architecture

```
Ethereum L1 --> Base L2 (8453) --> Intuition L3 (1155)

                 +-----------+
  Browser -----> |  gateway   | :80
                 |  (nginx)   |
                 +-----+------+
                       |
          +------------+------------+
          |            |            |
     /    |      /http |      /ws   |     /api/status
          |            |            |          |
   static files   nitro:8545   nitro:8546   init:9000
                       |
                  Base RPC
              (parent chain)
```

**Services:**
- **init** -- Downloads snapshot, tracks lifecycle, serves status API
- **nitro** -- Arbitrum Nitro node (official image)
- **gateway** -- Nginx reverse proxy + dashboard static files

## Environment Variables

| Variable | Required | Default |
|---|---|---|
| `BASE_RPC_URL` | Yes | -- |
| `SNAPSHOT_URL` | No | S3 snapshot URL (pre-configured) |

## Node Lifecycle

The dashboard shows real-time progress through these phases:

1. **Downloading** -- Fetches the ~32 GB chain snapshot from S3
2. **Extracting** -- Unpacks to ~43 GB datadir
3. **Starting** -- Nitro node boots and connects to Base
4. **Syncing** -- Catches up to chain head (scans batches, then processes new blocks)
5. **Synced** -- Following chain in real-time

On subsequent deploys, the datadir volume persists -- the node skips straight to Starting.

## Minimum Requirements

| Resource | Minimum |
|---|---|
| CPU | 2 cores |
| RAM | 2 GB |
| Disk | 100 GB |
| Network | Stable connection |

## Key Contracts (on Base)

| Contract | Address |
|---|---|
| Bridge | `0x98EC528e10d54c3Db77c08021644DBe48e994726` |
| Inbox | `0x9F82973d054809dD9cae4836d70ce70DcE1403B0` |
| Sequencer Inbox | `0xFC239694C97b06BF2409C88EA199f7110f39A9bF` |
| Rollup | `0x6B78C90257A7a12a3E91EbF3CAFcc7E518FAcD38` |
