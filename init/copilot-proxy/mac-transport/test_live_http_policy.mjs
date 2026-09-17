import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { installHttpIdlePolicy, revertHttpIdlePolicy } from './live_http_policy.mjs';
import { connectInspector, localJSON } from './inspector_client.mjs';

const legacy = new URL('./fixtures/legacy-api-relay.mjs', import.meta.url);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function until(fn, label) {
  const end = Date.now() + 4000;
  while (Date.now() < end) { const value = await fn(); if (value) return value; await delay(10); }
  throw new Error('Fixture timeout: ' + label);
}

function request(port, route, body = 'synthetic-body', headers = {}, onChunk = () => {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: route,
      method: route === '/healthz' ? 'GET' : 'POST', agent: false, headers }, res => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', chunk => { data += chunk; onChunk(chunk); });
      res.on('end', () => resolve({ status: res.statusCode, body: data, complete: res.complete, headers: res.headers }));
      res.on('error', reject);
    });
    req.on('error', reject); req.setTimeout(2500, () => req.destroy(new Error('fixture_request_timeout')));
    req.end(route === '/healthz' ? undefined : body);
  });
}

async function echoClient(port) {
  const socket = net.connect(port, '127.0.0.1');
  await once(socket, 'connect');
  let pending = Buffer.alloc(0);
  const chunks = [];
  socket.on('data', chunk => { chunks.push(chunk); });
  socket.on('error', () => {});
  const take = async count => {
    await until(() => { while (chunks.length) pending = Buffer.concat([pending, chunks.shift()]); return pending.length >= count; }, 'socket bytes');
    const part = pending.subarray(0, count); pending = pending.subarray(count); return part;
  };
  socket.write(`GET /v1/responses HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n`);
  let head = '';
  while (!head.endsWith('\r\n\r\n')) head += (await take(1)).toString();
  assert.match(head, /^HTTP\/1.1 101 /);
  return { socket, async echo(text) {
    const body = Buffer.from(text), mask = Buffer.from('abcd');
    socket.write(Buffer.concat([Buffer.from([0x81, 0x80 | body.length]), mask, Buffer.from(body.map((byte, i) => byte ^ mask[i % 4]))]));
    const frame = await take(2); assert.equal(frame[0], 0x81);
    return (await take(frame[1])).toString();
  } };
}

async function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cp-live-policy-'));
  const script = path.join(root, 'legacy.mjs');
  const source = fs.readFileSync(legacy, 'utf8');
  assert(source.includes('const IDLE_TIMEOUT_MS = 120_000;'));
  fs.writeFileSync(script, source.replace('const IDLE_TIMEOUT_MS = 120_000;', 'const IDLE_TIMEOUT_MS = 200;'));
  const sockets = new Set(), received = [];
  let releaseHold;
  const server = http.createServer(async (req, res) => {
    let body = ''; for await (const chunk of req) body += chunk;
    received.push({ path: req.url, body, authorization: req.headers.authorization });
    const kind = new URL(req.url, 'http://fixture').searchParams.get('fixture');
    if (kind === 'hold') {
      res.writeHead(200, { 'content-type': 'text/event-stream' }); res.write('data: first\n\n');
      const interval = setInterval(() => res.write(': keepalive\n\n'), 40);
      res.on('close', () => clearInterval(interval));
      releaseHold = () => { clearInterval(interval); res.end('data: last\n\n'); };
    } else if (kind === 'sse') {
      res.writeHead(200, { 'content-type': 'text/event-stream' }); res.write('data: first\n\n');
      await delay(350); if (!res.destroyed) res.end('data: last\n\n');
    } else {
      await delay(350); if (!res.destroyed) res.end(body);
    }
  });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {}); });
  server.on('upgrade', (req, socket) => {
    const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
    let buffer = Buffer.alloc(0);
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 6) {
        const length = buffer[1] & 0x7f;
        if (buffer.length < 6 + length) return;
        const mask = buffer.subarray(2, 6), payload = buffer.subarray(6, 6 + length);
        const decoded = Buffer.from(payload.map((byte, i) => byte ^ mask[i % 4]));
        socket.write(Buffer.concat([Buffer.from([0x81, decoded.length]), decoded]));
        buffer = buffer.subarray(6 + length);
      }
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const upstream = server.address().port;
  const child = spawn(process.execPath, ['--inspect=127.0.0.1:0', script, '--port', '0', '--enabled', '--test-mode', '--test-upstream-port', String(upstream)],
    { stdio: ['pipe', 'pipe', 'pipe'], env: { PATH: '/usr/bin:/bin:/opt/homebrew/bin' } });
  let debugPort, ready, lines = '';
  child.stderr.on('data', chunk => { const match = chunk.toString().match(/127\.0\.0\.1:(\d+)\//); if (match) debugPort = Number(match[1]); });
  child.stdout.on('data', chunk => {
    lines += chunk;
    for (;;) { const index = lines.indexOf('\n'); if (index < 0) break;
      const line = lines.slice(0, index); lines = lines.slice(index + 1);
      const item = JSON.parse(line); if (item.event === 'ready') ready = item;
    }
  });
  await until(() => ready && debugPort, 'legacy startup');
  const inspector = await connectInspector(debugPort);
  t.after(async () => {
    await inspector.disconnect();
    if (child.exitCode === null) { child.kill('SIGTERM'); await once(child, 'exit'); }
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  });
  const config = { pid: child.pid, instanceId: ready.instanceId, listenPort: ready.port,
    upstreamPort: upstream, oldIdleMs: 200, newIdleMs: 700, testMode: true };
  return { child, ready, inspector, config, received, debugPort, release: () => releaseHold() };
}

test('live settings preserve active HTTP/WS, fix new HTTP/SSE idleness, and revert', { timeout: 15000 }, async t => {
  const f = await fixture(t), port = f.ready.port;
  const baseline = await request(port, '/v1/responses?fixture=late-before');
  assert.equal(baseline.status, 502);
  const ws = await echoClient(port); t.after(() => ws.socket.destroy());
  assert.equal(await ws.echo('before'), 'before');
  let sawFirst = false;
  const held = request(port, '/v1/responses?fixture=hold', 'held-body', {}, () => { sawFirst = true; });
  await until(() => sawFirst, 'active HTTP stream');
  const before = await localJSON(port, '/healthz');
  assert.equal(before.activeWebSockets, 1);
  const result = await f.inspector.evaluate(`(${installHttpIdlePolicy.toString()})(${JSON.stringify(f.config)})`);
  assert.equal(result.active, true);
  const health = await localJSON(port, '/healthz');
  assert.equal(health.pid, before.pid); assert.equal(health.instanceId, before.instanceId);
  assert.equal(health.activeWebSockets, 1); assert.equal(health.httpIdleTimeoutMs, 700);
  assert.equal(health.observationVersion, before.observationVersion);
  assert.equal(health.transportVersion, before.transportVersion);
  assert.equal((await request(port, '/healthz', '', { Origin: 'https://untrusted.example' })).status, 403);
  assert.equal((await request(port, '/healthz', '', { Host: 'untrusted.example' })).status, 403);
  const body = 'exact synthetic payload 你好';
  const response = await request(port, '/v1/responses?fixture=late-after', body, { Authorization: 'Bearer synthetic-secret' });
  assert.equal(response.status, 200); assert.equal(response.body, body);
  const sse = await request(port, '/v1/responses?fixture=sse');
  assert.equal(sse.status, 200); assert.equal(sse.complete, true);
  assert.equal(sse.body, 'data: first\n\ndata: last\n\n');
  assert.equal(await ws.echo('after'), 'after');
  f.release(); const heldResult = await held;
  assert(heldResult.body.startsWith('data: first\n\n')); assert(heldResult.body.endsWith('data: last\n\n'));
  const hits = f.received.filter(row => row.path.includes('late-after'));
  assert.equal(hits.length, 1); assert.equal(hits[0].authorization, 'Bearer local');
  assert.equal((await f.inspector.evaluate(`(${installHttpIdlePolicy.toString()})(${JSON.stringify(f.config)})`)).active, true);
  assert.equal((await f.inspector.evaluate(`(${revertHttpIdlePolicy.toString()})()`)).reverted, true);
  assert.equal((await localJSON(port, '/healthz')).networkPolicy, undefined);
  assert.equal((await request(port, '/v1/responses?fixture=late-reverted')).status, 502);
  assert.equal(await ws.echo('reverted'), 'reverted');
});

test('wrong target and nonstandard production mappings cannot be patched', { timeout: 10000 }, async t => {
  const f = await fixture(t);
  for (const config of [{ ...f.config, pid: f.child.pid + 1 }, { ...f.config, testMode: false }]) {
    await assert.rejects(f.inspector.evaluate(`(${installHttpIdlePolicy.toString()})(${JSON.stringify(config)})`));
  }
  assert.equal((await localJSON(f.ready.port, '/healthz')).networkPolicy, undefined);
});

test('temporary inspector can close without exiting the relay', { timeout: 10000 }, async t => {
  const f = await fixture(t);
  await f.inspector.evaluate('setTimeout(() => process.getBuiltinModule("inspector").close(), 200).unref(); true');
  await f.inspector.disconnect();
  await delay(350);
  await assert.rejects(localJSON(f.debugPort, '/json/list'));
  assert.equal((await localJSON(f.ready.port, '/healthz')).pid, f.child.pid);
  assert.equal(f.child.exitCode, null);
});
