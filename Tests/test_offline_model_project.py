"""Checks real bundled bytes and project configuration; does not claim Apple runtime validation."""
from pathlib import Path
import hashlib
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODEL_ROOT = ROOT / 'PGYDepthDemo/Resources/Models'

# Independently pinned delivery identities: changing ModelInfo alone cannot bless different weights.
PINNED = {
    'DepthAnythingV3_base_504.mlpackage': {
        'Data/com.apple.CoreML/model.mlmodel': (317533, '1e7e0943bae1c2cd8c58c6d8968f57f7a451b34f152104f80101f1aea535c233'),
        'Data/com.apple.CoreML/weights/weight.bin': (233223744, '7823e9552eef8dff710bb9c51f7b5b7cdbc4c7bd7e06b1a434369f5e8bef1c8b'),
        'Manifest.json': (617, '20b752a53baf0102afce370e2b39288a8d98ebe24c095e987e90fc61542e58a7'),
    },
    'DepthAnythingV2SmallF16.mlpackage': {
        'Data/com.apple.CoreML/model.mlmodel': (399433, '44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042'),
        'Data/com.apple.CoreML/weights/weight.bin': (49419072, 'fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed'),
        'Manifest.json': (617, '2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7'),
    },
}


class OfflineDeliveryTests(unittest.TestCase):
    def test_both_full_model_packages_and_manifest_references_are_present(self):
        for name, files in PINNED.items():
            base = MODEL_ROOT / name
            with self.subTest(package=name):
                self.assertEqual({str(p.relative_to(base)) for p in base.rglob('*') if p.is_file()}, set(files))
                for rel, (size, sha) in files.items():
                    path = base / rel
                    self.assertEqual(path.stat().st_size, size, rel)
                    digest = hashlib.sha256()
                    with path.open('rb') as stream:
                        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                            digest.update(chunk)
                    self.assertEqual(digest.hexdigest(), sha, rel)
                manifest = json.loads((base / 'Manifest.json').read_text())
                entries = manifest['itemInfoEntries']
                self.assertEqual(entries[manifest['rootModelIdentifier']]['path'], 'com.apple.CoreML/model.mlmodel')
                for entry in entries.values():
                    target = base / 'Data' / entry['path']
                    self.assertTrue(target.resolve().is_relative_to(base.resolve()))
                    self.assertTrue(target.exists(), entry['path'])

    def test_model_info_matches_pinned_deliveries(self):
        info = json.loads((ROOT / 'PGYDepthDemo/Resources/ModelInfo.json').read_text())
        self.assertEqual(info['package'], 'DepthAnythingV3_base_504.mlpackage')
        self.assertEqual(info['revision'], 'a3d12de43e1b6131cd05cdd9027e0c4978d436e5')
        self.assertEqual(info['archiveSHA256'], 'cd96d12b7d14fb92c312ad1efe771eb1732680578e11bf6b76ab63f4c5d6c51b')
        comparison = info['comparisonModel']
        self.assertEqual(comparison['package'], 'DepthAnythingV2SmallF16.mlpackage')
        for metadata, entries in [(info, info['files']),
                                  (comparison, [comparison[k] for k in ('model', 'weights', 'manifest')])]:
            actual = {entry['path']: (entry['bytes'], entry['sha256']) for entry in entries}
            self.assertEqual(actual, PINNED[metadata['package']])
            self.assertEqual(metadata['totalBytes'], sum(size for size, _ in actual.values()))
        self.assertEqual(info['actualInterface']['input']['width'], 504)
        self.assertEqual(info['actualInterface']['input']['height'], 504)
        for name in ('depth', 'confidence'):
            self.assertEqual(info['actualInterface']['outputs'][name]['shape'], [1, 504, 504])

    def test_ordinary_import_runs_depth_inference_not_blank_labels(self):
        code = (ROOT / 'PGYDepthDemo/Imaging/PhotoPipeline.swift').read_text()
        self.assertIn('depthEstimator.estimate', code)
        self.assertNotIn('SceneLayerMap.blank', code)
        self.assertNotIn('try analyzeLayers', code)

    def test_sample_uses_same_import_as_user_photo(self):
        code = (ROOT / 'PGYDepthDemo/State/EditorModel.swift').read_text()
        self.assertNotIn('pipeline.loadReference()', code)
        self.assertNotIn('referenceData?.analysis', code)
        self.assertIn('自动深度', code)

    def test_no_download_stage_or_runtime_network(self):
        pbx = (ROOT / 'PGYDepthDemo.xcodeproj/project.pbxproj').read_text()
        self.assertNotIn('PBXShellScriptBuildPhase', pbx)
        self.assertNotIn('XCRemoteSwiftPackageReference', pbx)
        code = '\n'.join(p.read_text() for p in (ROOT / 'PGYDepthDemo').rglob('*.swift'))
        for value in ['URLSession', 'https://huggingface', 'MLModel.compileModel']:
            self.assertNotIn(value, code)

    def test_compiled_bundle_model_load_is_implemented(self):
        code = (ROOT / 'PGYDepthDemo/Imaging/OfflineDepthEstimator.swift').read_text()
        self.assertIn('withExtension: "mlmodelc"', code)
        self.assertIn('prediction(from:', code)
        self.assertIn('MLFeatureValue(pixelBuffer:', code)
        self.assertIn('modelChoice.resourceName', code)

    def test_models_are_native_xcode_sources_not_raw_copies(self):
        pbx = (ROOT / 'PGYDepthDemo.xcodeproj/project.pbxproj').read_text()
        for name in PINNED:
            self.assertIn(name, pbx)
        self.assertIn('folder.mlpackage', pbx)
        # Exact target/phase membership and duplicate detection live in validate_project.py.


if __name__ == '__main__':
    unittest.main()
