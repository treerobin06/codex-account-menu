// Local Node inspector only. No browser connection, pausing, heap inspection,
// credential inspection, or payload logging.
import http from 'node:http';

export function localJSON(port, path) {
  return new Promise((resolve, reject) => {
    const request = http.get({ host: '127.0.0.1', port, path, agent: false }, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => {
        body += chunk;
        if (body.length > 128000) request.destroy(new Error('oversized_local_response'));
      });
      response.on('end', () => {
        try { resolve(JSON.parse(body)); } catch { reject(new Error('invalid_local_json')); }
      });
      response.on('error', reject);
    });
    request.setTimeout(2000, () => request.destroy(new Error('local_request_timeout')));
    request.on('error', reject);
  });
}

export async function connectInspector(port) {
  const targets = await localJSON(port, '/json/list');
  if (!Array.isArray(targets) || targets.length !== 1) throw new Error('unexpected_inspector_targets');
  const address = new URL(targets[0].webSocketDebuggerUrl);
  if (address.protocol !== 'ws:' || address.hostname !== '127.0.0.1' || Number(address.port) !== port) {
    throw new Error('nonlocal_inspector_endpoint');
  }
  const socket = new WebSocket(address);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { socket.close(); reject(new Error('inspector_connect_timeout')); }, 2500);
    socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
    socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('inspector_connect_error')); }, { once: true });
  });
  const pending = new Map();
  let identifier = 0;
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    const waiter = pending.get(message.id);
    if (!waiter) return; // Ignore unrelated inspector events; do not print them.
    pending.delete(message.id); clearTimeout(waiter.timer);
    if (message.error) waiter.reject(new Error('inspector_protocol_error'));
    else waiter.resolve(message.result);
  });
  socket.addEventListener('close', () => {
    for (const item of pending.values()) { clearTimeout(item.timer); item.reject(new Error('inspector_disconnected')); }
    pending.clear();
  });
  return {
    async evaluate(expression) {
      const id = ++identifier;
      const result = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error('inspector_evaluation_timeout')); }, 3000);
        pending.set(id, { resolve, reject, timer });
        socket.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: {
          expression, returnByValue: true, awaitPromise: true, timeout: 1500,
        } }));
      });
      if (result.exceptionDetails) throw new Error('runtime_evaluation_rejected');
      return result.result?.value;
    },
    async disconnect() {
      if (socket.readyState === WebSocket.CLOSED) return;
      await new Promise(resolve => {
        const timer = setTimeout(resolve, 1500);
        socket.addEventListener('close', () => { clearTimeout(timer); resolve(); }, { once: true });
        socket.close();
      });
    },
  };
}
