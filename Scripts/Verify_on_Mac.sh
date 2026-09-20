#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: 此脚本需要安装完整 Xcode 的 Mac。" >&2
  exit 1
fi
mkdir -p Verification
xcodebuild -version
xcodebuild -project PGYDepthDemo.xcodeproj -scheme PGYDepthDemo \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .DerivedData CODE_SIGNING_ALLOWED=NO build \
  2>&1 | tee Verification/mac-build.log
printf '\n编译命令已成功结束。接下来在 Xcode 选模拟器或真机运行，并按 Docs/TEST_PLAN.md 验收。\n'
