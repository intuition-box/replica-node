# Local RPC — Personal Setup

Run a personal Intuition L3 RPC node on your machine. No dashboard, no API key protected gateway — one simple RPC endpoint in local.

> The official replica guide from the Intuition team can be found at [hub.intuition.systems](https://hub.intuition.systems/) (`replica-guide.zip`).

## Prerequisites

- Docker
- A Base mainnet RPC URL ([get one from Alchemy](https://dashboard.alchemy.com/))
- ~80 GB free disk space

## 1. Create a working directory

```bash
mkdir intuition-rpc && cd intuition-rpc
```

## 2. Download the node config

```bash
curl -O https://raw.githubusercontent.com/intuition-box/RPC/main/nodeConfig.json
```

## 3. Download and extract the snapshot

```bash
curl -L -o snapshot.tar.gz https://constellationlabs-dashboard-beta.s3.amazonaws.com/intuition-03-11-2026.tar.gz
tar -xzf snapshot.tar.gz
mv mnt/datadir/intuition ./datadir/intuition
rm -rf mnt snapshot.tar.gz
```

This downloads ~32 GB and extracts to ~43 GB.

## 4. Start the node

```bash
docker run -d \
  --name intuition-rpc \
  -p 8545:8545 \
  -p 8546:8546 \
  -v $(pwd)/nodeConfig.json:/config/nodeConfig.json:ro \
  -v $(pwd)/datadir:/home/user/.arbitrum \
  --restart unless-stopped \
  public.ecr.aws/i6b2w2n6/nitro-node:v3.7.1 \
  --conf.file=/config/nodeConfig.json \
  --node.staker.enable \
  --node.staker.strategy=Watchtower \
  --execution.forwarding-target=wss://rpc.intuition.systems/ws \
  --node.feed.input.url=wss://rpc.intuition.systems/feed \
  --parent-chain.connection.url=YOUR_BASE_RPC_URL \
  --node.dangerous.disable-blob-reader \
  --node.data-availability.rest-aggregator.urls=https://rpc.intuition.systems/rest-aggregator \
  --node.data-availability.parent-chain-node-url=YOUR_BASE_RPC_URL
```

Replace `YOUR_BASE_RPC_URL` with your Alchemy Base URL.

## 5. Use it

Once synced (~10 minutes after snapshot), your RPC is at:

- **HTTP**: `http://localhost:8545`
- **WebSocket**: `ws://localhost:8546`

## Quick checks

```bash
# Current block
curl -s -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Chain ID (should be 1155)
curl -s -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'

# Logs
docker logs -f intuition-rpc
```

## Stop / Restart

```bash
docker stop intuition-rpc
docker start intuition-rpc    # resumes from where it left off
docker rm intuition-rpc       # remove (datadir is preserved)
```
