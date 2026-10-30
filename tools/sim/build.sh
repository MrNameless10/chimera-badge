#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
os="${SOLANA_OS:-$here/.solana-os}"
if [ ! -d "$os" ]; then
    git clone -q https://github.com/spacemandev-git/solana-os.git "$os"
fi
vendor="$os/main/lua/vendor"
out="$here/.build"
mkdir -p "$out"
cp "$os/main/lua/lua_json.c" "$out/lua_json.c"
srcs=()
for f in lapi lauxlib lbaselib lcode lcorolib lctype ldebug ldo ldump lfunc lgc llex lmathlib lmem lobject \
         lopcodes lparser lstate lstring lstrlib ltable ltablib ltm lundump lutf8lib lvm lzio; do
    srcs+=("$vendor/$f.c")
done
zig cc -target wasm32-wasi -mcpu=generic+exception_handling -mllvm -wasm-enable-sjlj -O2 -w -D_WASI_EMULATED_SIGNAL \
    -I"$here/shim" -I"$vendor" "${srcs[@]}" "$out/lua_json.c" "$here/sim.c" "$here/shim/tag.s" \
    -lsetjmp -lwasi-emulated-signal -o "$out/badgesim.wasm"
echo "$out/badgesim.wasm"
