# Plan: API Key Auth on nginx gateway

## Principle

Keep nginx as the gateway (it works). Add API key auth without replacing it.

## How it works

### URL pattern (Alchemy-style)

```
https://domain/http/API_KEY   → proxied to nitro:8545
https://domain/ws/API_KEY     → proxied to nitro:8546
https://domain/               → dashboard (public, no key)
https://domain/api/status     → status API (public, no key)
```

### Three auth modes

1. **Open access** — no `API_KEY` env var, no keys file → everything passes through
2. **Single key** — `API_KEY=mysecret` env var → only `/http/mysecret` works
3. **Multi-key** — keys listed in `/data/keys.json` file → validated against the list

### nginx auth logic

Use nginx `map` + location regex to extract and validate the key from the URL path:

```nginx
# Extract key from /http/KEY or /ws/KEY
map $uri $api_key {
    ~^/http/(?<k>[^/]+)  $k;
    ~^/ws/(?<k>[^/]+)    $k;
    default              "";
}

# Validate key (generated from env var + keys.json)
map $api_key $key_valid {
    default 0;
    include /etc/nginx/keys.map;  # generated file: "key1" 1; "key2" 1; etc.
}

# If no keys configured at all, allow everything
# This is handled by the entrypoint: if no keys, keys.map contains `default 1;`
```

### Key management CLI

A shell script `/usr/local/bin/rpc-keys` baked into the gateway image:

```bash
rpc-keys add <name>       # generates key, adds to keys.json, regenerates keys.map, reloads nginx
rpc-keys list             # shows all keys from keys.json
rpc-keys revoke <key>     # removes from keys.json, regenerates keys.map, reloads nginx
rpc-keys rotate <key>     # revoke + add with same name
```

- `keys.json` stored on a persistent volume (`/data/keys.json`)
- CLI regenerates `/etc/nginx/keys.map` from `keys.json` + `API_KEY` env var
- CLI runs `nginx -s reload` after changes (zero downtime)

### Request counting

Skip SQLite for now. Use nginx access logs with the key in the log format:

```nginx
log_format rpc '$time_iso8601 $api_key $request_method $uri $status $request_time';
access_log /data/rpc.log rpc;
```

The CLI can parse logs for stats:

```bash
rpc-keys stats             # global: total, today, last hour
rpc-keys stats <key>       # per-key stats from log grep
```

## Files to change

1. **`gateway/nginx.conf`** — add map blocks, regex locations for `/http/KEY` and `/ws/KEY`, auth check
2. **`gateway/Dockerfile`** — keep nginx-based, add `rpc-keys` script + `jq` for JSON handling
3. **`gateway/rpc-keys.sh`** — CLI script for key management
4. **`gateway/entrypoint.sh`** — generates initial `keys.map` from env var on startup, then starts nginx
5. **`docker-compose.yaml`** — add `API_KEY` env var and persistent volume for gateway

## What stays the same

- nginx serves the dashboard (static files)
- nginx proxies `/api/status` to init:9000 (nc server, works fine with nginx)
- nginx proxies `/http` and `/ws` to nitro
- init container unchanged
- nitro container unchanged
- dashboard unchanged

## Flow

```
Request: GET /http/abc123/
         ↓
nginx extracts "abc123" from URI
         ↓
nginx checks keys.map: is "abc123" valid?
         ↓
  YES → proxy to nitro:8545 (strips /http/abc123 prefix)
  NO  → return 401 JSON error
```

## Open access flow

```
No API_KEY env var + no keys.json
         ↓
entrypoint.sh generates keys.map with: default 1;
         ↓
All requests to /http and /ws pass through (no key needed in URL)
/http works directly (no /http/KEY needed)
```
