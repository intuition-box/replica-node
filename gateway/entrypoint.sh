#!/bin/sh
set -e

KEYS_FILE="${KEYS_FILE:-/data/keys.json}"
KEYS_MAP="/etc/nginx/keys.map"

mkdir -p /data

# Ensure keys.json exists
if [ ! -f "$KEYS_FILE" ]; then
  echo '[]' > "$KEYS_FILE"
fi

# Generate initial keys.map
echo "# Auto-generated - do not edit" > "$KEYS_MAP"

KEY_COUNT=0

# Add API_KEY env var if set
if [ -n "$API_KEY" ]; then
  echo "\"$API_KEY\" 1;" >> "$KEYS_MAP"
  KEY_COUNT=$((KEY_COUNT + 1))
fi

# Add keys from keys.json
if [ -f "$KEYS_FILE" ]; then
  ACTIVE=$(jq -r '.[] | select(.revoked != true) | .key' "$KEYS_FILE" 2>/dev/null || true)
  for k in $ACTIVE; do
    echo "\"$k\" 1;" >> "$KEYS_MAP"
    KEY_COUNT=$((KEY_COUNT + 1))
  done
fi

# If no keys configured, allow everything
if [ "$KEY_COUNT" -eq 0 ]; then
  echo '# No keys configured - open access' > "$KEYS_MAP"
  echo '"" 1;' >> "$KEYS_MAP"
  echo 'default 1;' >> "$KEYS_MAP"
fi

echo "Auth mode: $([ $KEY_COUNT -gt 0 ] && echo "$KEY_COUNT key(s) configured" || echo "open access")"

# Start nginx
exec nginx -g 'daemon off;'
