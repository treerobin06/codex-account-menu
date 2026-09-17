import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const NODE = '/opt/homebrew/bin/node';
const HELPER = fileURLToPath(new URL('../../Sources/SwitcherCore/Resources/codex-api-relay.mjs', import.meta.url));
const HOST = '127.0.0.1';
const TEST_OPTIONS = { timeout: 10_000 };
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const THREAD_A = '01a0ab7a-a500-7b63-80d1-1a9c16b3a64c';
const THREAD_B = '01a0ab7a-a51c-7d03-a73d-0613f7d3e642';
const SESSION = '01a0ab7a-a600-7a11-82d2-1a9c16b3a64c';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function bounded(promise, label, milliseconds = 2500) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}

async function upstreamFixture(t, handler, upgrade) {
  const sockets = new Set();
  const server = http.createServer(handler);
  server.on('connection', socket => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
  });
  if (upgrade) server.on('upgrade', upgrade);
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, HOST, resolve);
  });
  const port = server.address().port;
  assert.notEqual(port, 4141, 'Tests must never use the production upstream');
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    if (server.listening) await bounded(new Promise(resolve => server.close(resolve)), 'close fixture');
  });
  return { server, port };
}

async function relayFixture(t, upstreamPort) {
  assert(Number.isInteger(upstreamPort) && upstreamPort > 0 && upstreamPort !== 4141);
  const child = spawn(NODE, [HELPER, '--port', '0', '--enabled', '--test-mode', '--test-upstream-port', String(upstreamPort)],
    { stdio: ['pipe', 'pipe', 'pipe'] });
  const events = [];
  let output = '', errorOutput = '', pending = '';
  const exit = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', (code, signal) => resolve({ code, signal }));
  });
  child.stdin.on('error', () => {});
  child.stdout.on('data', bytes => {
    output += bytes.toString();
    pending += bytes.toString();
    let newline;
    while ((newline = pending.indexOf('\n')) >= 0) {
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      if (line) events.push(JSON.parse(line));
    }
  });
  child.stderr.on('data', bytes => { errorOutput += bytes.toString(); });
  async function event(predicate, start = 0) {
    return bounded((async () => {
      for (;;) {
        const found = events.slice(start).find(predicate);
        if (found) return found;
        if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Helper exited before expected event: ${errorOutput}`);
        await delay(5);
      }
    })(), 'relay event');
  }
  async function control(op) {
    const start = events.length;
    child.stdin.write(JSON.stringify({ op }) + '\n');
    return event(value => value.event === 'control' && value.op === op, start);
  }
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.stdin.end();
    try { await bounded(exit, 'helper cleanup'); }
    catch { child.kill('SIGKILL'); await bounded(exit, 'owned helper forced cleanup'); }
  });
  const ready = await event(value => value.event === 'ready');
  assert.equal(ready.host, HOST);
  assert(ready.port > 0 && ready.port !== 4141);
  assert.match(ready.instanceId, /^[a-z0-9-]{36}$/i);
  assert.equal(ready.enabled, true);
  assert.equal(ready.activeRequests, 0);
  assert.equal(ready.activeWebSockets, 0);
  return { child, ready, control, exit, events, output: () => output + errorOutput };
}

async function waitIdle(relay) {
  return bounded((async () => {
    for (;;) {
      const state = await relay.control('status');
      if (state.activeRequests === 0 && state.activeWebSockets === 0) return state;
      await delay(10);
    }
  })(), 'relay idle');
}

function request(port, { method = 'GET', path = '/v1/models', headers = {}, body, onChunk } = {}) {
  return bounded(new Promise((resolve, reject) => {
    const req = http.request({ host: HOST, port, method, path, headers, agent: false }, response => {
      const chunks = [];
      response.on('data', chunk => { chunks.push(chunk); onChunk?.(chunk); });
      response.once('error', reject);
      response.once('aborted', () => reject(new Error('Response aborted')));
      response.once('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }));
    });
    req.once('error', reject);
    req.setTimeout(2000, () => req.destroy(new Error('Request timed out')));
    req.end(body);
  }), 'HTTP response');
}

async function collect(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks);
}

function assertSanitized(headers, upstreamPort) {
  assert.equal(headers.authorization, 'Bearer local');
  assert.equal(headers.host, `${HOST}:${upstreamPort}`);
  for (const name of ['cookie', 'chatgpt-account-id', 'openai-organization', 'openai-project', 'x-api-key', 'proxy-authorization']) {
    assert.equal(headers[name], undefined, `${name} must be stripped`);
  }
}

function secretHeaders() {
  return { authorization: 'Bearer synthetic-official-secret', cookie: 'session=synthetic-cookie-secret',
    'chatgpt-account-id': 'synthetic-account-secret', 'openai-organization': 'synthetic-org-secret',
    'openai-project': 'synthetic-project-secret', 'x-api-key': 'synthetic-api-secret',
    'proxy-authorization': 'Basic synthetic-proxy-secret' };
}

class SocketReader {
  constructor(socket) {
    this.buffer = Buffer.alloc(0);
    this.closed = false;
    socket.on('data', bytes => { this.buffer = Buffer.concat([this.buffer, bytes]); });
    socket.on('error', () => {});
    socket.on('close', () => { this.closed = true; });
  }
  async takeUntil(predicate, label) {
    return bounded((async () => {
      for (;;) {
        const count = predicate(this.buffer);
        if (count >= 0) {
          const value = this.buffer.subarray(0, count);
          this.buffer = this.buffer.subarray(count);
          return value;
        }
        if (this.closed) throw new Error(`Socket closed: ${label}`);
        await delay(5);
      }
    })(), label);
  }
  header() { return this.takeUntil(bytes => { const end = bytes.indexOf('\r\n\r\n'); return end < 0 ? -1 : end + 4; }, 'WS handshake'); }
  bytes(count) { return this.takeUntil(bytes => bytes.length >= count ? count : -1, 'WS frame'); }
}

function maskedFrame(text) {
  const payload = Buffer.from(text), mask = Buffer.from([11, 22, 33, 44]);
  assert(payload.length < 126);
  return Buffer.concat([Buffer.from([0x81, 0x80 | payload.length]), mask,
    Buffer.from(payload.map((value, index) => value ^ mask[index % 4]))]);
}

function serverFrame(text) {
  const payload = Buffer.from(text);
  return Buffer.concat([Buffer.from([0x81, payload.length]), payload]);
}

async function websocket(t, port, { path = '/v1/responses', protocol = 'responses', head = Buffer.alloc(0), extraHeaders = {} } = {}) {
  const socket = net.connect({ host: HOST, port });
  const reader = new SocketReader(socket);
  t.after(() => socket.destroy());
  await bounded(new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject); }), 'WS connect');
  const headers = { Host: `${HOST}:${port}`, Connection: 'Upgrade', Upgrade: 'websocket',
    'Sec-WebSocket-Key': Buffer.from('fixture-ws-key!!').toString('base64'), 'Sec-WebSocket-Version': '13',
    'Sec-WebSocket-Protocol': protocol, 'Sec-WebSocket-Extensions': 'permessage-deflate', ...secretHeaders(), ...extraHeaders };
  const message = `GET ${path} HTTP/1.1\r\n${Object.entries(headers).map(([key, value]) => `${key}: ${value}`).join('\r\n')}\r\n\r\n`;
  socket.write(Buffer.concat([Buffer.from(message), head]));
  const header = (await reader.header()).toString();
    return { socket, reader, header };
}

test('browser origins and foreign Host values cannot spend through the local model relay', TEST_OPTIONS, async t => {
  let hits = 0;
  const upstream = await upstreamFixture(t, async (req, res) => { hits += 1; await collect(req); res.end('native-ok'); },
    (_request, socket) => { hits += 1; socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); });
  const relay = await relayFixture(t, upstream.port);
  for (const origin of ['https://untrusted.example', 'null', `http://${HOST}:${relay.ready.port}`]) {
    const result = await request(relay.ready.port, { method: 'POST', path: '/v1/responses',
      headers: { origin, 'content-type': 'text/plain' }, body: '{"model":"fixture"}' });
    assert.equal(result.status, 403);
    const ws = await websocket(t, relay.ready.port, { extraHeaders: { Origin: origin } });
    assert.match(ws.header, /^HTTP\/1\.1 403 /);
    ws.socket.destroy();
  }
  assert.equal((await request(relay.ready.port, { headers: { Host: 'untrusted.example' } })).status, 403);
  const foreignWS = await websocket(t, relay.ready.port, { extraHeaders: { Host: 'untrusted.example' } });
  assert.match(foreignWS.header, /^HTTP\/1\.1 403 /);
  foreignWS.socket.destroy();
  assert.equal(hits, 0);
  assert.equal((await request(relay.ready.port)).status, 200);
  assert.equal(hits, 1);
});

test('HTTP streams SSE immediately, strips identity headers, and refuses busy controls', TEST_OPTIONS, async t => {
  const received = deferred(), finish = deferred(), firstChunk = deferred();
  const prompt = 'synthetic-prompt-must-not-be-logged';
  const payload = Buffer.from(JSON.stringify({ input: prompt }));
  const first = Buffer.from('event: response.created\ndata: {"id":"fixture"}\n\n');
  const last = Buffer.from('data: [DONE]\n\n');
  const upstream = await upstreamFixture(t, async (req, res) => {
    const body = await collect(req);
    received.resolve({ headers: req.headers, body, path: req.url });
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', 'set-cookie': 'server-secret=1' });
    res.write(first);
    await finish.promise;
    res.end(last);
  });
  const relay = await relayFixture(t, upstream.port);
  const response = request(relay.ready.port, { method: 'POST', path: '/v1/responses?private=synthetic-query-secret',
    headers: { ...secretHeaders(), 'content-type': 'application/json', 'openai-beta': 'responses=experimental', 'content-length': payload.length },
    body: payload, onChunk: firstChunk.resolve });
  response.catch(() => {});
  t.after(() => finish.resolve());
  assert.deepEqual(await bounded(firstChunk.promise, 'first streamed chunk'), first);
  const incoming = await received.promise;
  assertSanitized(incoming.headers, upstream.port);
  assert.equal(incoming.headers['openai-beta'], 'responses=experimental');
  assert.deepEqual(incoming.body, payload);
  for (const op of ['disable', 'shutdown']) {
    const state = await relay.control(op);
    assert.equal(state.ok, false); assert.equal(state.status, 'busy');
    assert.equal(state.enabled, true); assert.equal(state.activeRequests, 1);
  }
  finish.resolve();
  const result = await response;
  assert.deepEqual(result.body, Buffer.concat([first, last]));
  assert.equal(result.headers['set-cookie'], undefined);
  await waitIdle(relay);
  for (const secret of [prompt, 'synthetic-official-secret', 'synthetic-query-secret', 'synthetic-cookie-secret']) {
    assert(!relay.output().includes(secret));
  }
});

test('Content-Encoding request and response payloads remain opaque bytes', TEST_OPTIONS, async t => {
  const requestBytes = gzipSync(Buffer.from('{"input":"synthetic-compressed-prompt"}'));
  const responseBytes = gzipSync(Buffer.from('{"output":"synthetic-compressed-result"}'));
  const received = deferred();
  const upstream = await upstreamFixture(t, async (req, res) => {
    received.resolve({ body: await collect(req), headers: req.headers });
    res.writeHead(200, { 'content-type': 'application/json', 'content-encoding': 'gzip', 'content-length': responseBytes.length });
    res.end(responseBytes);
  });
  const relay = await relayFixture(t, upstream.port);
  const response = await request(relay.ready.port, { method: 'POST', path: '/v1/responses', body: requestBytes,
    headers: { 'content-type': 'application/json', 'content-encoding': 'gzip', 'content-length': requestBytes.length } });
  const incoming = await received.promise;
  assert.deepEqual(incoming.body, requestBytes);
  assert.equal(incoming.headers['content-encoding'], 'gzip');
  assert.deepEqual(response.body, responseBytes);
  assert.equal(response.headers['content-encoding'], 'gzip');
  assert(!relay.output().includes('synthetic-compressed-prompt'));
});

test('upstream 401/429/5xx are preserved; redirects never reach another destination', TEST_OPTIONS, async t => {
  let alternateHits = 0, hits = 0;
  const alternate = await upstreamFixture(t, (_req, res) => { alternateHits += 1; res.end('must not be reached'); });
  const upstream = await upstreamFixture(t, async (req, res) => {
    hits += 1; await collect(req);
    const status = Number(new URL(req.url, 'http://fixture').searchParams.get('status'));
    res.writeHead(status, { 'content-type': 'application/json', 'retry-after': '7',
      location: `http://${HOST}:${alternate.port}/v1/responses`, 'set-cookie': 'server-private=1' });
    res.end(`status-${status}`);
  });
  const relay = await relayFixture(t, upstream.port);
  for (const status of [401, 429, 500, 503, 302]) {
    const result = await request(relay.ready.port, { method: 'POST', path: `/v1/responses?status=${status}`, body: '{}' });
    assert.equal(result.status, status === 302 ? 502 : status);
    assert.equal(result.headers.location, undefined);
    assert.equal(result.headers['set-cookie'], undefined);
    if (status === 302) assert.equal(JSON.parse(result.body).error.code, 'upstream_redirect_rejected');
    else { assert.equal(result.body.toString(), `status-${status}`); assert.equal(result.headers['retry-after'], '7'); }
    const observed = (await waitIdle(relay)).recentRequests[0];
    assert.equal(observed.statusCode, result.status);
    assert.equal(observed.phase, status === 302 ? 'transport_error' : 'http_finished');
  }
  assert.equal(hits, 5); assert.equal(alternateHits, 0);
});

test('disabled relay and unsupported paths never forward; explicit Responses paths do', TEST_OPTIONS, async t => {
  let hits = 0;
  const upstream = await upstreamFixture(t, async (req, res) => { hits += 1; await collect(req); res.end('fixture-ok'); });
  const relay = await relayFixture(t, upstream.port);
  assert.equal((await relay.control('disable')).ok, true);
  assert.equal((await request(relay.ready.port)).status, 503);
  const disabledWS = await websocket(t, relay.ready.port);
  assert.match(disabledWS.header, /^HTTP\/1\.1 503 /);
  disabledWS.socket.destroy();
  assert.equal(hits, 0);
  assert.equal((await relay.control('enable')).ok, true);
  for (const [method, path] of [['POST', '/v1/models'], ['GET', '/v1/responses'], ['POST', '/v1/chat/completions'],
    ['GET', '/admin'], ['GET', '//v1/models'], ['GET', '/v1/%6dodels'], ['GET', '/v1/../v1/models'],
    ['POST', '/v1/responses/id/arbitrary'], ['GET', `http://${HOST}:${upstream.port}/v1/models`]]) {
    assert.equal((await request(relay.ready.port, { method, path })).status, 404, `${method} ${path}`);
  }
  assert.equal(hits, 0);
  for (const [method, path] of [['GET', '/v1/models'], ['POST', '/v1/responses'], ['POST', '/v1/responses/compact'],
    ['GET', '/v1/responses/resp_1'], ['DELETE', '/v1/responses/resp_1'], ['POST', '/v1/responses/resp_1/cancel'],
    ['GET', '/v1/responses/resp_1/input_items']]) {
    assert.equal((await request(relay.ready.port, { method, path })).status, 200);
  }
  assert.equal(hits, 7);
});

test('WebSocket preserves both upgrade heads and raw frames while stripping identity headers', TEST_OPTIONS, async t => {
  const early = maskedFrame('early-client-frame'), later = maskedFrame('later-client-frame');
  const greeting = serverFrame('early-upstream-frame'), reply = serverFrame('later-upstream-frame');
  const handshake = deferred(), received = deferred();
  const upstream = await upstreamFixture(t, (_req, res) => res.end(), (req, socket, head) => {
    handshake.resolve(req.headers);
    let bytes = Buffer.from(head);
    const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + WS_GUID).digest('base64');
    const headers = `HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ${accept}\r\nSec-WebSocket-Protocol: responses\r\nSet-Cookie: upstream-private=1\r\nAuthorization: upstream-private\r\n\r\n`;
    socket.write(Buffer.concat([Buffer.from(headers), greeting]));
    socket.on('data', chunk => {
      bytes = Buffer.concat([bytes, chunk]);
      if (bytes.length >= early.length + later.length) { received.resolve(bytes); socket.write(reply); }
    });
  });
  const relay = await relayFixture(t, upstream.port);
  const client = await websocket(t, relay.ready.port, { head: early,
    extraHeaders: { 'thread-id': THREAD_A, 'session-id': SESSION } });
  assert.match(client.header, /^HTTP\/1\.1 101 /);
  assert(!/set-cookie|authorization:/i.test(client.header));
  assert.deepEqual(await client.reader.bytes(greeting.length), greeting);
  const incoming = await handshake.promise;
  assertSanitized(incoming, upstream.port);
  assert.equal(incoming['sec-websocket-protocol'], 'responses');
  assert.equal(incoming['sec-websocket-extensions'], undefined);
  assert.equal(incoming['thread-id'], undefined);
  assert.equal(incoming['session-id'], undefined);
  const observation = (await relay.control('status')).recentRequests[0];
  assert.equal(observation.threadID, THREAD_A);
  assert.equal(observation.sessionID, SESSION);
  assert.equal(observation.transport, 'websocket');
  assert.equal(observation.phase, 'websocket_open');
  assert.equal(observation.statusCode, 101);
  for (const op of ['disable', 'shutdown']) {
    const state = await relay.control(op);
    assert.equal(state.ok, false); assert.equal(state.status, 'busy');
    assert.equal(state.enabled, true); assert.equal(state.activeWebSockets, 1);
  }
  client.socket.write(later);
  assert.deepEqual(await bounded(received.promise, 'raw upstream frames'), Buffer.concat([early, later]));
  assert.deepEqual(await client.reader.bytes(reply.length), reply);
  client.socket.destroy();
  const ended = await waitIdle(relay);
  assert.equal(ended.recentRequests[0].id, observation.id);
  assert.equal(ended.recentRequests[0].phase, 'websocket_closed');
  assert.equal(ended.recentRequests[0].statusCode, 101);
  assert.equal((await relay.control('disable')).ok, true);
  for (const secret of ['synthetic-official-secret', 'synthetic-cookie-secret', 'early-client-frame']) assert(!relay.output().includes(secret));
});

test('HTTP observations retain only UUID attribution and transport stages, never model completion', TEST_OPTIONS, async t => {
  const received = deferred(), release = deferred(), firstChunk = deferred();
  const upstream = await upstreamFixture(t, async (req, res) => {
    received.resolve({ headers: req.headers, body: await collect(req) });
    res.writeHead(200, { 'content-type': 'text/event-stream', 'x-request-id': 'private-response-id' });
    res.write('data: {"type":"response.failed","message":"synthetic-private-model-error"}\n\n');
    await release.promise;
    res.end('data: [DONE]\n\n');
  });
  const relay = await relayFixture(t, upstream.port);
  const pending = request(relay.ready.port, { method: 'POST', path: '/v1/responses?secret=synthetic-query-secret',
    headers: { ...secretHeaders(), 'thread-id': THREAD_A.toUpperCase(), 'session-id': SESSION,
      'x-private': 'synthetic-private-header' }, body: 'synthetic-private-body', onChunk: firstChunk.resolve });
  pending.catch(() => {});
  t.after(() => release.resolve());
  await bounded(firstChunk.promise, 'observed stream first chunk');
  const status = await relay.control('status');
  assert.equal(status.observationVersion, 1);
  assert.equal(status.observationLimit, 100);
  assert.equal(status.recentRequests.length, 1);
  const row = status.recentRequests[0];
  assert.deepEqual(Object.keys(row).sort(), ['id', 'phase', 'route', 'sessionID', 'startedAt', 'statusCode', 'threadID', 'transport', 'updatedAt'].sort());
  assert.match(row.id, /^[0-9a-f-]{36}$/);
  assert(Number.isFinite(Date.parse(row.startedAt)));
  assert(Number.isFinite(Date.parse(row.updatedAt)));
  assert.equal(row.threadID, THREAD_A);
  assert.equal(row.sessionID, SESSION);
  assert.equal(row.transport, 'http');
  assert.equal(row.phase, 'http_response');
  assert.equal(row.statusCode, 200);
  assert.equal(row.route, 'copilot');
  const incoming = await received.promise;
  assert.equal(incoming.headers['thread-id'], undefined);
  assert.equal(incoming.headers['session-id'], undefined);
  assert.equal(incoming.body.toString(), 'synthetic-private-body');
  const publicHealth = JSON.parse((await request(relay.ready.port, { path: '/healthz' })).body.toString());
  assert.equal(publicHealth.recentRequests, undefined);
  assert.equal(publicHealth.observationVersion, undefined);
  release.resolve();
  const response = await pending;
  assert(response.body.toString().includes('synthetic-private-model-error'));
  const done = await waitIdle(relay);
  assert.equal(done.recentRequests[0].id, row.id);
  // SSE deliberately says response.failed. The relay must not parse that body
  // or describe successful generation merely because the HTTP stream finished.
  assert.equal(done.recentRequests[0].phase, 'http_finished');
  assert.equal(done.recentRequests[0].statusCode, 200);
  for (const secret of ['synthetic-query-secret', 'synthetic-private-header', 'synthetic-private-body',
    'synthetic-private-model-error', 'private-response-id', 'synthetic-official-secret']) {
    assert(!JSON.stringify(done).includes(secret));
    assert(!relay.output().includes(secret));
  }
});

test('Missing or malformed thread IDs remain unknown, including shared session IDs', TEST_OPTIONS, async t => {
  const upstream = await upstreamFixture(t, async (req, res) => { await collect(req); res.end('{}'); });
  const relay = await relayFixture(t, upstream.port);
  for (const headers of [{ 'thread-id': THREAD_A, 'session-id': SESSION }, { 'thread-id': THREAD_B, 'session-id': SESSION },
    { 'session-id': SESSION }, { 'thread-id': `${THREAD_A}, ${THREAD_B}`, 'session-id': SESSION },
    { 'thread-id': 'private-not-a-uuid', 'session-id': 'private-session-value' },
    { 'x-codex-thread-id': THREAD_A, session_id: SESSION }]) {
    assert.equal((await request(relay.ready.port, { method: 'POST', path: '/v1/responses', headers, body: '{}' })).status, 200);
  }
  const rows = (await waitIdle(relay)).recentRequests.toReversed();
  assert.deepEqual(rows.map(row => row.threadID), [THREAD_A, THREAD_B, null, null, null, null]);
  assert.deepEqual(rows.map(row => row.sessionID), [SESSION, SESSION, SESSION, SESSION, null, null]);
  assert(!relay.output().includes('private-not-a-uuid'));
  assert(!relay.output().includes('private-session-value'));
});

test('Recent observations are bounded, model-only, and cleared with a new relay instance', TEST_OPTIONS, async t => {
  const upstream = await upstreamFixture(t, async (req, res) => { await collect(req); res.end('{}'); });
  const relay = await relayFixture(t, upstream.port);
  const empty = await relay.control('status');
  assert.deepEqual(empty.recentRequests, []);
  await request(relay.ready.port); // Model catalogue is not a model request.
  await request(relay.ready.port, { path: '/v1/responses/response_private_id' });
  assert.deepEqual((await relay.control('status')).recentRequests, []);
  await request(relay.ready.port, { method: 'POST', path: '/v1/responses/compact', body: '{}' });
  const originalID = (await waitIdle(relay)).recentRequests[0].id;
  for (let i = 0; i < 102; i += 1) {
    await request(relay.ready.port, { method: 'POST', path: '/v1/responses', body: '{}' });
  }
  const rows = (await waitIdle(relay)).recentRequests;
  assert.equal(rows.length, 100);
  assert.equal(new Set(rows.map(row => row.id)).size, 100);
  assert(!rows.some(row => row.id === originalID));
  assert(rows.every(row => row.phase === 'http_finished' && row.statusCode === 200));
  assert.equal((await relay.control('disable')).recentRequests, undefined);
  await request(relay.ready.port, { method: 'POST', path: '/v1/responses', body: '{}' });
  assert.deepEqual((await relay.control('status')).recentRequests, rows);
  const replacement = await relayFixture(t, upstream.port);
  assert.notEqual(replacement.ready.instanceId, relay.ready.instanceId);
  assert.deepEqual((await replacement.control('status')).recentRequests, []);
});

test('HTTP disconnects and rejected WS handshakes cannot look like model success', TEST_OPTIONS, async t => {
  const released = deferred();
  const upstream = await upstreamFixture(t, async (req, res) => {
    await collect(req);
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('data: start\n\n');
    await released.promise;
    res.destroy();
  }, (_req, socket) => socket.end('HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'));
  const relay = await relayFixture(t, upstream.port);
  const first = deferred();
  const response = request(relay.ready.port, { method: 'POST', path: '/v1/responses', body: '{}', onChunk: first.resolve });
  response.catch(() => {});
  t.after(() => released.resolve());
  await bounded(first.promise, 'disconnect stream');
  released.resolve();
  await assert.rejects(response);
  const httpRow = (await waitIdle(relay)).recentRequests[0];
  assert.equal(httpRow.phase, 'http_closed');
  assert.equal(httpRow.statusCode, 200);
  const client = await websocket(t, relay.ready.port);
  assert.match(client.header, /^HTTP\/1\.1 429 /);
  client.socket.destroy();
  const wsRow = (await waitIdle(relay)).recentRequests[0];
  assert.equal(wsRow.phase, 'websocket_rejected');
  assert.equal(wsRow.statusCode, 429);
});

test('Concurrent streams preserve separate thread attribution even within one session', TEST_OPTIONS, async t => {
  const release = deferred();
  const upstream = await upstreamFixture(t, async (req, res) => {
    const body = await collect(req);
    res.writeHead(200, { 'content-type': 'application/octet-stream' });
    res.write(body);
    await release.promise;
    res.end(body);
  });
  const relay = await relayFixture(t, upstream.port);
  t.after(() => release.resolve());
  const chunks = Array.from({ length: 8 }, deferred);
  const ids = Array.from({ length: 8 }, (_, i) => `01a0ab7a-a500-7b63-80d1-1a9c16b3a64${i}`);
  const pending = ids.map((id, i) => request(relay.ready.port, { method: 'POST', path: '/v1/responses',
    headers: { 'thread-id': id, 'session-id': SESSION }, body: `opaque-payload-${i}`, onChunk: chunks[i].resolve }));
  for (const promise of pending) promise.catch(() => {});
  await Promise.all(chunks.map(chunk => chunk.promise));
  const live = await relay.control('status');
  assert.equal(live.activeRequests, 8);
  assert.equal(live.recentRequests.length, 8);
  assert.deepEqual(live.recentRequests.map(row => row.threadID).sort(), ids.toSorted());
  assert(live.recentRequests.every(row => row.sessionID === SESSION && row.phase === 'http_response'));
  release.resolve();
  const responses = await Promise.all(pending);
  responses.forEach((response, i) => assert.equal(response.body.toString(), `opaque-payload-${i}opaque-payload-${i}`));
  const finished = await waitIdle(relay);
  assert.equal(finished.recentRequests.length, 8);
  assert(finished.recentRequests.every(row => row.phase === 'http_finished'));
});

test('WebSocket redirects are rejected and secret subprotocols are not forwarded', TEST_OPTIONS, async t => {
  let headers, hits = 0, alternateHits = 0;
  const alternate = await upstreamFixture(t, (_req, res) => { alternateHits += 1; res.end('must not be reached'); });
  const upstream = await upstreamFixture(t, (_req, res) => res.end(), (req, socket) => {
    hits += 1; headers = req.headers;
    socket.end(`HTTP/1.1 302 Found\r\nLocation: http://${HOST}:${alternate.port}/never-follow\r\nContent-Length: 0\r\n\r\n`);
  });
  const relay = await relayFixture(t, upstream.port);
  const client = await websocket(t, relay.ready.port, { protocol: 'bearer.synthetic-subprotocol-secret, responses' });
  assert.match(client.header, /^HTTP\/1\.1 502 /);
  assert(!/location:/i.test(client.header));
  assert.equal(headers['sec-websocket-protocol'], undefined);
  assert.equal(hits, 1);
  assert.equal(alternateHits, 0);
  assert(!relay.output().includes('synthetic-subprotocol-secret'));
});

for (const ending of ['shutdown', 'stdin EOF', 'owned helper crash']) {
  test(`${ending} leaves no usable forwarding endpoint`, TEST_OPTIONS, async t => {
    let hits = 0;
    const upstream = await upstreamFixture(t, (_req, res) => { hits += 1; res.end('fixture'); });
    const relay = await relayFixture(t, upstream.port);
    assert.equal((await request(relay.ready.port)).status, 200);
    await waitIdle(relay);
    if (ending === 'shutdown') assert.equal((await relay.control('shutdown')).ok, true);
    else if (ending === 'stdin EOF') relay.child.stdin.end();
    else relay.child.kill('SIGKILL');
    await bounded(relay.exit, ending);
    await assert.rejects(request(relay.ready.port));
    assert.equal(hits, 1);
  });
}
