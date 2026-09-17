import fs from 'node:fs';
import net from 'node:net';
import { createHash } from 'node:crypto';
import { installHttpIdlePolicy, revertHttpIdlePolicy } from './live_http_policy.mjs';
import { connectInspector, localJSON } from './inspector_client.mjs';

const ticket = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const config = ticket.config;
if (ticket.deadline < Date.now() || !['apply', 'revert'].includes(ticket.action)
    || config.testMode || config.listenPort !== 4142 || config.upstreamPort !== 4141) {
  throw new Error('invalid_or_expired_ticket');
}
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
await new Promise((resolve, reject) => {
  const probe = net.createServer();
  probe.once('error', () => reject(new Error('inspector_port_already_in_use')));
  probe.listen(9229, '127.0.0.1', () => probe.close(resolve));
});
const before = await localJSON(4142, '/healthz');
if (before.pid !== config.pid || before.instanceId !== config.instanceId || !before.enabled
    || before.testMode || before.upstreamPort !== 4141) throw new Error('relay_identity_changed');
let inspector, verified = false, applied = false, result;
// SIGUSR1 starts only this Node process's loopback inspector, without pausing.
process.kill(config.pid, 'SIGUSR1');
const cleanupExpression = milliseconds => `(() => {
  const inspector = process.getBuiltinModule('inspector');
  const key = Symbol.for('tree.copilot.temporary-inspector-cleanup');
  if (globalThis[key]) clearTimeout(globalThis[key].timer);
  const marker = { url: inspector.url() };
  marker.timer = setTimeout(() => {
    if (globalThis[key] === marker) {
      delete globalThis[key];
      if (inspector.url() === marker.url) inspector.close();
    }
  }, ${milliseconds}).unref();
  globalThis[key] = marker;
  return true;
})()`;
try {
  const deadline = Date.now() + 3500;
  while (Date.now() < deadline) {
    try { inspector = await connectInspector(9229); break; }
    catch { await wait(40); }
  }
  if (!inspector) throw new Error('owned_inspector_not_reachable');
  const identity = await inspector.evaluate('({pid:process.pid,uid:process.getuid()})');
  if (identity.pid !== config.pid || identity.uid !== process.getuid()) throw new Error('inspector_target_mismatch');
  verified = true;
  await inspector.evaluate(cleanupExpression(10000));
  if (ticket.action === 'apply') {
    const policy = await inspector.evaluate(`(${installHttpIdlePolicy.toString()})(${JSON.stringify(config)})`);
    applied = true;
    if (!policy.active) throw new Error('policy_not_active');
  } else {
    await inspector.evaluate(`(${revertHttpIdlePolicy.toString()})()`);
  }
  const models = await localJSON(4142, '/v1/models');
  const ids = (models.data ?? []).map(item => item.id).sort();
  const hash = createHash('sha256').update(ids.join('\n')).digest('hex');
  const after = await localJSON(4142, '/healthz');
  if (after.pid !== before.pid || after.instanceId !== before.instanceId
      || ids.length === 0 || hash !== ticket.modelsHash) throw new Error('post_update_data_path_changed');
  if (ticket.action === 'apply' && (!after.networkPolicy?.active || after.httpIdleTimeoutMs !== 600000
      || after.networkPolicy.appliedRequests < 1)) throw new Error('live_request_policy_not_verified');
  if (ticket.action === 'revert' && after.networkPolicy !== undefined) throw new Error('revert_not_verified');
  if (after.observationVersion !== before.observationVersion) throw new Error('recording_state_changed');
  result = { action: ticket.action, pid: after.pid, instanceId: after.instanceId,
    networkPolicy: after.networkPolicy ?? null, models: ids.length, modelsHash: hash,
    httpRequestsBefore: before.activeRequests, httpRequestsAfter: after.activeRequests,
    webSocketsBefore: before.activeWebSockets, webSocketsAfter: after.activeWebSockets,
    processRestarted: false, recordingStateChanged: false };
} catch (error) {
  if (verified && ticket.action === 'apply') {
    try { await inspector.evaluate(`(${revertHttpIdlePolicy.toString()})()`); applied = false; }
    catch { /* Preserve uncertainty in the reported failure; never kill a relay. */ }
  }
  result = { action: ticket.action, error: error.message, appliedMayRemain: applied, processRestarted: false };
} finally {
  if (inspector && verified) {
    try { await inspector.evaluate(cleanupExpression(200)); } catch {}
  }
  if (inspector) await inspector.disconnect();
}
let closed = false;
for (let i = 0; i < 20; i += 1) {
  await wait(100);
  try { await localJSON(9229, '/json/list'); } catch { closed = true; break; }
}
result.inspectorClosed = closed;
console.log(JSON.stringify(result, null, 2));
if (result.error || !closed) process.exitCode = 1;
