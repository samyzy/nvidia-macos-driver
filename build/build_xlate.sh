#!/bin/bash
set -u
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
HERE=$(cd "$(dirname "$0")/.." && pwd)
N=${N:-$HOME/nvmtl-build}
if [ -d "$HERE/translator" ] && [ ! -d "$N/bindless" ]; then
  X="${X:-$HERE/translator}"
  O="${O:-$HERE/build-out/xlate}"
  L="${L:-$HERE/build-out/.xlate.lock}"
else
  X="${X:-$N/bindless}"
  C=$(git -C "$X" rev-parse --short HEAD 2>/dev/null || echo "head")
  O="${O:-$N/LIVE/out/xlate-$C}"
  L="${L:-$N/build.lock}"
fi
mkdir -p "$O" "$(dirname "$L")"
cd "$X" || exit 2
C=$(git -C "$X" rev-parse --short HEAD 2>/dev/null || echo "head")
until mkdir "$L" 2>/dev/null; do sleep 5; done; echo "build_xlate $C $$" > "$L/owner"; trap 'rm -rf "$L"' EXIT
export RUSTFLAGS="--remap-path-prefix=$X=/src --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME=/build"
TARGET_FLAG=""
TARGET_DYLIB="target/release/libnvmtl_translate.dylib"
if [ "$(uname -m)" != "x86_64" ]; then
  TARGET_FLAG="--target x86_64-apple-darwin"
  TARGET_DYLIB="target/x86_64-apple-darwin/release/libnvmtl_translate.dylib"
fi
cargo build --release $TARGET_FLAG --ignore-rust-version --manifest-path wrapper/Cargo.toml --target-dir target > "$O/cargo.log" 2>&1; rc=$?
if [ "$rc" != 0 ]; then
  cat "$O/cargo.log" | tail -n 30
fi
grep -E "^error|warning: unused" "$O/cargo.log" | head -10
[ "$rc" = 0 ] || { echo "STOP: cargo build failed (rc $rc) — $O/cargo.log"; exit 4; }
cp "$TARGET_DYLIB" "$O/"; D="$O/libnvmtl_translate.dylib"; strip -S "$D"   # debug-map stabs name every .o by absolute path
install_name_tool -id @rpath/libnvmtl_translate.dylib "$D" 2>/dev/null && codesign -f -s - "$D" 2>/dev/null
miss=0
for p in NVMTL_NO_BINDLESS_ALL NVMTL_NO_TIER2; do [ "$(strings -a "$D" | grep -c -- "$p")" -ge 1 ] || { echo "  MISSING marker $p"; miss=$((miss+1)); }; done
if [ -f "$N/LIVE/xlate.exports" ]; then
  gone=$(comm -23 "$N/LIVE/xlate.exports" <(nm -gU "$D" | awk '{print $3}' | sort) | wc -l | tr -d ' ')
  [ "$gone" = 0 ] || { echo "  MISSING $gone export(s)"; miss=$((miss+1)); }
fi
echo "$X $(git -C "$X" rev-parse HEAD 2>/dev/null || echo "$C")" > "$O/TREE"
if [ -f "$N/shipcheck.py" ]; then
  echo "  tree: $X @ $C   identity: $(python3 "$N/shipcheck.py" "$D" | tail -1)"
fi
echo "xlate-$C  sha $(shasum -a256 "$D" | cut -c1-8)  uuid $(otool -l "$D" | awk '/uuid/{print $2; exit}')  missing $miss"
[ $miss = 0 ] || { echo "STOP: do NOT stage"; exit 6; }
echo "$D"
