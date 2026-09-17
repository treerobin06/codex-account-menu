import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const NODE = '/opt/homebrew/bin/node';
const HELPER = fileURLToPath(new URL('../../Sources/SwitcherCore/Resources/codex-api-relay.mjs', import.meta.url));
const options = { timeout: 10_000 };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function until(action, label) {
  const deadline = Date.now() + 3000;
  let last;
  while (Date.now() < deadline) {
    try { const value = await action(); if (value) return value; } catch (error) { last = error; }
    await delay(10);
  }
  throw new Error(`Timed out: ${label}${last ? ` (${last.code ?? last.message})` : ''}`);
}

function control(socketPath, op, id = randomUUID()) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketPath);
    let data = '';
    socket.setEncoding('utf8');
    socket.setTimeout(2000, () => socket.destroy(new Error('control_timeout')));
    socket.on('error', reject);
    socket.on('connect', () => socket.write(`${JSON.stringify({ id, op })}\n`));
    socket.on('data', chunk => { data += chunk; });
    socket.on('end', () => {
      try {
        const lines = data.trim().split('\n');
        assert.equal(lines.length, 1);
        const response = JSON.parse(lines[0]);
        assert.equal(response.id, id);
        assert.equal(response.op, op);
        resolve(response);
      } catch (error) { reject(error); }
    });
  });
}

function health(port, route = '/healthz') {
  return new Promise((resolve, reject) => {
    const request = http.get({ host: '127.0.0.1', port, path: route, agent: false }, response => {
      let data = '';
      response.on('data', bytes => { data += bytes.toString(); });
      response.on('end', () => resolve({ status: response.statusCode, value: data ? JSON.parse(data) : null }));
    });
    request.on('error', reject);
    request.setTimeout(2000, () => request.destroy(new Error('http_timeout')));
  });
}

async function fixture(t, setup = () => {}) {
  const directory = fs.mkdtempSync(path.join(fs.realpathSync('/tmp'), 'relay-control-'));
  fs.chmodSync(directory, 0o700);
  const controlDirectory = path.join(directory, 'bridge');
  fs.mkdirSync(controlDirectory, { mode: 0o700 });
  const socketPath = path.join(controlDirectory, 'control.sock');
  const sockets = new Set();
  const server = http.createServer((request, response) => {
    request.resume();
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end('{"fixture":true}');
  });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {}); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const upstreamPort = server.address().port;
  assert.notEqual(upstreamPort, 4141);
  setup({ directory, socketPath, controlDirectory });
  const child = spawn(NODE, [HELPER, '--port', '0', '--enabled', '--test-mode', '--test-upstream-port', String(upstreamPort),
    '--control-socket', socketPath], { stdio: ['pipe', 'pipe', 'pipe'], env: { PATH: '/opt/homebrew/bin:/usr/bin:/bin' } });
  const events = [];
  let buffer = '';
  child.stdin.on('error', () => {});
  child.stdout.on('data', data => {
    buffer += data;
    let end;
    while ((end = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, end);
      buffer = buffer.slice(end + 1);
      if (line) events.push(JSON.parse(line));
    }
  });
  child.stderr.on('data', () => {});
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      try { await control(socketPath, 'shutdown'); } catch {}
      try { await until(() => child.exitCode !== null || child.signalCode !== null, 'helper exits'); }
      catch { child.kill('SIGKILL'); await until(() => child.signalCode !== null, 'owned helper kill'); }
    }
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(directory, { recursive: true, force: true });
  });
  return { child, directory, socketPath, controlDirectory, upstreamPort, server, events };
}

async function ready(fixture_) {
  const status = await until(async () => {
    if (fixture_.child.exitCode !== null) throw new Error('helper_exited');
    const state = await control(fixture_.socketPath, 'status');
    return state.ok ? state : null;
  }, 'socket ready');
  assert.equal(status.protocolVersion, 1);
  assert.equal(status.pid, fixture_.child.pid);
  assert.equal(status.host, '127.0.0.1');
  assert.equal(status.testMode, true);
  assert.equal(status.upstreamPort, fixture_.upstreamPort);
  assert.equal(status.controlSocket, fixture_.socketPath);
  return status;
}

test('Unix control is private, reusable, and survives caller stdio closing', options, async t => {
  const item = await fixture(t);
  const original = await ready(item);
  assert.equal(fs.statSync(item.controlDirectory).mode & 0o777, 0o700);
  assert.equal(fs.statSync(item.socketPath).mode & 0o777, 0o600);
  assert(fs.statSync(item.socketPath).isSocket());
  const disabled = await control(item.socketPath, 'disable');
  assert.equal(disabled.ok, true);
  assert.equal(disabled.enabled, false);
  assert.equal((await health(original.port, '/v1/models')).status, 503);
  const enabled = await control(item.socketPath, 'enable');
  assert.equal(enabled.instanceId, original.instanceId);
  assert.equal(enabled.pid, original.pid);
  assert.equal(enabled.enabled, true);
  item.child.stdin.end();
  item.child.stdout.destroy();
  assert.equal((await health(original.port, '/v1/models')).status, 200);
  await delay(30); // Allow the metrics write to observe a disconnected stdout reader.
  assert.equal((await control(item.socketPath, 'status')).pid, original.pid);
  const shutdown = await control(item.socketPath, 'shutdown');
  assert.equal(shutdown.ok, true);
  await until(() => item.child.exitCode !== null, 'normal shutdown');
  assert.equal(item.child.exitCode, 0);
  assert.equal(fs.existsSync(item.socketPath), false);
});

test('Unix control rejects busy disable/shutdown while a model stream is active', options, async t => {
  const item = await fixture(t);
  let finish;
  item.server.removeAllListeners('request');
  item.server.on('request', (request, response) => {
    request.resume();
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.write('data: first\n\n');
    finish = () => response.end('data: last\n\n');
  });
  const state = await ready(item);
  const threadID = '01a0ab7a-a500-7b63-80d1-1a9c16b3a64c';
  const request = http.request({ host: '127.0.0.1', port: state.port, method: 'POST', path: '/v1/responses', agent: false,
    headers: { 'thread-id': threadID } });
  const ended = new Promise((resolve, reject) => {
    request.on('response', response => { response.resume(); response.on('end', resolve); response.on('error', reject); });
    request.on('error', reject);
  });
  request.end('{}');
  await until(async () => (await control(item.socketPath, 'status')).activeRequests === 1, 'active stream');
  const observed = await control(item.socketPath, 'status');
  assert.equal(observed.protocolVersion, 1);
  assert.equal(observed.observationVersion, 1);
  assert.equal(observed.recentRequests[0].threadID, threadID);
  assert.equal(observed.recentRequests[0].sessionID, null);
  assert.equal((await health(state.port)).value.recentRequests, undefined);
  for (const op of ['disable', 'shutdown']) {
    const response = await control(item.socketPath, op);
    assert.equal(response.ok, false);
    assert.equal(response.status, 'busy');
    assert.equal(response.enabled, true);
    assert.equal(response.activeRequests, 1);
  }
  finish();
  await ended;
  assert.equal((await control(item.socketPath, 'status')).recentRequests[0].phase, 'http_finished');
  assert.equal((await control(item.socketPath, 'disable')).ok, true);
});

test('Existing foreign file or symlink is never replaced', options, async t => {
  for (const symlink of [false, true]) {
    const marker = `foreign-${symlink}`;
    const item = await fixture(t, ({ socketPath, directory }) => {
      if (symlink) {
        fs.writeFileSync(path.join(directory, 'target'), marker, { mode: 0o600 });
        fs.symlinkSync(path.join(directory, 'target'), socketPath);
      } else fs.writeFileSync(socketPath, marker, { mode: 0o600 });
    });
    await until(() => item.child.exitCode !== null, 'foreign path refusal');
    assert.equal(item.child.exitCode, 2);
    assert.equal(fs.readFileSync(item.socketPath, 'utf8'), marker);
    assert.equal(fs.lstatSync(item.socketPath).isSymbolicLink(), symlink);
    assert(item.events.some(event => event.event === 'fatal' && event.status === 'control_path_exists'));
  }
});

test('Unix shutdown never unlinks a file that replaced its original socket', options, async t => {
  const item = await fixture(t);
  await ready(item);
  fs.renameSync(item.socketPath, path.join(item.controlDirectory, 'owned-socket-moved'));
  fs.writeFileSync(item.socketPath, 'replacement-must-survive', { mode: 0o600 });
  const id = randomUUID();
  item.child.stdin.write(`${JSON.stringify({ id, op: 'shutdown' })}\n`);
  await until(() => item.child.exitCode !== null, 'replacement-safe shutdown');
  assert.equal(item.child.exitCode, 0);
  assert.equal(fs.readFileSync(item.socketPath, 'utf8'), 'replacement-must-survive');
});
