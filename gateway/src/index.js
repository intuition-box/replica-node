import { createServer } from 'http';
import httpProxy from 'http-proxy';
import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { isValidKey, hasAnyKeys, logRequest } from './db.js';

const { createProxyServer } = httpProxy;

const PORT = parseInt(process.env.PORT || '80');
const NITRO_HTTP = process.env.NITRO_HTTP || 'http://nitro:8545';
const NITRO_WS = process.env.NITRO_WS || 'http://nitro:8546';
const INIT_STATUS = process.env.INIT_STATUS || 'http://init:9000';
const API_KEY = process.env.API_KEY || '';
const STATIC_DIR = process.env.STATIC_DIR || '/app/public';

const proxy = createProxyServer({ ws: true, changeOrigin: true });
proxy.on('error', (err, req, res) => {
  if (res.writeHead) {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'upstream unavailable' }));
  }
});

function getMimeType(path) {
  if (path.endsWith('.html')) return 'text/html';
  if (path.endsWith('.js')) return 'application/javascript';
  if (path.endsWith('.css')) return 'text/css';
  if (path.endsWith('.json')) return 'application/json';
  if (path.endsWith('.svg')) return 'image/svg+xml';
  if (path.endsWith('.png')) return 'image/png';
  if (path.endsWith('.ico')) return 'image/x-icon';
  return 'application/octet-stream';
}

function serveStatic(req, res) {
  let filePath = req.url === '/' ? '/index.html' : req.url;
  filePath = filePath.split('?')[0];
  const fullPath = join(STATIC_DIR, filePath);

  if (existsSync(fullPath)) {
    const content = readFileSync(fullPath);
    res.writeHead(200, { 'Content-Type': getMimeType(fullPath) });
    res.end(content);
  } else {
    // SPA fallback
    const indexPath = join(STATIC_DIR, 'index.html');
    if (existsSync(indexPath)) {
      const content = readFileSync(indexPath);
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(content);
    } else {
      res.writeHead(404);
      res.end('Not found');
    }
  }
}

// Auth check: returns the extracted key or null if unauthorized
function checkAuth(pathname) {
  // Extract key from path: /http/KEY or /ws/KEY
  const parts = pathname.split('/').filter(Boolean);
  if (parts.length < 2) return { key: null, authorized: false };

  const key = parts[1];

  // If API_KEY env is set, check against it
  if (API_KEY && key === API_KEY) return { key, authorized: true };

  // If SQLite has keys, check against them
  if (hasAnyKeys() && isValidKey(key)) return { key, authorized: true };

  // If neither API_KEY nor SQLite keys exist, open access (no key needed)
  if (!API_KEY && !hasAnyKeys()) return { key: 'anonymous', authorized: true };

  return { key, authorized: false };
}

// Check if auth is required (API_KEY set or SQLite has keys)
function authRequired() {
  return !!(API_KEY || hasAnyKeys());
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const pathname = url.pathname;
  const start = performance.now();

  // Dashboard - always public
  if (!pathname.startsWith('/http') && !pathname.startsWith('/ws') && !pathname.startsWith('/api/')) {
    return serveStatic(req, res);
  }

  // Status API - always public, fetch directly (nc server is flaky with proxying)
  if (pathname === '/api/status') {
    try {
      const statusRes = await fetch(`${INIT_STATUS}/api/status`);
      const body = await statusRes.text();
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache', 'Access-Control-Allow-Origin': '*' });
      res.end(body);
    } catch {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ phase: 'starting', message: 'Status unavailable' }));
    }
    return;
  }

  // RPC endpoints: /http or /http/KEY
  if (pathname.startsWith('/http')) {
    if (authRequired()) {
      const { key, authorized } = checkAuth(pathname);
      if (!authorized) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid or missing API key' }));
        return;
      }
      res.on('finish', () => {
        logRequest(key, req.method, '/http', res.statusCode, Math.round(performance.now() - start));
      });
    } else {
      res.on('finish', () => {
        logRequest('anonymous', req.method, '/http', res.statusCode, Math.round(performance.now() - start));
      });
    }
    return proxy.web(req, res, { target: NITRO_HTTP, ignorePath: true });
  }

  // WS over HTTP
  if (pathname.startsWith('/ws')) {
    if (authRequired()) {
      const { key, authorized } = checkAuth(pathname);
      if (!authorized) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid or missing API key' }));
        return;
      }
      res.on('finish', () => {
        logRequest(key, req.method, '/ws', res.statusCode, Math.round(performance.now() - start));
      });
    }
    return proxy.web(req, res, { target: NITRO_WS, ignorePath: true });
  }

  res.writeHead(404);
  res.end('Not found');
});

// WebSocket upgrade
server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const pathname = url.pathname;

  if (pathname.startsWith('/ws')) {
    if (authRequired()) {
      const { authorized } = checkAuth(pathname);
      if (!authorized) {
        socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
        socket.destroy();
        return;
      }
    }
    proxy.ws(req, socket, head, { target: NITRO_WS, ignorePath: true });
  } else {
    socket.destroy();
  }
});

server.listen(PORT, () => {
  console.log(`Gateway listening on port ${PORT}`);
  console.log(`Auth mode: ${API_KEY ? 'single key (API_KEY)' : hasAnyKeys() ? 'multi-key (SQLite)' : 'open (no auth)'}`);
});
