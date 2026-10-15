#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/work/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/work/module-cache"
mkdir -p work
swift test --disable-sandbox --scratch-path work/build -Xswiftc -module-cache-path -Xswiftc "$PWD/work/module-cache" "$@"
