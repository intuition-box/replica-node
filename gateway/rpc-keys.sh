#!/bin/sh
set -e

KEYS_FILE="${KEYS_FILE:-/data/keys.json}"
KEYS_MAP="/etc/nginx/keys.map"
LOG_FILE="/data/rpc.log"
DOMAIN="${DOMAIN:-${SERVICE_FQDN_GATEWAY:-${COOLIFY_FQDN:-}}}"

# Ensure keys.json exists
if [ ! -f "$KEYS_FILE" ]; then
  echo '[]' > "$KEYS_FILE"
fi

generate_key() {
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Regenerate nginx keys.map from keys.json + API_KEY env var, then reload nginx
rebuild_map() {
  echo "# Auto-generated - do not edit" > "$KEYS_MAP"

  KEY_COUNT=0

  # Add API_KEY env var if set
  if [ -n "$API_KEY" ]; then
    echo "\"$API_KEY\" 1;" >> "$KEYS_MAP"
    KEY_COUNT=$((KEY_COUNT + 1))
  fi

  # Add keys from keys.json
  ACTIVE=$(jq -r '.[] | select(.revoked != true) | .key' "$KEYS_FILE" 2>/dev/null)
  for k in $ACTIVE; do
    echo "\"$k\" 1;" >> "$KEYS_MAP"
    KEY_COUNT=$((KEY_COUNT + 1))
  done

  # If no keys configured, allow everything. Otherwise reject unknown keys.
  if [ "$KEY_COUNT" -eq 0 ]; then
    echo '# No keys configured - open access' > "$KEYS_MAP"
    echo 'default 1;' >> "$KEYS_MAP"
  else
    echo 'default 0;' >> "$KEYS_MAP"
  fi

  # Reload nginx if running
  nginx -s reload 2>/dev/null || true
}

cmd_add() {
  NAME="$1"
  if [ -z "$NAME" ]; then
    echo "Usage: rpc-keys add <name>"
    exit 1
  fi
  KEY=$(generate_key)
  jq --arg k "$KEY" --arg n "$NAME" '. += [{"key": $k, "name": $n, "created_at": (now | strftime("%Y-%m-%d %H:%M:%S")), "revoked": false}]' "$KEYS_FILE" > "$KEYS_FILE.tmp"
  mv "$KEYS_FILE.tmp" "$KEYS_FILE"
  rebuild_map
  echo ""
  echo "  Key created for \"$NAME\":"
  echo "  $KEY"
  echo ""
  if [ -n "$DOMAIN" ]; then
    echo "  HTTP: https://$DOMAIN/http/$KEY"
    echo "  WS:   wss://$DOMAIN/ws/$KEY"
  else
    echo "  HTTP: /http/$KEY"
    echo "  WS:   /ws/$KEY"
  fi
  echo ""
}

# Resolve a key or name to the actual key
resolve_key() {
  INPUT="$1"
  # Try as key first
  FOUND=$(jq -r --arg k "$INPUT" '.[] | select(.key == $k and .revoked != true) | .key' "$KEYS_FILE" 2>/dev/null)
  if [ -n "$FOUND" ]; then
    echo "$FOUND"
    return
  fi
  # Try as name
  FOUND=$(jq -r --arg n "$INPUT" '.[] | select(.name == $n and .revoked != true) | .key' "$KEYS_FILE" 2>/dev/null)
  if [ -n "$FOUND" ]; then
    echo "$FOUND"
    return
  fi
  echo ""
}

cmd_revoke() {
  INPUT="$1"
  if [ -z "$INPUT" ]; then
    echo "Usage: rpc-keys revoke <key|name>"
    exit 1
  fi
  KEY=$(resolve_key "$INPUT")
  if [ -z "$KEY" ]; then
    echo "Key or name \"$INPUT\" not found or already revoked."
    exit 1
  fi
  jq --arg k "$KEY" 'map(if .key == $k then .revoked = true else . end)' "$KEYS_FILE" > "$KEYS_FILE.tmp"
  mv "$KEYS_FILE.tmp" "$KEYS_FILE"
  rebuild_map
  echo "Key revoked."
}

cmd_rotate() {
  INPUT="$1"
  if [ -z "$INPUT" ]; then
    echo "Usage: rpc-keys rotate <key|name>"
    exit 1
  fi
  OLD_KEY=$(resolve_key "$INPUT")
  if [ -z "$OLD_KEY" ]; then
    echo "Key or name \"$INPUT\" not found or already revoked."
    exit 1
  fi
  NAME=$(jq -r --arg k "$OLD_KEY" '.[] | select(.key == $k and .revoked != true) | .name' "$KEYS_FILE")
  if [ -z "$NAME" ]; then
    echo "Key not found or already revoked."
    exit 1
  fi
  # Revoke old
  jq --arg k "$OLD_KEY" 'map(if .key == $k then .revoked = true else . end)' "$KEYS_FILE" > "$KEYS_FILE.tmp"
  mv "$KEYS_FILE.tmp" "$KEYS_FILE"
  # Add new
  NEW_KEY=$(generate_key)
  jq --arg k "$NEW_KEY" --arg n "$NAME" '. += [{"key": $k, "name": $n, "created_at": (now | strftime("%Y-%m-%d %H:%M:%S")), "revoked": false}]' "$KEYS_FILE" > "$KEYS_FILE.tmp"
  mv "$KEYS_FILE.tmp" "$KEYS_FILE"
  rebuild_map
  echo ""
  echo "  Key rotated for \"$NAME\":"
  echo "  Old: $OLD_KEY (revoked)"
  echo "  New: $NEW_KEY"
  echo ""
  if [ -n "$DOMAIN" ]; then
    echo "  HTTP: https://$DOMAIN/http/$NEW_KEY"
    echo "  WS:   wss://$DOMAIN/ws/$NEW_KEY"
    echo ""
  fi
}

cmd_list() {
  KEYS=$(jq -r '.[] | "\(.revoked)\t\(.name)\t\(.key)\t\(.created_at)"' "$KEYS_FILE" 2>/dev/null)
  if [ -z "$KEYS" ]; then
    if [ -n "$API_KEY" ]; then
      echo ""
      echo "  Single key mode (API_KEY env var)"
      echo "  Key: $API_KEY"
      echo ""
    else
      echo ""
      echo "  No API keys configured. RPC is open access."
      echo ""
    fi
    return
  fi

  echo ""
  echo "$KEYS" | while IFS='	' read -r REVOKED NAME KEY CREATED; do
    if [ "$REVOKED" = "true" ]; then
      STATUS=" (REVOKED)"
    else
      STATUS=""
      # Count requests from log
      if [ -f "$LOG_FILE" ]; then
        TOTAL=$(grep -c "key=$KEY " "$LOG_FILE" 2>/dev/null || echo 0)
        TODAY=$(grep "key=$KEY " "$LOG_FILE" 2>/dev/null | grep "^$(date -u +%Y-%m-%d)" | wc -l | tr -d ' ')
        HOUR=$(date -u +%Y-%m-%dT%H)
        LAST_HOUR=$(grep "key=$KEY " "$LOG_FILE" 2>/dev/null | grep "^$HOUR" | wc -l | tr -d ' ')
      else
        TOTAL=0; TODAY=0; LAST_HOUR=0
      fi
    fi

    echo "  $NAME$STATUS"
    echo "  Key:      $KEY"
    echo "  Created:  $CREATED"
    if [ "$REVOKED" != "true" ]; then
      echo "  Requests: $TOTAL total | $TODAY today | $LAST_HOUR last hour"
    fi
    echo ""
  done

  if [ -n "$API_KEY" ]; then
    echo "  + Single key (API_KEY env var): $API_KEY"
    echo ""
  fi
}

cmd_stats() {
  INPUT="$1"
  if [ ! -f "$LOG_FILE" ]; then
    echo "No request logs yet."
    return
  fi

  KEY=""
  if [ -n "$INPUT" ]; then
    KEY=$(resolve_key "$INPUT")
    if [ -z "$KEY" ]; then
      KEY="$INPUT"
    fi
  fi

  if [ -n "$KEY" ]; then
    NAME=$(jq -r --arg k "$KEY" '.[] | select(.key == $k) | .name' "$KEYS_FILE" 2>/dev/null)
    FILTER="key=$KEY "
    LABEL="Stats for ${NAME:-$KEY}"
  else
    FILTER=""
    LABEL="Global stats"
  fi

  if [ -n "$FILTER" ]; then
    TOTAL=$(grep -c "$FILTER" "$LOG_FILE" 2>/dev/null || echo 0)
    TODAY=$(grep "$FILTER" "$LOG_FILE" 2>/dev/null | grep "^$(date -u +%Y-%m-%d)" | wc -l | tr -d ' ')
    HOUR=$(date -u +%Y-%m-%dT%H)
    LAST_HOUR=$(grep "$FILTER" "$LOG_FILE" 2>/dev/null | grep "^$HOUR" | wc -l | tr -d ' ')
  else
    TOTAL=$(wc -l < "$LOG_FILE" | tr -d ' ')
    TODAY=$(grep "^$(date -u +%Y-%m-%d)" "$LOG_FILE" | wc -l | tr -d ' ')
    HOUR=$(date -u +%Y-%m-%dT%H)
    LAST_HOUR=$(grep "^$HOUR" "$LOG_FILE" | wc -l | tr -d ' ')
  fi

  echo ""
  echo "  $LABEL"
  echo "  Total:     $TOTAL"
  echo "  Today:     $TODAY"
  echo "  Last hour: $LAST_HOUR"
  echo ""
}

case "${1:-help}" in
  add)    cmd_add "$2" ;;
  revoke) cmd_revoke "$2" ;;
  rotate) cmd_rotate "$2" ;;
  list)   cmd_list ;;
  stats)  cmd_stats "$2" ;;
  *)
    echo ""
    echo "  rpc-keys — Manage API keys for the Intuition L3 RPC"
    echo ""
    echo "  Commands:"
    echo "    add <name>            Create a new API key"
    echo "    revoke <key|name>     Revoke an API key"
    echo "    rotate <key|name>     Revoke old key, create new one"
    echo "    list                  List all keys with usage stats"
    echo "    stats [key|name]      Show request stats"
    echo ""
    ;;
esac
