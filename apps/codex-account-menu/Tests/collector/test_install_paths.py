#!/usr/bin/env python3
"""Installer path/backup regression in temporary homes; never installs a real app.

The fixture substitutes signature and process checks, so this validates path
selection and transaction behavior only, not Apple signing or GUI lifecycle.
"""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/install-app.sh"


@unittest.skipUnless(sys.platform == "darwin", "macOS installer fixture")
class InstallerPathTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="codex-installer-fixture-")
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "Fixture User"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("codesign", "ps"):
            stub = self.bin / name
            stub.write_text("#!/bin/sh\nexit 0\n")
            stub.chmod(0o700)
        self.candidate = self.root / "Candidate.app"
        contents = self.candidate / "Contents"
        resources = contents / "Resources/CodexAccountMenu_SwitcherCore.bundle"
        resources.mkdir(parents=True)
        (resources / "copilot-status.py").write_text("# fixture only\n")
        for relative in ("MacOS/CodexAccountMenu", "Helpers/codex-menu"):
            program = contents / relative
            program.parent.mkdir(exist_ok=True)
            program.write_text("fixture-one\n")
            program.chmod(0o700)
        with (contents / "Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": "com.tree.codex-account-menu",
                          "CFBundleExecutable": "CodexAccountMenu", "CFBundlePackageType": "APPL",
                          "LSUIElement": True, "CodexAccountMenuDemo": False,
                          "CodexAccountMenuResourceBundle": "CodexAccountMenu_SwitcherCore.bundle"}, output)
        self.destination = self.home / "Applications/Codex Account Menu.app"
        self.storage = self.home / "Library/Application Support/Codex Account Menu"

    def tearDown(self):
        self.temporary.cleanup()

    def run_installer(self, *, check=False, home=None):
        environment = dict(os.environ, HOME=str(home or self.home), PATH=str(self.bin) + ":" + os.environ["PATH"])
        arguments = ["/bin/bash", str(SCRIPT), "--app", str(self.candidate)]
        if check:
            arguments.append("--check")
        return subprocess.run(arguments, env=environment, capture_output=True, text=True, timeout=15)

    def test_check_uses_selected_home_and_writes_nothing(self):
        before = set(self.root.rglob("*"))
        result = self.run_installer(check=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.destination), result.stdout)
        self.assertIn(str(self.storage / "app-backups"), result.stdout)
        self.assertEqual(set(self.root.rglob("*")), before)

    def test_symlink_home_is_rejected_without_writes(self):
        alias = self.root / "home-alias"
        alias.symlink_to(self.home, target_is_directory=True)
        result = self.run_installer(check=True, home=alias)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.destination.exists())
        self.assertFalse(self.storage.exists())

    def test_fixture_install_keeps_backups_and_respects_existing_lock(self):
        first = self.run_installer()
        self.assertEqual(first.returncode, 0, first.stderr)
        installed = self.destination / "Contents/MacOS/CodexAccountMenu"
        self.assertEqual(installed.read_text(), "fixture-one\n")
        (self.candidate / "Contents/MacOS/CodexAccountMenu").write_text("fixture-two\n")
        second = self.run_installer()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(installed.read_text(), "fixture-two\n")
        backups = list((self.storage / "app-backups").glob("*/Codex Account Menu.app"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "Contents/MacOS/CodexAccountMenu").read_text(), "fixture-one\n")
        install_lock = self.storage / ".app-install-lock"
        self.assertFalse(install_lock.exists())
        install_lock.mkdir()
        third = self.run_installer()
        self.assertNotEqual(third.returncode, 0)
        self.assertTrue(install_lock.is_dir())
        self.assertEqual(installed.read_text(), "fixture-two\n")


if __name__ == "__main__":
    unittest.main()
