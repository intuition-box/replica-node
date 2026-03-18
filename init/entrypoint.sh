#!/bin/sh
set -e

STATUS_DIR="/status"
STATUS_FILE="$STATUS_DIR/status.json"
DATA_DIR="/data"
READY_FILE="$DATA_DIR/.ready"
SNAPSHOT_URL="${SNAPSHOT_URL:-https://constellationlabs-dashboard-beta.s3.amazonaws.com/intuition-03-11-2026.tar.gz}"
OFFICIAL_RPC="${OFFICIAL_RPC:-https://rpc.intuition.systems/http}"
NITRO_RPC="${NITRO_RPC:-http://nitro:8545}"
BASE_RPC_URL="${BASE_RPC_URL:-}"
DOCKER_SOCK="/var/run/docker.sock"
ROLLUP_CONTRACT="0x6B78C90257A7a12a3E91EbF3CAFcc7E518FAcD38"
TOTAL_ASSERTIONS=""

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

# Query total assertion count from rollup contract on Base (latestNodeCreated)
get_total_assertions() {
  if [ -n "$TOTAL_ASSERTIONS" ]; then
    echo "$TOTAL_ASSERTIONS"
    return
  fi
  # latestNodeCreated() selector = 0x7ba9534a
  result=$(curl -sf -X POST "$BASE_RPC_URL" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$ROLLUP_CONTRACT\",\"data\":\"0x7ba9534a\"},\"latest\"],\"id\":1}" 2>/dev/null)
  if [ $? -eq 0 ] && [ -n "$result" ]; then
    hex=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)
    if [ -n "$hex" ]; then
      TOTAL_ASSERTIONS=$(printf "%d" "$hex" 2>/dev/null || echo "")
      echo "$TOTAL_ASSERTIONS"
    fi
  fi
}

# Find nitro container ID via Docker socket
get_nitro_container_id() {
  curl -sf --unix-socket "$DOCKER_SOCK" "http://localhost/containers/json" 2>/dev/null \
    | jq -r '.[] | select(.Image | contains("nitro")) | .Id' 2>/dev/null \
    | head -1
}

# Read batch scan progress from nitro's logs via Docker socket
get_batch_progress() {
  NITRO_ID=$(get_nitro_container_id)
  if [ -z "$NITRO_ID" ]; then
    echo ""
    return
  fi

  # Get last 200 lines of logs, look for batch info
  LOGS=$(curl -sf --unix-socket "$DOCKER_SOCK" \
    "http://localhost/containers/$NITRO_ID/logs?stderr=true&stdout=true&tail=200" 2>/dev/null \
    | tr -d '\000-\010\016-\037' || true)

  # Extract "Expecting to find sequencer batches" line for total
  TOTAL_BATCHES=$(echo "$LOGS" | grep -o 'checkingBatchCount=[0-9]*' | tail -1 | cut -d= -f2)
  OUR_BATCHES=$(echo "$LOGS" | grep -o 'ourLatestBatchCount=[0-9]*' | tail -1 | cut -d= -f2)

  # Extract latest "Found sequencer batches" for current position
  CURRENT_BATCH=$(echo "$LOGS" | grep -o 'firstSequenceNumber=[0-9]*' | tail -1 | cut -d= -f2)

  # Check if we're getting new batches (not just duplicates)
  NEW_BATCHES=$(echo "$LOGS" | grep 'Found sequencer batches' | tail -1 | grep -o 'newBatchesCount=[0-9]*' | cut -d= -f2)

  # Also check assertion validation progress
  ASSERTION_NODE=$(echo "$LOGS" | grep -o 'node=[0-9]*' | tail -1 | cut -d= -f2)

  if [ -n "$TOTAL_BATCHES" ] && [ -n "$CURRENT_BATCH" ]; then
    echo "${CURRENT_BATCH}:${TOTAL_BATCHES}:${OUR_BATCHES:-0}:${NEW_BATCHES:-0}:${ASSERTION_NODE:-0}"
  elif [ -n "$ASSERTION_NODE" ]; then
    # Still in assertion validation, no batch data yet
    echo "0:0:0:0:${ASSERTION_NODE}"
  else
    echo ""
  fi
}

# --- Start HTTP status server in background ---
# Use a CGI script with busybox httpd for reliable concurrent connections
mkdir -p /srv/cgi-bin
cat > /srv/cgi-bin/status <<'CGIEOF'
#!/bin/sh
echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo "Cache-Control: no-cache"
echo ""
cat /status/status.json 2>/dev/null || echo '{"phase":"installing"}'
CGIEOF
chmod +x /srv/cgi-bin/status

busybox httpd -f -p 9000 -h /srv &

# --- Lifecycle ---

# Check if data already exists with meaningful chain data (>10GB = real snapshot, not fresh nitro)
CHAINDATA_SIZE=0
if [ -d "$DATA_DIR/intuition/nitro/l2chaindata" ]; then
  CHAINDATA_SIZE=$(du -s "$DATA_DIR/intuition/nitro/l2chaindata" 2>/dev/null | awk '{print $1}')
  CHAINDATA_SIZE=${CHAINDATA_SIZE:-0}
fi

if [ "$CHAINDATA_SIZE" -gt 10000000 ] 2>/dev/null; then
  echo "Existing chain data found ($(($CHAINDATA_SIZE / 1048576)) GB), skipping download"
  write_status '{"phase":"starting","message":"Existing data found, starting node..."}'
  touch "$READY_FILE"
else
  # Remove any fresh nitro data (created before snapshot was ready)
  if [ -d "$DATA_DIR/intuition" ]; then
    echo "Removing incomplete chain data, will restore from snapshot"
    rm -rf "$DATA_DIR/intuition"
  fi

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

  # Handle nested directory structure (snapshot extracts to mnt/datadir/intuition/)
  # Nitro expects data at /home/user/.arbitrum/intuition/ which maps to $DATA_DIR/intuition/
  # Remove any existing intuition dir first to avoid nesting (mv into existing dir)
  SNAPSHOT_SRC=""
  if [ -d "$DATA_DIR/mnt/datadir/intuition" ]; then
    SNAPSHOT_SRC="$DATA_DIR/mnt/datadir/intuition"
  elif [ -d "$DATA_DIR/mnt/datadir" ]; then
    SNAPSHOT_SRC="$DATA_DIR/mnt/datadir"
  fi

  if [ -n "$SNAPSHOT_SRC" ]; then
    rm -rf "$DATA_DIR/intuition"
    mv "$SNAPSHOT_SRC" "$DATA_DIR/intuition"
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
SNAPSHOT_BLOCK=""

while true; do
  sleep 5

  LOCAL_BLOCK=$(get_block "$NITRO_RPC")
  OFFICIAL_BLOCK=$(get_block "$OFFICIAL_RPC")
  UPDATED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [ -z "$LOCAL_BLOCK" ]; then
    write_status '{"phase":"starting","message":"Waiting for node to respond..."}'
    continue
  fi

  if [ -z "$OFFICIAL_BLOCK" ]; then
    OFFICIAL_BLOCK=0
  fi

  # Remember the first block we see (snapshot block)
  if [ -z "$SNAPSHOT_BLOCK" ]; then
    SNAPSHOT_BLOCK=$LOCAL_BLOCK
  fi

  DIFF=$((OFFICIAL_BLOCK - LOCAL_BLOCK))
  if [ "$DIFF" -lt 0 ]; then
    DIFF=0
  fi

  # Detect batch scanning phase:
  # Block is stuck at snapshot height (or 0) while node scans historical batches on Base
  if [ "$LOCAL_BLOCK" -eq "$SNAPSHOT_BLOCK" ] && [ "$DIFF" -gt 10 ]; then
    BATCH_INFO=$(get_batch_progress)
    if [ -n "$BATCH_INFO" ]; then
      CURRENT_BATCH=$(echo "$BATCH_INFO" | cut -d: -f1)
      TOTAL_BATCHES=$(echo "$BATCH_INFO" | cut -d: -f2)
      OUR_BATCHES=$(echo "$BATCH_INFO" | cut -d: -f3)
      NEW_BATCHES=$(echo "$BATCH_INFO" | cut -d: -f4)
      ASSERTION_NODE=$(echo "$BATCH_INFO" | cut -d: -f5)

      if [ "$TOTAL_BATCHES" -gt 0 ] 2>/dev/null; then
        SCAN_PCT=$((CURRENT_BATCH * 100 / TOTAL_BATCHES))
        write_status "{\"phase\":\"scanning\",\"scanStep\":\"batches\",\"currentBatch\":$CURRENT_BATCH,\"totalBatches\":$TOTAL_BATCHES,\"knownBatches\":$OUR_BATCHES,\"newBatches\":$NEW_BATCHES,\"scanProgress\":$SCAN_PCT,\"localBlock\":$LOCAL_BLOCK,\"officialBlock\":$OFFICIAL_BLOCK,\"blockDiff\":$DIFF,\"updatedAt\":\"$UPDATED\"}"
      elif [ "${ASSERTION_NODE:-0}" -gt 0 ] 2>/dev/null; then
        ASSERT_TOTAL=$(get_total_assertions)
        ASSERT_TOTAL=${ASSERT_TOTAL:-0}
        if [ "$ASSERT_TOTAL" -gt 0 ] 2>/dev/null; then
          ASSERT_PCT=$((ASSERTION_NODE * 100 / ASSERT_TOTAL))
        else
          ASSERT_PCT=0
        fi
        write_status "{\"phase\":\"scanning\",\"scanStep\":\"assertions\",\"assertionNode\":$ASSERTION_NODE,\"totalAssertions\":$ASSERT_TOTAL,\"assertionProgress\":$ASSERT_PCT,\"currentBatch\":0,\"totalBatches\":0,\"scanProgress\":0,\"localBlock\":$LOCAL_BLOCK,\"officialBlock\":$OFFICIAL_BLOCK,\"blockDiff\":$DIFF,\"updatedAt\":\"$UPDATED\"}"
      else
        write_status "{\"phase\":\"scanning\",\"scanStep\":\"starting\",\"currentBatch\":0,\"totalBatches\":0,\"scanProgress\":0,\"localBlock\":$LOCAL_BLOCK,\"officialBlock\":$OFFICIAL_BLOCK,\"blockDiff\":$DIFF,\"updatedAt\":\"$UPDATED\"}"
      fi
    else
      write_status "{\"phase\":\"scanning\",\"scanStep\":\"starting\",\"currentBatch\":0,\"totalBatches\":0,\"scanProgress\":0,\"localBlock\":$LOCAL_BLOCK,\"officialBlock\":$OFFICIAL_BLOCK,\"blockDiff\":$DIFF,\"updatedAt\":\"$UPDATED\"}"
    fi
    continue
  fi

  # Calculate blocks per minute
  NOW=$(date +%s)
  ELAPSED=$((NOW - PREV_TIME))
  if [ "$ELAPSED" -gt 0 ] && [ "$PREV_BLOCK" -gt 0 ] && [ "$LOCAL_BLOCK" -gt "$PREV_BLOCK" ]; then
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

  write_status "{\"phase\":\"$PHASE\",\"localBlock\":$LOCAL_BLOCK,\"officialBlock\":$OFFICIAL_BLOCK,\"blockDiff\":$DIFF,\"blocksPerMinute\":$BPM,\"updatedAt\":\"$UPDATED\"}"
done
