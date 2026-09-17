// One-time, reversible settings bridge for the legacy running relay.
// The installed relay already has the durable 600s default for its next start.
// This function is self-contained so a local Node inspector can evaluate it.
export function installHttpIdlePolicy(config) {
  const key = Symbol.for('tree.copilot.http-idle-policy.v1');
  const http = process.getBuiltinModule('http');
  if (process.pid !== config.pid || !Number.isInteger(config.listenPort)
      || !Number.isInteger(config.upstreamPort) || typeof config.instanceId !== 'string'
      || !Number.isInteger(config.oldIdleMs) || !Number.isInteger(config.newIdleMs)
      || config.newIdleMs <= config.oldIdleMs) throw new Error('invalid_policy_target');
  if (!config.testMode && (config.listenPort !== 4142 || config.upstreamPort !== 4141
      || config.oldIdleMs !== 120000 || config.newIdleMs !== 600000)) throw new Error('unexpected_production_policy');
  const previous = globalThis[key];
  if (previous) {
    if (JSON.stringify(previous.config) !== JSON.stringify(config) || !previous.summary().active) {
      throw new Error('different_or_displaced_policy');
    }
    return previous.summary();
  }
  const requestDescriptor = Object.getOwnPropertyDescriptor(http, 'request');
  const emitDescriptor = Object.getOwnPropertyDescriptor(http.Server.prototype, 'emit');
  const originalRequest = http.request;
  const originalEmit = http.Server.prototype.emit;
  let appliedRequests = 0;
  const policy = {
    config: Object.freeze({ ...config }),
    summary: () => ({ version: 1, source: 'live-http-settings',
      active: http.request === requestHook && http.Server.prototype.emit === emitHook,
      httpIdleTimeoutMs: config.newIdleMs, appliesToNewHttpRequests: true, appliedRequests }),
    revert: () => {
      if (!policy.summary().active) throw new Error('policy_hooks_changed');
      Object.defineProperty(http, 'request', requestDescriptor);
      if (emitDescriptor) Object.defineProperty(http.Server.prototype, 'emit', emitDescriptor);
      else delete http.Server.prototype.emit;
      delete globalThis[key];
      return { reverted: true, pid: process.pid };
    },
  };
  function requestHook(...args) {
    const options = args[0];
    if (options && typeof options === 'object' && options.host === '127.0.0.1'
        && Number(options.port) === config.upstreamPort && options.timeout === config.oldIdleMs
        && typeof options.path === 'string' && options.path.startsWith('/v1/')
        && String(options.headers?.upgrade ?? '').toLowerCase() !== 'websocket') {
      args[0] = { ...options, timeout: config.newIdleMs };
      appliedRequests += 1;
    }
    // No retries, payload access, credential changes, or existing-socket edits.
    return Reflect.apply(originalRequest, this, args);
  }
  function emitHook(...args) {
    const [event, request, response] = args;
    const address = event === 'request' && request?.method === 'GET' && request.url === '/healthz'
      ? this.address() : null;
    if (address?.address === '127.0.0.1' && address.port === config.listenPort) {
      const writeHead = response.writeHead;
      const end = response.end;
      let pendingHead = null;
      response.writeHead = function (...head) { pendingHead = head; return this; };
      response.end = function (chunk, ...rest) {
        this.writeHead = writeHead;
        this.end = end;
        let body = chunk;
        try {
          const value = JSON.parse(Buffer.isBuffer(chunk) ? chunk.toString('utf8') : chunk);
          if (pendingHead?.length === 2 && pendingHead[0] === 200 && pendingHead[1]
              && typeof pendingHead[1] === 'object' && !Array.isArray(pendingHead[1])
              && value.pid === config.pid && value.instanceId === config.instanceId
              && value.port === config.listenPort && value.upstreamPort === config.upstreamPort) {
            const current = policy.summary();
            // Report only the settings actually changed; never impersonate v2
            // or enable the newer request-recording feature in the old process.
            body = Buffer.from(JSON.stringify({ ...value, networkPolicy: current,
              ...(current.active ? { httpIdleTimeoutMs: current.httpIdleTimeoutMs } : {}) }));
            const headers = { ...pendingHead[1] };
            for (const name of Object.keys(headers)) if (name.toLowerCase() === 'content-length') delete headers[name];
            headers['content-length'] = body.length;
            pendingHead = [200, headers];
          }
        } catch { /* Preserve all other health/security responses unchanged. */ }
        if (pendingHead) Reflect.apply(writeHead, this, pendingHead);
        return Reflect.apply(end, this, [body, ...rest]);
      };
    }
    return Reflect.apply(originalEmit, this, args);
  }
  try {
    Object.defineProperty(http, 'request', { ...requestDescriptor, value: requestHook });
    Object.defineProperty(http.Server.prototype, 'emit', {
      configurable: true, writable: true, enumerable: emitDescriptor?.enumerable ?? false, value: emitHook,
    });
    globalThis[key] = policy;
  } catch (error) {
    Object.defineProperty(http, 'request', requestDescriptor);
    if (emitDescriptor) Object.defineProperty(http.Server.prototype, 'emit', emitDescriptor);
    else delete http.Server.prototype.emit;
    throw error;
  }
  return policy.summary();
}

export function revertHttpIdlePolicy() {
  const policy = globalThis[Symbol.for('tree.copilot.http-idle-policy.v1')];
  return policy ? policy.revert() : { reverted: false, reason: 'not-installed', pid: process.pid };
}
