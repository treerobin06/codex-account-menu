import importlib.util
from pathlib import Path
import socketserver
import threading
import unittest

spec = importlib.util.spec_from_file_location('doctor', Path(__file__).with_name('copilot-doctor.py'))
doctor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(doctor)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.recv(4096)
        self.request.sendall(self.server.reply)


class DoctorTests(unittest.TestCase):
    def test_network_budget_and_complete_program_version_are_distinct(self):
        self.assertTrue(doctor.timeout_policy_ready({'transportVersion': 2, 'httpIdleTimeoutMs': 600000}))
        self.assertTrue(doctor.timeout_policy_ready({'httpIdleTimeoutMs': 600000, 'networkPolicy': {'active': True}}))
        self.assertFalse(doctor.timeout_policy_ready({'httpIdleTimeoutMs': 600000, 'networkPolicy': {'active': False}}))
        self.assertFalse(doctor.timeout_policy_ready({'httpIdleTimeoutMs': 120000}))

    def probe(self, reply, path='/v1/models'):
        with socketserver.TCPServer(('127.0.0.1', 0), Handler) as server:
            server.reply = reply
            worker = threading.Thread(target=server.handle_request)
            worker.start()
            try:
                return doctor.fetch(server.server_address[1], path)
            finally:
                worker.join(timeout=3)

    def http(self, body, status=200):
        return ('HTTP/1.1 %d Test\r\nContent-Length: %d\r\nConnection: close\r\n\r\n' %
                (status, len(body))).encode() + body

    def test_model_catalog_requires_real_nonempty_model_ids(self):
        self.assertFalse(self.probe(self.http(b'{"data":[]}'))['valid'])
        self.assertFalse(self.probe(self.http(b'{"data":[{"name":"not-an-id"}]}'))['valid'])
        result = self.probe(self.http(b'{"data":[{"id":"fixture"}]}'))
        self.assertTrue(result['valid'])
        self.assertEqual(result['models'], 1)

    def test_malformed_http_and_json_become_layer_failures(self):
        bad_http = self.probe(b'not HTTP\r\n\r\n')
        self.assertFalse(bad_http['valid'])
        self.assertEqual(bad_http['error'], 'BadStatusLine')
        self.assertFalse(self.probe(self.http(b'[]'))['valid'])
        self.assertFalse(self.probe(self.http(b'incomplete-json'))['valid'])

    def test_application_unready_is_distinct_from_a_broken_socket(self):
        result = self.probe(self.http(b'{"status":"not_ready"}', 503), '/readyz')
        self.assertFalse(result['valid'])
        self.assertEqual(result['http'], 503)
        self.assertEqual(result['status'], 'not_ready')
        self.assertNotIn('error', result)


if __name__ == '__main__':
    unittest.main(verbosity=2)
