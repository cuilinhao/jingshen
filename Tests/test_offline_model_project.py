"""Delivery/regression checks on real files. No network, no Apple SDK claimed."""
from pathlib import Path
import hashlib,json,re,unittest
ROOT=Path(__file__).resolve().parents[1]
class OfflineDeliveryTests(unittest.TestCase):
 def test_uploaded_full_weights_are_present(self):
  base=ROOT/'PGYDepthDemo/Resources/Models/DepthAnythingV2SmallF16.mlpackage'
  for rel,size,sha in [('Data/com.apple.CoreML/model.mlmodel',399433,'44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042'),('Data/com.apple.CoreML/weights/weight.bin',49419072,'fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed')]:
   data=(base/rel).read_bytes();self.assertEqual(len(data),size);self.assertEqual(hashlib.sha256(data).hexdigest(),sha)
  manifest=json.loads((base/'Manifest.json').read_text());self.assertIn(manifest['rootModelIdentifier'],manifest['itemInfoEntries'])
 def test_ordinary_import_runs_depth_inference_not_blank_labels(self):
  code=(ROOT/'PGYDepthDemo/Imaging/PhotoPipeline.swift').read_text()
  self.assertIn('depthEstimator.estimate',code)
  self.assertNotIn('SceneLayerMap.blank',code)
  self.assertNotIn('try analyzeLayers',code)
 def test_sample_uses_same_import_as_user_photo(self):
  code=(ROOT/'PGYDepthDemo/State/EditorModel.swift').read_text()
  self.assertNotIn('pipeline.loadReference()',code)
  self.assertNotIn('referenceData?.analysis',code)
  self.assertIn('自动深度',code)
 def test_no_download_stage_or_runtime_network(self):
  pbx=(ROOT/'PGYDepthDemo.xcodeproj/project.pbxproj').read_text()
  self.assertNotIn('PBXShellScriptBuildPhase',pbx)
  self.assertNotIn('XCRemoteSwiftPackageReference',pbx)
  code='\n'.join(p.read_text() for p in (ROOT/'PGYDepthDemo').rglob('*.swift'))
  for s in ['URLSession','https://huggingface','MLModel.compileModel']:
   self.assertNotIn(s,code)
 def test_compiled_bundle_model_load_is_implemented(self):
  code=(ROOT/'PGYDepthDemo/Imaging/OfflineDepthEstimator.swift').read_text()
  self.assertIn('withExtension: "mlmodelc"',code)
  self.assertIn('prediction(from:',code)
  self.assertIn('MLFeatureValue(pixelBuffer:',code)
 def test_model_is_a_native_xcode_source_not_raw_copy(self):
  pbx=(ROOT/'PGYDepthDemo.xcodeproj/project.pbxproj').read_text()
  self.assertIn('DepthAnythingV2SmallF16.mlpackage',pbx)
  self.assertIn('folder.mlpackage',pbx)
if __name__=='__main__':unittest.main()
