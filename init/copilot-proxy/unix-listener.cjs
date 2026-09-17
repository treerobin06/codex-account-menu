// Test-only transport adapter: keep unmodified upstream HTTP handlers private.
const net = require('node:net');
const fs = require('node:fs');
const socketPath = process.env.TREE_COPILOT_SOCKET;
if (!socketPath || !socketPath.startsWith('/run/tree-copilot-')) {
  throw new Error('A private runtime Unix socket is required');
}
const originalListen = net.Server.prototype.listen;
let bound = false;
net.Server.prototype.listen = function (...args) {
  if (bound) throw new Error('Unexpected second server listener');
  bound = true;
  const callback = typeof args.at(-1) === 'function' ? args.at(-1) : undefined;
  this.once('listening', () => fs.chmodSync(socketPath, 0o600));
  return originalListen.call(this, socketPath, callback);
};
