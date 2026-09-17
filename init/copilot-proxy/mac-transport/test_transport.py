#!/usr/bin/env python3
"""Integration tests with synthetic local HTTP/SSE/WebSocket traffic only."""
import base64
import csv
import hashlib
import http.client
import http.server
import importlib.util
import io
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('copilot_link', ROOT / 'copilot-link.py')
link = importlib.util.module_from_spec(spec)
spec.loader.exec_module(link)
BINARY = link.BIN_SOURCE


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    assert port not in (4141, 4142, 4143, 14141, 14142)
    return port


class Fixture(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, name):
        super().__init__(('127.0.0.1', 0), Handler)
        self.name, self.available, self.application_ready = name, True, True
        self.posts = []
        self.worker = threading.Thread(target=self.serve_forever, kwargs={'poll_interval': .02}, daemon=True)
        self.worker.start()

    def finish(self):
        self.shutdown()
        self.server_close()
        self.worker.join(timeout=1)

    def handle_error(self, *_):
        pass  # Expected when a failure-injection case closes a stream.


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def respond(self, status, data):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def do_GET(self):
        if self.path == '/readyz':
            status = 404 if not self.server.available else 200 if self.server.application_ready else 503
            self.respond(status, b'{"status":"ready"}')
        elif self.headers.get('Upgrade', '').lower() == 'websocket':
            digest = hashlib.sha1((self.headers['Sec-WebSocket-Key'] +
                                   '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', base64.b64encode(digest).decode())
            self.end_headers()
            self.wfile.flush()
            while True:
                head = self.rfile.read(2)
                if len(head) != 2 or head[0] & 0x0f == 8:
                    break
                length = head[1] & 127
                assert length < 126
                mask = self.rfile.read(4)
                data = self.rfile.read(length)
                plain = bytes(byte ^ mask[i % 4] for i, byte in enumerate(data))
                response = self.server.name.encode() + b':' + plain
                self.wfile.write(bytes((0x81, len(response))) + response)
                self.wfile.flush()
            self.close_connection = True
        else:
            self.respond(200, self.server.name.encode())

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        self.server.posts.append(body)
        if self.path == '/abort-after-receive':
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        if self.path == '/sse':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            for text in (b'data: alpha\n\n', b'data: beta\n\n', b'data: [DONE]\n\n'):
                self.wfile.write(('%x\r\n' % len(text)).encode() + text + b'\r\n')
                self.wfile.flush()
                time.sleep(.02)
            self.wfile.write(b'0\r\n\r\n')
            self.wfile.flush()
        else:
            self.respond(200, body)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='copilot-link-test-', dir='/tmp')
        self.path = Path(self.temp.name)
        self.primary, self.backup = Fixture('primary'), Fixture('backup')
        self.port = free_port()
        self.control = self.path / 'admin.sock'
        config = link.render(self.port, self.control, self.primary.server_port, self.backup.server_port,
                             wait='1200ms', interval='100ms', rise=1, fall=1)
        (self.path / 'haproxy.cfg').write_text(config)
        checked = subprocess.run([str(BINARY), '-c', '-f', str(self.path / 'haproxy.cfg')], capture_output=True)
        self.assertEqual(checked.returncode, 0, checked.stderr.decode())
        self.log = open(self.path / 'process.log', 'w+')
        self.process = subprocess.Popen([str(BINARY), '-db', '-f', str(self.path / 'haproxy.cfg')],
                                        stdout=self.log, stderr=self.log)
        self.sockets = []
        self.wait_state('primary', 'UP')
        self.wait_state('backup', 'UP')

    def tearDown(self):
        for connection in self.sockets:
            connection.close()
        self.process.terminate()
        self.process.wait(timeout=3)
        self.primary.finish()
        self.backup.finish()
        self.log.close()
        self.temp.cleanup()

    def stats(self):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(1)
            sock.connect(str(self.control))
            sock.sendall(b'show stat\n')
            sock.shutdown(socket.SHUT_WR)
            data = b''
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                data += chunk
        return {row['svname']: row['status'] for row in csv.DictReader(io.StringIO(data.decode().lstrip('# ')))
                if row['pxname'] == 'copilot_paths'}

    def wait_state(self, name, state):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            try:
                if self.stats().get(name) == state:
                    return
            except OSError:
                pass
            if self.process.poll() is not None:
                self.log.seek(0)
                self.fail(self.log.read())
            time.sleep(.02)
        self.fail('Missing server state ' + name + '=' + state)

    def request(self, method='GET', path='/probe', body=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=4)
        try:
            connection.request(method, path, body=body)
            response = connection.getresponse()
            return response.status, response.read(), {k.lower(): v for k, v in response.getheaders()}
        finally:
            connection.close()

    def websocket(self):
        sock = socket.create_connection(('127.0.0.1', self.port), timeout=3)
        self.sockets.append(sock)
        sock.sendall(b'GET /v1/responses HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n')
        head = b''
        while b'\r\n\r\n' not in head:
            head += sock.recv(1)
        self.assertIn(b' 101 ', head)
        return sock

    def ws_echo(self, sock, data=b'hello'):
        mask = b'abcd'
        sock.sendall(bytes((0x81, 0x80 | len(data))) + mask + bytes(x ^ mask[i % 4] for i, x in enumerate(data)))
        header = sock.recv(2)
        self.assertEqual(header[0], 0x81)
        result = b''
        while len(result) < header[1]:
            result += sock.recv(header[1] - len(result))
        return result

    def test_primary_and_exact_post_body(self):
        self.assertEqual(self.request()[1], b'primary')
        body = bytes(range(256)) * 256
        self.assertEqual(self.request('POST', '/echo', body)[1], body)
        self.assertEqual(len(self.primary.posts), 1)
        self.assertEqual(len(self.backup.posts), 0)

    def test_sse_is_complete(self):
        status, data, headers = self.request('POST', '/sse', b'{}')
        self.assertEqual(status, 200)
        self.assertEqual(data, b'data: alpha\n\ndata: beta\n\ndata: [DONE]\n\n')
        self.assertEqual(headers['content-type'], 'text/event-stream')

    def test_failover_and_no_eviction_of_websocket(self):
        original = self.websocket()
        self.assertEqual(self.ws_echo(original), b'primary:hello')
        self.primary.available = False
        self.wait_state('primary', 'DOWN')
        self.assertEqual(self.request()[1], b'backup')
        self.assertEqual(self.ws_echo(original), b'primary:hello')
        fallback = self.websocket()
        self.assertEqual(self.ws_echo(fallback), b'backup:hello')
        self.primary.available = True
        self.wait_state('primary', 'UP')
        self.assertEqual(self.request()[1], b'primary')
        self.assertEqual(self.ws_echo(fallback), b'backup:hello')

    def test_short_total_outage_waits_then_delivers_once(self):
        self.primary.available = self.backup.available = False
        self.wait_state('primary', 'DOWN')
        self.wait_state('backup', 'DOWN')
        timer = threading.Timer(.25, lambda: setattr(self.primary, 'available', True))
        timer.start()
        try:
            start = time.monotonic()
            status, body, _ = self.request('POST', '/echo', b'one-off-request')
            self.assertEqual((status, body), (200, b'one-off-request'))
            self.assertGreater(time.monotonic() - start, .2)
            self.assertEqual(self.primary.posts, [b'one-off-request'])
            self.assertEqual(self.backup.posts, [])
        finally:
            timer.join()

    def test_total_outage_is_bounded_and_explicit(self):
        self.primary.available = self.backup.available = False
        self.wait_state('primary', 'DOWN')
        self.wait_state('backup', 'DOWN')
        start = time.monotonic()
        status, body, headers = self.request()
        elapsed = time.monotonic() - start
        self.assertEqual(status, 503)
        self.assertEqual(json.loads(body)['error']['code'], 'transport_recovering')
        self.assertEqual(headers['retry-after'], '2')
        self.assertGreater(elapsed, 1)
        self.assertLess(elapsed, 3)

    def test_received_post_is_never_replayed(self):
        status, _, _ = self.request('POST', '/abort-after-receive', b'non-idempotent')
        self.assertEqual(status, 502)
        self.assertEqual(self.primary.posts, [b'non-idempotent'])
        self.assertEqual(self.backup.posts, [])

    def test_application_unready_does_not_mark_transport_down(self):
        self.primary.application_ready = False
        time.sleep(.3)
        self.assertEqual(self.stats()['primary'], 'UP')
        self.assertEqual(self.request()[1], b'primary')


if __name__ == '__main__':
    unittest.main(verbosity=2)
