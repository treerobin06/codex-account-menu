#!/usr/bin/env node
// Local model transport only. No npm dependencies, credential files or payload logging.
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

const HOST = '127.0.0.1';
const PRODUCTION_UPSTREAM_PORT = 4141;
const DEFAULT_PORT = 4142;
const MAX_ACTIVE = 64;
const IDLE_TIMEOUT_MS = 120_000;
const OBSERVATION_LIMIT = 100;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REQUEST_HEADERS = new Set(['accept', 'accept-encoding', 'content-type', 'content-encoding', 'content-length', 'openai-beta']);
const RESPONSE_HEADERS = new Set(['content-type', 'content-encoding', 'content-length', 'cache-control', 'retry-after', 'x-request-id']);
const RESPONSE_WS_HEADERS = new Set(['sec-websocket-accept', 'sec-websocket-protocol', 'sec-websocket-extensions']);

function optionsFrom(arguments_) {
  const options = { port: DEFAULT_PORT, enabled: false, testMode: false, testPort: null, controlSocket: null };
  for (let i = 0; i < arguments_.length; i += 1) {
    switch (arguments_[i]) {
      case '--port': options.port = Number(arguments_[++i]); break;
      case '--enabled': options.enabled = true; break;
      case '--control-socket': options.controlSocket = arguments_[++i]; break;
      case '--test-mode': options.testMode = true; break;
      case '--test-upstream-port': options.testPort = Number(arguments_[++i]); break;
      default: throw new Error('invalid_cli_arguments');
    }
  }
  if (!Number.isInteger(options.port) || options.port < 0 || options.port > 65535) throw new Error('invalid_port');
  if (options.testMode !== (options.testPort !== null)) throw new Error('explicit_test_mode_required');
  if (options.testMode && (!Number.isInteger(options.testPort) || options.testPort < 1 || options.testPort > 65535 || options.testPort === PRODUCTION_UPSTREAM_PORT)) {
    throw new Error('invalid_test_upstream_port');
  }
  if (options.controlSocket !== null && (typeof options.controlSocket !== 'string'
      || !path.isAbsolute(options.controlSocket) || path.resolve(options.controlSocket) !== options.controlSocket
      || /[\0\r\n]/.test(options.controlSocket) || Buffer.byteLength(options.controlSocket) > 100)) throw new Error('invalid_control_path');
  return options;
}

function prepareControlPath(filename) {
  if (!filename) return null;
  const parent = path.dirname(filename);
  const directories = [];
  for (let current = parent; current !== path.dirname(current); current = path.dirname(current)) directories.push(current);
  for (const directory of directories.reverse()) {
    let stat;
    try { stat = fs.lstatSync(directory); }
    catch (error) {
      if (error.code !== 'ENOENT') throw error;
      fs.mkdirSync(directory, { mode: 0o700 });
      stat = fs.lstatSync(directory);
    }
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('unsafe_control_directory');
  }
  const parentStat = fs.lstatSync(parent);
  if (parentStat.uid !== process.getuid() || (parentStat.mode & 0o777) !== 0o700) throw new Error('unsafe_control_directory');
  try { fs.lstatSync(filename); throw new Error('control_path_exists'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  return { parent, parentDev: parentStat.dev, parentIno: parentStat.ino, socketDev: null, socketIno: null };
}

function emit(event, fields = {}) {
  // Parent readers may disappear. Bound diagnostics; never buffer model content.
  if (process.stdout.destroyed || process.stdout.writableLength > 65_536) return;
  process.stdout.write(`${JSON.stringify({ event, ...fields })}\n`);
}

function hopHeaders(headers) {
  return new Set(String(headers.connection ?? '').toLowerCase().split(',').map(value => value.trim()));
}

function requestHeaders(request, upstreamPort, websocket) {
  const excluded = hopHeaders(request.headers);
  const headers = {};
  for (const name of REQUEST_HEADERS) {
    if (!excluded.has(name) && request.headers[name] !== undefined) headers[name] = request.headers[name];
  }
  // Construct these from constants; incoming OAuth, cookies, ChatGPT account IDs,
  // OpenAI organization/project and other unlisted headers never cross the relay.
  headers.authorization = 'Bearer local';
  headers.host = `${HOST}:${upstreamPort}`;
  headers['user-agent'] = 'codex-account-menu-api-relay/1';
  if (websocket) {
    delete headers['content-length'];
    headers.connection = 'Upgrade';
    headers.upgrade = 'websocket';
    headers['sec-websocket-key'] = request.headers['sec-websocket-key'];
    headers['sec-websocket-version'] = request.headers['sec-websocket-version'];
    // Subprotocols can carry API keys. Forward only this known non-secret token.
    if (request.headers['sec-websocket-protocol'] === 'responses') headers['sec-websocket-protocol'] = 'responses';
    // Compression is not negotiated by this initial relay. Frames/payload bytes
    // are passed unchanged; upstream receives no extension offer to accept.
  }
  return headers;
}

function responseHeaders(response, websocket = false) {
  const excluded = hopHeaders(response.headers);
  const headers = {};
  for (const [name, value] of Object.entries(response.headers)) {
    if (!excluded.has(name) && RESPONSE_HEADERS.has(name)) headers[name] = value;
    if (websocket && RESPONSE_WS_HEADERS.has(name)) headers[name] = value;
  }
  if (websocket) {
    headers.connection = 'Upgrade';
    headers.upgrade = 'websocket';
  }
  // No Location, Set-Cookie, Authorization or account/organization response headers.
  return headers;
}

function routeFor(request, websocket = false) {
  const raw = request.url ?? '';
  if (!raw.startsWith('/') || raw.startsWith('//') || raw.includes('#')) return null;
  const url = new URL(raw, `http://${HOST}`);
  const path = url.pathname;
  // Percent-encoded separators/dot segments are not part of supported endpoint IDs.
  if (raw.split('?', 1)[0] !== path || path.includes('%')) return null;
  let allowed = false;
  if (websocket) allowed = request.method === 'GET' && path === '/v1/responses';
  else if (path === '/v1/models') allowed = request.method === 'GET';
  else if (path === '/v1/responses' || path === '/v1/responses/compact') allowed = request.method === 'POST';
  else if (/^\/v1\/responses\/[A-Za-z0-9_-]{1,256}$/.test(path)) allowed = ['GET', 'DELETE'].includes(request.method);
  else if (/^\/v1\/responses\/[A-Za-z0-9_-]{1,256}\/cancel$/.test(path)) allowed = request.method === 'POST';
  else if (/^\/v1\/responses\/[A-Za-z0-9_-]{1,256}\/input_items$/.test(path)) allowed = request.method === 'GET';
  return allowed ? { path, target: path + url.search } : null;
}

function errorBody(code) {
  return Buffer.from(JSON.stringify({ error: { type: 'local_relay_error', code, message: code } }));
}

function httpError(response, status, code) {
  if (response.destroyed) return;
  if (response.headersSent) { response.destroy(); return; }
  const body = errorBody(code);
  response.writeHead(status, { 'content-type': 'application/json', 'content-length': body.length, connection: 'close' });
  response.end(body);
}

function writeSocketResponse(socket, status, headers) {
  const phrase = http.STATUS_CODES[status] ?? 'Upstream Response';
  const lines = [`HTTP/1.1 ${status} ${phrase}`];
  for (const [name, values] of Object.entries(headers)) {
    for (const value of Array.isArray(values) ? values : [values]) {
      if (value !== undefined && !/[\r\n]/.test(String(value))) lines.push(`${name}: ${value}`);
    }
  }
  socket.write(`${lines.join('\r\n')}\r\n\r\n`);
}

function socketError(socket, status, code) {
  if (socket.destroyed) return;
  const body = errorBody(code);
  writeSocketResponse(socket, status, { 'content-type': 'application/json', 'content-length': body.length, connection: 'close' });
  socket.end(body);
}

function main(options) {
  process.umask(0o077);
  const controlIdentity = prepareControlPath(options.controlSocket);
  const instanceId = randomUUID();
  const upstreamPort = options.testMode ? options.testPort : PRODUCTION_UPSTREAM_PORT;
  const httpOperations = new Set();
  const websocketOperations = new Set();
  const connections = new Set();
  const agent = new http.Agent({ keepAlive: false, maxSockets: MAX_ACTIVE, maxTotalSockets: MAX_ACTIVE });
  let enabled = options.enabled;
  let stopping = false;
  let shutdownRequested = false;
  let listenPort = options.port;
  let controlReady = !options.controlSocket;
  let httpReady = false;
  let readyEmitted = false;
  const controlConnections = new Set();
  const recentRequests = [];
  const state = (includeObservations = false) => ({ instanceId, protocolVersion: 1, pid: process.pid, host: HOST, port: listenPort,
    baseURL: `http://${HOST}:${listenPort}/v1`, controlSocket: options.controlSocket,
    testMode: options.testMode, upstreamPort,
    enabled, activeRequests: httpOperations.size, activeWebSockets: websocketOperations.size,
    ...(includeObservations ? { observationVersion: 1, observationLimit: OBSERVATION_LIMIT, recentRequests } : {}) });
  const busy = () => httpOperations.size + websocketOperations.size > 0;
  // This is a native runtime transport, not a browser-facing endpoint. Browsers
  // send Origin on WebSocket handshakes (RFC 6455); reject it rather than turn
  // a visited web page into a caller of the user's fixed Copilot credentials.
  const nativeLoopbackRequest = request => request.headers.origin === undefined
    && request.headers.host === `${HOST}:${listenPort}`;

  function register(collection, request, route) {
    const requestId = randomUUID();
    const started = performance.now();
    const websocket = collection === websocketOperations;
    const isModelTransport = websocket || (request.method === 'POST'
      && ['/v1/responses', '/v1/responses/compact'].includes(route.path));
    const identifier = name => typeof request.headers[name] === 'string' && UUID_PATTERN.test(request.headers[name])
      ? request.headers[name].toLowerCase() : null;
    // Current native requests carry separate thread-id and session-id headers.
    // A session can span a fork family: never substitute it for a missing thread.
    // Read only these UUIDs before the existing upstream allowlist strips them.
    const now = new Date().toISOString();
    const observation = isModelTransport ? { id: requestId, startedAt: now, updatedAt: now,
      threadID: identifier('thread-id'), sessionID: identifier('session-id'),
      transport: websocket ? 'websocket' : 'http', phase: 'forwarding', statusCode: null, route: 'copilot' } : null;
    if (observation) {
      recentRequests.unshift(observation);
      if (recentRequests.length > OBSERVATION_LIMIT) recentRequests.pop();
    }
    const operation = { upstream: null, upstreamSocket: null, destroy: () => {}, ended: false,
      observe(phase, statusCode = observation?.statusCode ?? null) {
        if (!observation || operation.ended) return;
        observation.phase = phase;
        observation.statusCode = statusCode;
        observation.updatedAt = new Date().toISOString();
      },
      finish(statusCode, outcome) {
        if (operation.ended) return;
        // These are transport events only. Payloads and WS frames remain opaque;
        // HTTP 200/EOF or WS 101 can never prove a completed model turn.
        if (websocket) {
          if (observation?.phase === 'websocket_open') operation.observe('websocket_closed');
          else if (observation?.phase === 'forwarding') operation.observe('transport_error');
        } else if (observation?.phase !== 'transport_error') {
          operation.observe(outcome === 'completed' ? 'http_finished' : 'http_closed');
        }
        operation.ended = true;
        collection.delete(operation);
        emit('request', { requestId, method: request.method, path: route.path, statusCode,
          outcome, durationMs: Math.round(performance.now() - started) });
      } };
    collection.add(operation);
    return operation;
  }

  const server = http.createServer({ maxHeaderSize: 32_768 }, (request, response) => {
    if (!nativeLoopbackRequest(request)) { request.resume(); httpError(response, 403, 'native_loopback_client_required'); return; }
    if (request.method === 'GET' && request.url === '/healthz') {
      const body = JSON.stringify({ ok: true, status: enabled ? 'enabled' : 'disabled', ...state() });
      response.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body), 'cache-control': 'no-store' });
      response.end(body);
      return;
    }
    const route = routeFor(request);
    if (!route) { request.resume(); httpError(response, 404, 'route_not_allowed'); return; }
    if (!enabled || stopping || shutdownRequested) { request.resume(); httpError(response, 503, 'relay_disabled'); return; }
    if (httpOperations.size + websocketOperations.size >= MAX_ACTIVE) { request.resume(); httpError(response, 503, 'relay_busy'); return; }
    const operation = register(httpOperations, request, route);
    const upstream = http.request({ host: HOST, port: upstreamPort, method: request.method, path: route.target,
      headers: requestHeaders(request, upstreamPort, false), agent, timeout: IDLE_TIMEOUT_MS });
    operation.upstream = upstream;
    operation.destroy = () => { upstream.destroy(); response.destroy(); request.destroy(); };
    request.on('aborted', () => { upstream.destroy(); operation.finish(499, 'client_aborted'); });
    request.on('error', () => { upstream.destroy(); response.destroy(); });
    response.on('close', () => { if (!response.writableFinished) upstream.destroy(); operation.finish(response.statusCode, 'closed'); });
    response.on('finish', () => operation.finish(response.statusCode, 'completed'));
    upstream.on('timeout', () => upstream.destroy(new Error('upstream_timeout')));
    upstream.on('error', () => { operation.observe('transport_error', 502); httpError(response, 502, 'upstream_unavailable'); });
    upstream.on('upgrade', (_response, socket) => { operation.observe('transport_error', 502); socket.destroy(); httpError(response, 502, 'unexpected_upgrade'); });
    upstream.on('response', result => {
      if (result.statusCode >= 300 && result.statusCode < 400) {
        operation.observe('transport_error', 502);
        result.resume(); httpError(response, 502, 'upstream_redirect_rejected'); return;
      }
      operation.observe('http_response', result.statusCode ?? null);
      response.writeHead(result.statusCode ?? 502, responseHeaders(result));
      result.on('error', () => response.destroy());
      result.on('aborted', () => response.destroy());
      result.pipe(response);
    });
    request.pipe(upstream);
  });

  server.on('upgrade', (request, socket, head) => {
    socket.on('error', () => {});
    if (!nativeLoopbackRequest(request)) { socketError(socket, 403, 'native_loopback_client_required'); return; }
    const route = routeFor(request, true);
    if (!route || String(request.headers.upgrade).toLowerCase() !== 'websocket'
        || typeof request.headers['sec-websocket-key'] !== 'string' || request.headers['sec-websocket-version'] !== '13') {
      socketError(socket, 400, 'websocket_route_not_allowed'); return;
    }
    if (!enabled || stopping || shutdownRequested) { socketError(socket, 503, 'relay_disabled'); return; }
    if (httpOperations.size + websocketOperations.size >= MAX_ACTIVE) { socketError(socket, 503, 'relay_busy'); return; }
    const operation = register(websocketOperations, request, route);
    const upstream = http.request({ host: HOST, port: upstreamPort, method: 'GET', path: route.target,
      headers: requestHeaders(request, upstreamPort, true), agent: false, timeout: IDLE_TIMEOUT_MS });
    operation.upstream = upstream;
    let upgraded = false;
    operation.destroy = () => { upstream.destroy(); operation.upstreamSocket?.destroy(); socket.destroy(); };
    // HTTP-upgrade sockets allow half-open TCP connections. A client EOF ends
    // this WebSocket tunnel even if the upstream leaves its other half open.
    socket.on('end', () => operation.destroy());
    socket.on('close', () => { upstream.destroy(); operation.upstreamSocket?.destroy(); operation.finish(upgraded ? 101 : 502, 'closed'); });
    upstream.on('timeout', () => upstream.destroy(new Error('upstream_timeout')));
    upstream.on('error', () => { operation.observe('transport_error', upgraded ? 101 : 502); if (upgraded) socket.destroy(); else socketError(socket, 502, 'upstream_unavailable'); });
    upstream.on('response', result => {
      if (result.statusCode >= 300 && result.statusCode < 400) {
        operation.observe('transport_error', 502);
        result.resume(); socketError(socket, 502, 'upstream_redirect_rejected'); return;
      }
      operation.observe('websocket_rejected', result.statusCode ?? null);
      const headers = responseHeaders(result);
      // IncomingMessage removes transfer framing; finish this rejection by EOF.
      delete headers['content-length'];
      headers.connection = 'close';
      writeSocketResponse(socket, result.statusCode ?? 502, headers);
      result.on('error', () => socket.destroy());
      result.pipe(socket);
    });
    upstream.on('upgrade', (result, upstreamSocket, upstreamHead) => {
      if (result.statusCode !== 101) { operation.observe('transport_error', 502); upstreamSocket.destroy(); socketError(socket, 502, 'invalid_upgrade'); return; }
      upgraded = true;
      operation.observe('websocket_open', 101);
      operation.upstreamSocket = upstreamSocket;
      upstreamSocket.on('error', () => socket.destroy());
      upstreamSocket.on('end', () => socket.end(() => socket.destroy()));
      upstreamSocket.on('close', () => { if (!upstreamSocket.readableEnded) socket.destroy(); });
      writeSocketResponse(socket, 101, responseHeaders(result, true));
      if (upstreamHead.length) socket.write(upstreamHead);
      if (head.length) upstreamSocket.write(head);
      socket.pipe(upstreamSocket);
      upstreamSocket.pipe(socket);
    });
    upstream.end();
  });

  server.maxConnections = 128;
  server.headersTimeout = 10_000;
  server.requestTimeout = 30_000;
  server.keepAliveTimeout = 5_000;
  server.on('connection', socket => {
    connections.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => connections.delete(socket));
  });
  server.on('clientError', (_error, socket) => socketError(socket, 400, 'invalid_http_request'));
  server.on('error', () => { emit('fatal', { ok: false, status: 'listener_unavailable' }); forceStop(1); });

  function cleanupControlPath() {
    if (!controlIdentity || controlIdentity.socketIno === null) return;
    try {
      const parent = fs.lstatSync(controlIdentity.parent);
      const socket = fs.lstatSync(options.controlSocket);
      if (!parent.isSymbolicLink() && parent.isDirectory() && parent.dev === controlIdentity.parentDev
          && parent.ino === controlIdentity.parentIno && socket.isSocket() && !socket.isSymbolicLink()
          && socket.dev === controlIdentity.socketDev && socket.ino === controlIdentity.socketIno) fs.unlinkSync(options.controlSocket);
    } catch { /* A removed or replaced path is never blindly deleted. */ }
  }

  function forceStop(exitCode) {
    if (stopping) return;
    stopping = true;
    shutdownRequested = true;
    enabled = false;
    for (const operation of [...httpOperations, ...websocketOperations]) operation.destroy();
    for (const socket of connections) socket.destroy();
    for (const socket of controlConnections) socket.destroy();
    agent.destroy();
    cleanupControlPath();
    // Do not call the Unix server's close(): libuv unlinks its original pathname
    // without checking inode identity. The OS closes that listener at process
    // exit; only the verified socket path above is explicitly unlinked.
    server.close(() => process.exit(exitCode));
    setTimeout(() => process.exit(exitCode), 500).unref();
  }

  function control(command) {
    const op = command?.op;
    const id = command?.id ?? null;
    if ((id !== null && (typeof id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)))
        || !['enable', 'disable', 'status', 'shutdown'].includes(op)) return { event: 'control', id: null, ok: false, status: 'invalid_command', ...state() };
    if (stopping || shutdownRequested) return { event: 'control', id, op, ok: false, status: 'shutting_down', ...state(op === 'status') };
    if (!httpReady || !controlReady) return { event: 'control', id, op, ok: false, status: 'starting', ...state(op === 'status') };
    if ((op === 'disable' || op === 'shutdown') && busy()) return { event: 'control', id, op, ok: false, status: 'busy', ...state() };
    // Check and mutation are synchronous on this single event loop.
    if (op === 'enable') enabled = true;
    if (op === 'disable' || op === 'shutdown') enabled = false;
    if (op === 'shutdown') shutdownRequested = true;
    return { event: 'control', id, op, ok: true, status: shutdownRequested ? 'shutting_down' : (enabled ? 'enabled' : 'disabled'), ...state(op === 'status') };
  }

  function replyControl(line, send) {
    let command;
    try { command = JSON.parse(line); } catch { command = null; }
    const response = control(command);
    const shutdown = response.ok && response.op === 'shutdown';
    send(`${JSON.stringify(response)}\n`, () => { if (shutdown) forceStop(0); });
    // A vanished requester cannot keep an already-approved shutdown alive.
    if (shutdown) setTimeout(() => forceStop(0), 200).unref();
  }

  function maybeReady() {
    if (readyEmitted || !httpReady || !controlReady || stopping) return;
    readyEmitted = true;
    emit('ready', { ok: true, status: enabled ? 'enabled' : 'disabled', ...state() });
  }

  if (options.controlSocket) {
    const controlServer = net.createServer(socket => {
      controlConnections.add(socket);
      socket.on('close', () => controlConnections.delete(socket));
      socket.on('error', () => {});
      socket.setEncoding('utf8');
      socket.setTimeout(5_000, () => socket.destroy());
      let buffer = '';
      let replied = false;
      socket.on('data', chunk => {
        if (replied) return;
        buffer += chunk;
        if (Buffer.byteLength(buffer) > 4096) { replied = true; replyControl('', (line, callback) => socket.end(line, callback)); return; }
        const newline = buffer.indexOf('\n');
        if (newline < 0) return;
        replied = true;
        replyControl(buffer.slice(0, newline), (line, callback) => socket.end(line, callback));
      });
    });
    controlServer.on('error', () => { emit('fatal', { ok: false, status: 'control_listener_unavailable' }); forceStop(1); });
    controlServer.listen(options.controlSocket, () => {
      try {
        const stat = fs.lstatSync(options.controlSocket);
        if (!stat.isSocket() || stat.uid !== process.getuid()) throw new Error('unsafe_control_socket');
        controlIdentity.socketDev = stat.dev;
        controlIdentity.socketIno = stat.ino;
        fs.chmodSync(options.controlSocket, 0o600);
        controlReady = true;
        maybeReady();
      } catch { emit('fatal', { ok: false, status: 'unsafe_control_socket' }); forceStop(1); }
    });
  }

  let controlBuffer = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    controlBuffer += chunk;
    if (Buffer.byteLength(controlBuffer) > 4096) { emit('fatal', { ok: false, status: 'invalid_control_input' }); forceStop(2); return; }
    let newline;
    while ((newline = controlBuffer.indexOf('\n')) >= 0) {
      const line = controlBuffer.slice(0, newline);
      controlBuffer = controlBuffer.slice(newline + 1);
      replyControl(line, (response, callback) => process.stdout.write(response, callback));
    }
  });
  process.stdin.on('end', () => { if (!options.controlSocket) forceStop(0); });
  process.stdin.on('error', () => { if (!options.controlSocket) forceStop(1); });
  process.stdout.on('error', () => { if (!options.controlSocket) forceStop(1); });
  process.on('SIGTERM', () => forceStop(0));
  process.on('SIGINT', () => forceStop(0));
  process.on('uncaughtException', () => { emit('fatal', { ok: false, status: 'internal_error' }); forceStop(1); });
  process.on('unhandledRejection', () => { emit('fatal', { ok: false, status: 'internal_error' }); forceStop(1); });
  server.listen({ host: HOST, port: options.port, exclusive: true }, () => {
    listenPort = server.address().port;
    httpReady = true;
    maybeReady();
  });
}

try { main(optionsFrom(process.argv.slice(2))); }
catch (error) {
  const known = new Set(['invalid_control_path', 'unsafe_control_directory', 'control_path_exists']);
  emit('fatal', { ok: false, status: known.has(error.message) ? error.message : 'invalid_cli_arguments' });
  process.exitCode = 2;
}
