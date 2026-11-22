"""Metadata reuse must never reuse source surfaces or a changed compiler context."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('metadata_surface', ROOT / 'scripts/deinit_surface.py')
surface = importlib.util.module_from_spec(spec)
spec.loader.exec_module(surface)


class ToolchainMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.compiler = self.root / 'toolchain/usr/bin/swiftc'
        self.compiler.parent.mkdir(parents=True)
        self.compiler.write_text('compiler one')
        self.compiler.chmod(0o755)
        self.selected = self.compiler
        self.source = self.root / 'scripts/isolated-deinit-surface.swift'
        self.source.parent.mkdir()
        self.source.write_text('unchanged scanner source')
        self.fixture = self.root / 'Fixture.swift'
        self.fixture.write_text('first fixture input')
        self.calls = []
        self.fail_version = False
        self.fail_sdk = False
        surface._compiler_version.cache_clear()
        self.output = mock.patch.object(surface.subprocess, 'check_output', side_effect=self.query)
        self.compile = mock.patch.object(surface.subprocess, 'run', side_effect=self.build)
        self.output.start(); self.compile.start()

    def tearDown(self):
        self.output.stop(); self.compile.stop()
        surface._compiler_version.cache_clear()
        self.directory.cleanup()

    def query(self, args, **kwargs):
        if args == ['xcrun', '--find', 'swiftc']:
            self.calls.append('find')
            return str(self.selected) + '\n'
        if args == [str(self.selected), '--version']:
            self.calls.append('version')
            if self.fail_version:
                raise subprocess.CalledProcessError(9, args)
            return ('version of ' + self.selected.read_text()).encode()
        if args == ['xcrun', '--sdk', 'macosx', '--show-sdk-path']:
            self.calls.append('sdk')
            if self.fail_sdk:
                raise subprocess.CalledProcessError(9, args)
            return str(self.root / 'sdk') + '\n'
        if Path(args[0]).name.startswith('surface-'):
            self.calls.append('scanner')
            # Deliberately fresh input observation, not a simulated Swift parser.
            return json.dumps({path: {'fresh_input': Path(path).read_text()} for path in args[1:]}).encode()
        raise AssertionError(args)

    def build(self, args, **kwargs):
        self.assertEqual(args[0], str(self.selected))
        self.assertTrue(kwargs['check'])
        self.calls.append('compile')
        Path(args[args.index('-o') + 1]).write_text('fake scanner executable')

    def extract(self):
        return surface.extract(self.root, ['Fixture.swift'])

    def test_warm_metadata_keeps_every_input_and_scanner_invocation_fresh(self):
        first = self.extract()
        self.fixture.write_text('second fixture input')
        second = self.extract()
        self.assertNotEqual(first, second)
        self.assertEqual(second['Fixture.swift']['fresh_input'], 'second fixture input')
        self.assertEqual(self.calls.count('find'), 2)
        self.assertEqual(self.calls.count('version'), 1)
        self.assertEqual(self.calls.count('sdk'), 1)
        self.assertEqual(self.calls.count('compile'), 1)
        self.assertEqual(self.calls.count('scanner'), 2)

    def test_replacement_selection_and_scanner_source_changes_miss_the_right_cache(self):
        self.extract()
        replacement = self.compiler.with_suffix('.replacement')
        replacement.write_text('compiler two')
        replacement.chmod(0o755)
        os.replace(replacement, self.compiler)
        self.extract()
        other = self.root / 'other/usr/bin/swiftc'
        other.parent.mkdir(parents=True)
        other.write_text('compiler three')
        self.selected = other
        self.extract()
        self.source.write_text('changed scanner source')
        self.extract()
        self.assertEqual(self.calls.count('version'), 3)
        self.assertEqual(self.calls.count('compile'), 4)
        self.assertEqual(self.calls.count('sdk'), 4)
        self.assertEqual(self.calls.count('scanner'), 4)

    def test_selection_environment_changes_do_not_borrow_cached_version_or_binary(self):
        self.extract()
        for key in ('DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS', 'PATH'):
            with mock.patch.dict(os.environ, {key: 'different selection context'}):
                self.extract()
        self.assertEqual(self.calls.count('version'), 5)
        self.assertEqual(self.calls.count('compile'), 5)
        self.assertEqual(self.calls.count('scanner'), 5)

    def test_failed_version_is_not_cached_and_never_runs_scanner(self):
        self.fail_version = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.extract()
        self.assertNotIn('scanner', self.calls)
        self.fail_version = False
        self.extract()
        self.extract()
        self.assertEqual(self.calls.count('version'), 2)
        self.assertEqual(self.calls.count('scanner'), 2)

    def test_failed_compile_sdk_lookup_remains_a_cold_miss(self):
        self.fail_sdk = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.extract()
        self.assertNotIn('scanner', self.calls)
        self.fail_sdk = False
        self.extract()
        self.assertEqual(self.calls.count('version'), 1)
        self.assertEqual(self.calls.count('sdk'), 2)
        self.assertEqual(self.calls.count('compile'), 1)
        self.assertEqual(self.calls.count('scanner'), 1)


if __name__ == '__main__':
    unittest.main()
