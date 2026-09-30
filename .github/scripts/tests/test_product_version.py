import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'product-version.py'
SPEC = importlib.util.spec_from_file_location('product_version', SCRIPT)
PRODUCT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCT)


class ProductVersionTests(unittest.TestCase):
    def test_accepts_plain_quoted_and_commented_numeric_versions(self):
        for scalar in ('1.1.0+3', "'1.1.0+3'", '"1.1.0+3"', '1.1.0+3 # release'):
            with self.subTest(scalar=scalar):
                self.assertEqual(PRODUCT.product_version('name: nikodesk\nversion: ' + scalar),
                                 {'version_name': '1.1.0', 'build_number': 3})

    def test_accepts_windows_component_and_build_boundaries(self):
        self.assertEqual(PRODUCT.product_version('version: 0.0.0+1')['build_number'], 1)
        self.assertEqual(PRODUCT.product_version('version: 65535.65535.65535+65535'),
                         {'version_name': '65535.65535.65535', 'build_number': 65535})

    def test_rejects_missing_duplicate_and_nested_declarations(self):
        for text in ('name: nikodesk', '# version: 1.1.0+3', '  version: 1.1.0+3',
                     'version: 1.1.0+3\nversion : 1.2.0+4'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                PRODUCT.product_version(text)

    def test_rejects_unknown_noncanonical_or_injectable_values(self):
        for scalar in ('', 'null', '*version', '|', '1.1.0', '1.1.0+0', '01.1.0+3',
                       '1.1.0+03', '1.1.0+-1', '1.1.0+3.4', '1.1.0-rc.1+3',
                       '١.1.0+3', '1.1.0+3; echo unsafe', '"1.1.0+3', '"1.1.0+3" extra'):
            with self.subTest(scalar=scalar), self.assertRaises(ValueError):
                PRODUCT.product_version('version: ' + scalar)

    def test_rejects_each_windows_16_bit_overflow(self):
        for scalar in ('65536.1.0+3', '1.65536.0+3', '1.1.65536+3', '1.1.0+65536',
                       '1.1.0+999999999999999999999999'):
            with self.subTest(scalar=scalar), self.assertRaises(ValueError):
                PRODUCT.product_version('version: ' + scalar)

    def test_job_output_appends_only_validated_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            output.write_text('existing=value\n', encoding='utf-8')
            environment = {'GITHUB_ACTIONS': 'true', 'GITHUB_REF_TYPE': 'branch',
                           'GITHUB_OUTPUT': str(output)}
            PRODUCT.write_github_output(PRODUCT.product_version('version: 1.1.0+3'), environment)
            self.assertEqual(output.read_text(encoding='utf-8'),
                             'existing=value\nversion_name=1.1.0\nbuild_number=3\n')

    def test_output_requires_normal_job_and_existing_regular_file(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            output.write_text('unchanged\n', encoding='utf-8')
            valid = {'GITHUB_ACTIONS': 'true', 'GITHUB_REF_TYPE': 'branch', 'GITHUB_OUTPUT': str(output)}
            for change in ({'GITHUB_ACTIONS': 'false'}, {'GITHUB_REF_TYPE': 'unknown'},
                           {'GITHUB_OUTPUT': ''}, {'GITHUB_OUTPUT': directory},
                           {'GITHUB_OUTPUT': str(Path(directory) / 'missing')}, {'GITHUB_OUTPUT': 'output'}):
                with self.subTest(change=change), self.assertRaises(ValueError):
                    PRODUCT.write_github_output(PRODUCT.product_version('version: 1.1.0+3'),
                                                dict(valid, **change))
            self.assertEqual(output.read_text(encoding='utf-8'), 'unchanged\n')

    def test_release_tag_is_a_check_and_never_a_version_override(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            output.touch()
            environment = {'GITHUB_ACTIONS': 'true', 'GITHUB_REF_TYPE': 'tag', 'GITHUB_OUTPUT': str(output)}
            version = PRODUCT.product_version('version: 1.1.0+3')
            for tag in ('v1.1.0+3', 'v1.2.0', '1.1.0', '', 'v1.1.0\nother=value'):
                with self.subTest(tag=tag), self.assertRaises(ValueError):
                    PRODUCT.write_github_output(version, dict(environment, GITHUB_REF_NAME=tag))
            self.assertEqual(output.read_text(encoding='utf-8'), '')
            PRODUCT.write_github_output(version, dict(environment, GITHUB_REF_NAME='v1.1.0'))
            self.assertEqual(output.read_text(encoding='utf-8'), 'version_name=1.1.0\nbuild_number=3\n')

    def test_cli_reads_actual_source_from_an_unrelated_working_directory(self):
        expected = PRODUCT.product_version(PRODUCT.PUBSPEC.read_text(encoding='utf-8'))
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(SCRIPT)], cwd=directory,
                                    capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout), expected)

    def test_cli_writes_actual_source_to_an_isolated_job_output(self):
        expected = PRODUCT.product_version(PRODUCT.PUBSPEC.read_text(encoding='utf-8'))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            output.touch()
            environment = dict(os.environ, GITHUB_ACTIONS='true', GITHUB_REF_TYPE='tag',
                               GITHUB_REF_NAME='v' + expected['version_name'], GITHUB_OUTPUT=str(output))
            result = subprocess.run([sys.executable, str(SCRIPT), '--github-output'],
                                    cwd=directory, env=environment, capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), expected)
            self.assertEqual(output.read_text(encoding='utf-8'),
                             'version_name={}\nbuild_number={}\n'.format(
                                 expected['version_name'], expected['build_number']))

    def test_cli_fails_before_writing_output_for_invalid_source(self):
        with tempfile.TemporaryDirectory() as directory:
            pubspec = Path(directory) / 'pubspec.yaml'
            pubspec.write_text('version: 1.1.0+65536\n', encoding='utf-8')
            output = Path(directory) / 'output'
            output.write_text('unchanged\n', encoding='utf-8')
            environment = dict(os.environ, GITHUB_ACTIONS='true', GITHUB_REF_TYPE='branch',
                               GITHUB_OUTPUT=str(output))
            result = subprocess.run([sys.executable, str(SCRIPT), '--pubspec', str(pubspec), '--github-output'],
                                    env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, '')
            self.assertEqual(output.read_text(encoding='utf-8'), 'unchanged\n')

    def test_cli_reports_missing_source_and_output_write_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(SCRIPT), '--pubspec', str(Path(directory) / 'missing')],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Product version error:', result.stderr)
        with patch.object(Path, 'open', side_effect=OSError('injected write failure')):
            with self.assertRaises(OSError):
                PRODUCT.write_github_output({'version_name': '1.1.0', 'build_number': 3},
                                           {'GITHUB_ACTIONS': 'true', 'GITHUB_REF_TYPE': 'branch',
                                            'GITHUB_OUTPUT': str(SCRIPT)})


if __name__ == '__main__':
    unittest.main()
