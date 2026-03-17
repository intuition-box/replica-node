#!/bin/sh
set -e

STATUS_DIR="/status"
STATUS_FILE="$STATUS_DIR/status.json"
DATA_DIR="/data"
READY_FILE="$DATA_DIR/.ready"
SNAPSHOT_URL="${SNAPSHOT_URL:-https://constellationlabs-dashboard-beta.s3.amazonaws.com/intuition-03-11-2026.tar.gz}"
OFFICIAL_RPC="${OFFICIAL_RPC:-https://rpc.intuition.systems/http}"
NITRO_RPC="${NITRO_RPC:-http://nitro:8545}"

mkdir -p "$STATUS_DIR" "$DATA_DIR"

# Write initial status immediately so /api/status never 502s
echo '{"phase":"installing"}' > "$STATUS_FILE"

write_status() {
  echo "$1" > "$STATUS_FILE"
}

get_block() {
  result=$(curl -sf -X POST "$1" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null)
  if [ $? -eq 0 ] && [ -n "$result" ]; then
    hex=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)
    if [ -n "$hex" ]; then
      printf "%d" "$hex" 2>/dev/null || echo ""
    fi
  fi
}

# --- Start HTTP status server in background ---
start_status_server() {
  mkdir -p /srv/api
  ln -sf "$STATUS_FILE" /srv/api/status
  while true; do
    {
      echo "HTTP/1.1 200 OK"
      echo "Content-Type: application/json"
      echo "Access-Control-Allow-Origin: *"
      echo "Cache-Control: no-cache"
      echo "Connection: close"
      echo ""
      cat "$STATUS_FILE" 2>/dev/null || echo '{"phase":"installing"}'
    } | nc -l -p 9000 -w 1 > /dev/null 2>&1 || true
  done
}

start_status_server &

# --- Lifecycle ---

# Check if datadir already exists
if [ -d "$DATA_DIR/datadir" ] && [ "$(ls -A $DATA_DIR/datadir 2>/dev/null)" ]; then
  echo "Existing datadir found, skipping download"
  write_status '{"phase":"starting","message":"Existing data found, starting node..."}'
  touch "$READY_FILE"
else
  # Download snapshot
  echo "Downloading snapshot from $SNAPSHOT_URL"

  # Get file size for progress tracking
  TOTAL_BYTES=$(curl -sI "$SNAPSHOT_URL" | grep -i content-length | awk '{print $2}' | tr -d '\r')
  TOTAL_BYTES=${TOTAL_BYTES:-34000000000}

  write_status "{\"phase\":\"downloading\",\"progress\":0,\"totalBytes\":$TOTAL_BYTES}"

  # Start download in background
  curl -L -o "$DATA_DIR/snapshot.tar.gz" "$SNAPSHOT_URL" 2>/dev/null &
  DL_PID=$!

  # Monitor progress
  while kill -0 $DL_PID 2>/dev/null; do
    if [ -f "$DATA_DIR/snapshot.tar.gz" ]; then
      CURRENT=$(stat -c%s "$DATA_DIR/snapshot.tar.gz" 2>/dev/null || echo 0)
      if [ "$TOTAL_BYTES" -gt 0 ] 2>/dev/null; then
        PROGRESS=$((CURRENT * 100 / TOTAL_BYTES))
        CURRENT_GB=$((CURRENT / 1073741824))
        TOTAL_GB=$((TOTAL_BYTES / 1073741824))
        write_status "{\"phase\":\"downloading\",\"progress\":$PROGRESS,\"downloadedBytes\":$CURRENT,\"totalBytes\":$TOTAL_BYTES,\"downloadedGB\":$CURRENT_GB,\"totalGB\":$TOTAL_GB}"
      fi
    fi
    sleep 2
  done

  wait $DL_PID || { echo "Download failed"; write_status '{"phase":"error","message":"Snapshot download failed"}'; exit 1; }

  write_status '{"phase":"extracting","message":"Extracting snapshot..."}'
  echo "Extracting snapshot..."

  cd "$DATA_DIR"
  tar -xzf snapshot.tar.gz

  # Handle nested directory structure (snapshot extracts to mnt/datadir)
  if [ -d "$DATA_DIR/mnt/datadir" ]; then
    mv "$DATA_DIR/mnt/datadir" "$DATA_DIR/datadir"
    rm -rf "$DATA_DIR/mnt"
  fi

  rm -f "$DATA_DIR/snapshot.tar.gz"
  echo "Extraction complete"

  write_status '{"phase":"starting","message":"Starting node..."}'
  touch "$READY_FILE"
fi

# --- Monitoring loop ---
echo "Entering monitoring loop"
PREV_BLOCK=0
PREV_TIME=$(date +%s)

while true; do
  sleep 5

  LOCAL_BLOCK=$(get_block "$NITRO_RPC")
  OFFICIAL_BLOCK=$(get_block "$OFFICIAL_RPC")

  if [ -z "$LOCAL_BLOCK" ]; then
    write_status '{"phase":"starting","message":"Waiting for node to respond..."}'
    continue
  fi

  if [ -z "$OFFICIAL_BLOCK" ]; then
    OFFICIAL_BLOCK=0
  fi

  DIFF=$((OFFICIAL_BLOCK - LOCAL_BLOCK))
  if [ "$DIFF" -lt 0 ]; then
    DIFF=0
  fi

  # Calculate blocks per minute
  NOW=$(date +%s)
  ELAPSED=$((NOW - PREV_TIME))
  if [ "$ELAPSED" -gt 0 ] && [ "$PREV_BLOCK" -gt 0 ]; then
    BLOCKS_GAINED=$((LOCAL_BLOCK - PREV_BLOCK))
    BPM=$((BLOCKS_GAINED * 60 / ELAPSED))
  else
    BPM=0
  fi

  PREV_BLOCK=$LOCAL_BLOCK
  PREV_TIME=$NOW

  if [ "$DIFF" -le 2 ]; then
    PHASE="synced"
  else
    PHASE="syncing"
  fi

  UPDATED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  write_status "{\"phase\":\"$PHASE\",\"localBlock\":$LOCAL_BLOCK,\"officialBlock\":$OFFICIAL_BLOCK,\"blockDiff\":$DIFF,\"blocksPerMinute\":$BPM,\"updatedAt\":\"$UPDATED\"}"
done
