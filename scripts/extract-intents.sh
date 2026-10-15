#!/bin/zsh
set -eu
cd "${0:A:h:h}"
copy_destination="$1"
copy_sdk=$(xcrun --show-sdk-path)
copy_toolchain=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
copy_xcode_version=$(xcodebuild -version | awk '/Build version/ {print $3}')
copy_arch=$(uname -m)
mkdir -p work/metadata
python3 - "$copy_arch" <<'PY'
from pathlib import Path
import sys
root=Path.cwd()
sources=sorted((root/'Apps/CopyMac').glob('*.swift'))
Path('work/metadata/sources.list').write_text('\n'.join(str(p) for p in sources)+'\n')
base=root/'work/build/out/Intermediates.noindex/Copy.build/Debug/CopyMac-p.build/Objects-normal'/sys.argv[1]
files=sorted(base.glob('*.swiftconstvalues'))
if not files:
    raise SystemExit('Missing Swift constant metadata; build CopyMac with the installed Xcode SwiftPM build system first.')
Path('work/metadata/constants.list').write_text('\n'.join(str(p) for p in files)+'\n')
PY
xcrun appintentsmetadataprocessor --output "$copy_destination" --toolchain-dir "$copy_toolchain" --module-name CopyMac --sdk-root "$copy_sdk" --xcode-version "$copy_xcode_version" --platform-family macOS --deployment-target 14.0 --target-triple "${copy_arch}-apple-macos14.0" --source-file-list "$PWD/work/metadata/sources.list" --swift-const-vals-list "$PWD/work/metadata/constants.list" --force
