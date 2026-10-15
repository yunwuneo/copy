#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/work/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/work/module-cache"
swift build --disable-sandbox --scratch-path work/build -Xswiftc -module-cache-path -Xswiftc "$PWD/work/module-cache" --product CopyMac
copy_bin_dir=$(swift build --disable-sandbox --scratch-path work/build --show-bin-path)
copy_bundle="$PWD/work/Copy.app"
if [[ "${1:-}" == "--ui-test" ]]; then
  copy_bundle="$PWD/work/Copy UI Test.app"
fi
mkdir -p "$copy_bundle/Contents/MacOS" "$copy_bundle/Contents/Resources"
cp "$copy_bin_dir/CopyMac" "$copy_bundle/Contents/MacOS/CopyMac"
cp Apps/CopyMac/Info.plist "$copy_bundle/Contents/Info.plist"
cp Apps/CopyMac/PrivacyInfo.xcprivacy "$copy_bundle/Contents/Resources/PrivacyInfo.xcprivacy"
./scripts/extract-intents.sh "$copy_bundle/Contents/Resources"
if [[ "${1:-}" == "--ui-test" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.neo.Copy.UITest" "$copy_bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Copy UI Test" "$copy_bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Copy UI Test" "$copy_bundle/Contents/Info.plist"
fi
/usr/bin/codesign --force --sign - "$copy_bundle"
/usr/bin/codesign --verify --strict "$copy_bundle"
/usr/bin/plutil -lint "$copy_bundle/Contents/Info.plist"
print "$copy_bundle"
