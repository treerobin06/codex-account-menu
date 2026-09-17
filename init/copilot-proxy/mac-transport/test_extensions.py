"""Exercise the real runtime API while established WebSockets remain open."""
import importlib.util
import os
from unittest.mock import patch
from pathlib import Path
import unittest
import extend_paths as extend
import test_transport as transport

spec = importlib.util.spec_from_file_location('native_ssh', Path(__file__).with_name('native-ssh.py'))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class RuntimeExtensionTests(unittest.TestCase):
    def setUp(self):
        self.rig = transport.TransportTests()
        self.rig.setUp()

    def tearDown(self):
        self.rig.tearDown()

    def test_dynamic_backups_failover_without_process_or_stream_restart(self):
        direct, jump = transport.Fixture('direct'), transport.Fixture('jump')
        try:
            original_pid = self.rig.process.pid
            original_ws = self.rig.websocket()
            self.assertEqual(self.rig.ws_echo(original_ws), b'primary:hello')
            for name, fixture in [('direct', direct), ('jump', jump)]:
                extend.add_path(name, fixture.server_port, self.rig.control, interval='100ms', rise=1, fall=1)
                self.rig.wait_state(name, 'UP')
            self.assertEqual(self.rig.process.pid, original_pid)
            self.assertIsNone(self.rig.process.poll())
            self.assertEqual(self.rig.ws_echo(original_ws), b'primary:hello')
            self.rig.primary.available = self.rig.backup.available = False
            self.rig.wait_state('primary', 'DOWN')
            self.rig.wait_state('backup', 'DOWN')
            self.assertEqual(self.rig.request()[1], b'direct')
            direct.available = False
            self.rig.wait_state('direct', 'DOWN')
            self.assertEqual(self.rig.request()[1], b'jump')
            jump_ws = self.rig.websocket()
            self.assertEqual(self.rig.ws_echo(jump_ws), b'jump:hello')
            with self.assertRaisesRegex(RuntimeError, 'draining'):
                extend.remove_path('jump', self.rig.control)
            self.assertEqual(self.rig.ws_echo(jump_ws), b'jump:hello')
            self.rig.primary.available = True
            self.rig.wait_state('primary', 'UP')
            self.assertEqual(self.rig.request()[1], b'primary')
            self.assertEqual(self.rig.ws_echo(original_ws), b'primary:hello')
            self.assertEqual(self.rig.ws_echo(jump_ws), b'jump:hello')
            jump_ws.close()
            # The core integration teardown owns all remaining fixture streams.
        finally:
            for connection in self.rig.sockets:
                connection.close()
            direct.finish()
            jump.finish()

    def test_runtime_remove_idle_backup_and_reject_duplicate(self):
        fixture = transport.Fixture('direct')
        try:
            extend.add_path('direct', fixture.server_port, self.rig.control, interval='100ms', rise=1, fall=1)
            self.rig.wait_state('direct', 'UP')
            with self.assertRaisesRegex(RuntimeError, 'already exists'):
                extend.add_path('direct', fixture.server_port, self.rig.control)
            extend.remove_path('direct', self.rig.control)
            self.assertNotIn('direct', self.rig.stats())
            self.assertEqual(self.rig.request()[1], b'primary')
        finally:
            fixture.finish()


class NativeCommandTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {
            'COPILOT_DIRECT_HOST': '192.0.2.10', 'COPILOT_DIRECT_PORT': '18050',
            'COPILOT_JUMP_HOST': '198.51.100.20', 'COPILOT_JUMP_PORT': '22',
            'COPILOT_PRIMARY_HOST': '192.0.2.20', 'COPILOT_PRIMARY_PORT': '22',
            'COPILOT_BACKUP_HOST': '198.51.100.30', 'COPILOT_BACKUP_PORT': '2222',
            'COPILOT_SSH_USER': 'test-user',
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_missing_endpoint_fails_before_network_or_process_access(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(native, 'output') as output:
            with self.assertRaisesRegex(ValueError, 'COPILOT_DIRECT_HOST'):
                native.command('direct', 'en0', '192.0.2.100')
            with self.assertRaisesRegex(RuntimeError, 'COPILOT_PRIMARY_HOST'):
                transport.link.transport_ssh_configuration()
            output.assert_not_called()

    def test_explicit_endpoints_keep_host_key_checks_and_one_server_alias(self):
        config, backup, port = transport.link.transport_ssh_configuration()
        self.assertIn('Host copilot-server\n', config)
        self.assertIn('HostKeyAlias copilot-server\n', config)
        self.assertIn('StrictHostKeyChecking yes', config)
        self.assertIn('ForwardAgent no', config)
        self.assertIn('User test-user\n', config)
        self.assertEqual((backup, port), ('198.51.100.30', 2222))
        self.assertEqual(native.command('direct', 'en0', '192.0.2.100')[-1], 'copilot-server')
        self.assertEqual(native.configuration_environment()['COPILOT_JUMP_HOST'], '198.51.100.20')
        with patch.dict(os.environ, {'COPILOT_PRIMARY_HOST': '192.0.2.1\nProxyCommand unsafe'}):
            with self.assertRaises(ValueError):
                transport.link.transport_ssh_configuration()

    def test_rollback_requires_a_verified_original_route(self):
        rows = {'primary': {'status': 'UP'}, 'backup': {'status': 'DOWN'}}
        self.assertFalse(extend.original_paths_ready(rows, lambda *a, **kw: {'data': []}))
        self.assertTrue(extend.original_paths_ready(rows, lambda *a, **kw: {'data': [{'id': 'fixture'}]}))
        def forbidden(*a, **kw):
            self.fail('A DOWN original route must not authorize withdrawing backups')
        self.assertFalse(extend.original_paths_ready({'primary': {'status': 'DOWN'}}, forbidden))

    def test_preview_or_uncommitted_gateway_cannot_be_extended_as_production(self):
        extend.require_production({'mode': 'production'}, '    bind 127.0.0.1:4141\n')
        for mode, port in [('preview', 4141), ('provisional', 4141), ('production', 4143)]:
            with self.assertRaises(RuntimeError):
                extend.require_production({'mode': mode}, '    bind 127.0.0.1:%d\n' % port)

    def test_direct_binds_interface_and_dhcp_source_with_existing_host_identity(self):
        args = native.command('direct', 'en5', '192.0.2.100')
        self.assertEqual(args[args.index('-B') + 1], 'en5')
        self.assertEqual(args[args.index('-b') + 1], '192.0.2.100')
        self.assertIn('HostName=192.0.2.10', args)
        self.assertIn('StrictHostKeyChecking=yes', args)
        self.assertIn('127.0.0.1:14143:/run/tree-copilot-proxy/http.sock', args)
        with self.assertRaises(ValueError):
            native.command('direct', 'utun4', '192.0.2.101')

    def test_jump_jump_keeps_existing_separate_identity_and_no_agent_forwarding(self):
        args = native.command('jump-host', 'en0', '198.51.100.100')
        self.assertEqual(args[args.index('-W') + 1], '192.0.2.10:18050')
        self.assertEqual(args[-1], 'copilot-jump')
        self.assertIn('HostName=198.51.100.20', args)
        self.assertIn('ForwardAgent=no', args)
        outer = native.command('jump')
        self.assertIn('127.0.0.1:14144:/run/tree-copilot-proxy/http.sock', outer)
        self.assertTrue(any('native-ssh.py jump-host' in arg for arg in outer))


if __name__ == '__main__':
    unittest.main(verbosity=2)
