import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';

const helper = fileURLToPath(new URL('../../Sources/SwitcherCore/Resources/codex-api-relay.mjs', import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function fixture(t, handler, idle = null) {
  const sockets = new Set();
  const server = http.createServer(handler);
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {}); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const args = [helper, '--port', '0', '--enabled', '--test-mode', '--test-upstream-port', String(server.address().port)];
  if (idle !== null) args.push('--test-http-idle-ms', String(idle));
  const child = spawn(process.execPath, args, { stdio: ['pipe', 'pipe', 'pipe'] });
  let buffer = '';
  const ready = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', code => reject(new Error('early_exit_' + code)));
    child.stdout.on('data', chunk => {
      buffer += chunk;
      const end = buffer.indexOf('\n');
      if (end >= 0) { const row = JSON.parse(buffer.slice(0, end)); if (row.event === 'ready') resolve(row); }
    });
  });
  t.after(async () => {
    if (child.exitCode === null) { child.kill('SIGTERM'); await once(child, 'exit'); }
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
  });
  return await ready;
}

function request(port, path = '/v1/responses') {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path, method: path === '/healthz' ? 'GET' : 'POST', agent: false }, res => {
      let body = '';
      res.on('data', chunk => { body += chunk; });
      res.once('end', () => resolve({ status: res.statusCode, body, complete: res.complete }));
      res.once('error', () => resolve({ status: res.statusCode, body, complete: false }));
    });
    req.setTimeout(2500, () => req.destroy(new Error('test_client_timeout')));
    req.once('error', reject);
    req.end(path === '/healthz' ? undefined : '{}');
  });
}

test('production defaults separate model idleness from connection and upgrade waiting', { timeout: 5000 }, async t => {
  const state = await fixture(t, (req, res) => { req.resume(); res.end('{}'); });
  const health = JSON.parse((await request(state.port, '/healthz')).body);
  assert.equal(health.transportVersion, 2);
  assert.equal(health.httpIdleTimeoutMs, 600000);
  assert.equal(health.upstreamConnectTimeoutMs, 3000);
  assert.equal(health.websocketHandshakeIdleTimeoutMs, 30000);
});

test('HTTP delayed first byte completes within the selected idle budget', { timeout: 5000 }, async t => {
  const state = await fixture(t, async (req, res) => { req.resume(); await sleep(180); res.end('{"ok":true}'); }, 500);
  const result = await request(state.port);
  assert.equal(result.status, 200);
  assert.deepEqual(JSON.parse(result.body), { ok: true });
});

test('pre-header idle expiration is explicitly 504 and is not retried', { timeout: 5000 }, async t => {
  let received = 0;
  const state = await fixture(t, req => { received += 1; req.resume(); }, 150);
  const result = await request(state.port);
  assert.equal(result.status, 504);
  assert.equal(JSON.parse(result.body).error.code, 'upstream_idle_timeout');
  assert.equal(received, 1);
});

test('SSE activity resets the idle timer; total duration can exceed the budget', { timeout: 5000 }, async t => {
  const state = await fixture(t, async (req, res) => {
    req.resume(); res.writeHead(200, { 'content-type': 'text/event-stream' });
    for (let i = 0; i < 5; i += 1) { res.write(`data: ${i}\n\n`); await sleep(110); }
    res.end('data: done\n\n');
  }, 250);
  const result = await request(state.port);
  assert.equal(result.complete, true);
  assert.equal(result.body, 'data: 0\n\ndata: 1\n\ndata: 2\n\ndata: 3\n\ndata: 4\n\ndata: done\n\n');
});

test('post-header SSE silence closes the incomplete stream without appending JSON', { timeout: 5000 }, async t => {
  const state = await fixture(t, (req, res) => {
    req.resume(); res.writeHead(200, { 'content-type': 'text/event-stream' }); res.write('data: first\n\n');
  }, 150);
  const result = await request(state.port);
  assert.equal(result.complete, false);
  assert.equal(result.body, 'data: first\n\n');
});

test('test timeout override is rejected outside explicit isolated test mode', { timeout: 5000 }, async () => {
  const child = spawn(process.execPath, [helper, '--port', '0', '--test-http-idle-ms', '150'], { stdio: ['pipe', 'pipe', 'pipe'] });
  const [code] = await once(child, 'exit');
  assert.notEqual(code, 0);
});
