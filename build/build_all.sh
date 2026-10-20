#!/bin/bash
# build_all.sh: Complete driver build script according to README
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

OUT_DIR="${OUT_DIR:-$HERE/build-out}"
DIST_DIR="${DIST_DIR:-$HERE/dist}"
OGKM="${OGKM:-$HOME/ogkm610}"
VULKAN_HEADERS="${VULKAN_HEADERS:-$HOME/Vulkan-Headers}"
BUILD_NVK="${BUILD_NVK:-0}"
RELEASE="${RELEASE:-1}"

echo "=========================================="
echo "  NullMoth NVIDIA Driver - Build All"
echo "=========================================="
echo "Source:         $HERE"
echo "Build Output:   $OUT_DIR"
echo "Distribution:   $DIST_DIR"
echo "OGKM:           $OGKM"
echo "Vulkan-Headers: $VULKAN_HEADERS"
echo "Release Build:  $RELEASE"
echo "=========================================="

mkdir -p "$OUT_DIR" "$DIST_DIR"

# 1. Shader Translator
echo ""
echo "--> [1/5] Building Shader Translator (libnvmtl_translate.dylib)..."
if command -v cargo >/dev/null 2>&1; then
  O="$OUT_DIR/xlate" X="$HERE/translator" "$HERE/build/build_xlate.sh"
  echo "    Shader Translator built successfully."
else
  echo "    WARNING: 'cargo' not found, skipping translator build."
fi

# 2. Metal Driver Plugin
echo ""
echo "--> [2/5] Building Metal Driver Plugin (NVMTLDriver.bundle)..."
if [ -d "$VULKAN_HEADERS/include" ]; then
  RELEASE="$RELEASE" VULKAN_HEADERS="$VULKAN_HEADERS" O="$OUT_DIR/plugin" S="$HERE/plugin" "$HERE/build/build_plugin.sh"
  
  # Assemble NVMTLDriver.bundle
  BUNDLE_DIR="$OUT_DIR/NVMTLDriver.bundle/Contents/MacOS"
  mkdir -p "$BUNDLE_DIR"
  cp "$OUT_DIR/plugin/NVMTLDriver" "$BUNDLE_DIR/"
  if [ -f "$OUT_DIR/xlate/libnvmtl_translate.dylib" ]; then
    cp "$OUT_DIR/xlate/libnvmtl_translate.dylib" "$BUNDLE_DIR/"
  fi
  codesign -f -s - "$BUNDLE_DIR/NVMTLDriver" 2>/dev/null || true
  echo "    NVMTLDriver.bundle assembled successfully."
else
  echo "    WARNING: Vulkan-Headers not found at $VULKAN_HEADERS, skipping plugin build."
fi

# 3. Kernel Extensions
echo ""
echo "--> [3/5] Building Kernel Extensions..."
if [ -d "$OGKM/src/nvidia-modeset" ]; then
  # Prepare dummy modeset compile_cmds if needed for accel_build
  mkdir -p "$OGKM/src/nvidia/_out/Darwin_x86_64"
  [ -f "$OGKM/src/nvidia/_out/Darwin_x86_64/compile_cmds.sh" ] || touch "$OGKM/src/nvidia/_out/Darwin_x86_64/compile_cmds.sh"
  
  export OGKM
  "$HERE/build/accel_build_all.sh" "$HERE/kexts/NVRM" "$OUT_DIR/kexts"
  echo "    NVAccel kexts (macOS 15 & 26) built successfully."
else
  echo "    WARNING: OGKM (open-gpu-kernel-modules) not found at $OGKM, skipping NVAccel."
fi

# NVRMAGDC
"$HERE/build/build_agdc.sh" "$HERE/kexts/NVRMAGDC" "$OUT_DIR/agdc"
echo "    NVRMAGDC.kext built successfully."

# NMDRM
"$HERE/kexts/NMDRM/build.sh" "$OUT_DIR/nmdrm"
echo "    NMDRM.kext built successfully."

# 4. Mesa NVK (Vulkan Driver)
echo ""
echo "--> [4/5] Building Mesa NVK (optional)..."
if [ "$BUILD_NVK" = "1" ]; then
  if [ -x "$HERE/build/build263.sh" ]; then
    "$HERE/build/build263.sh" || echo "    NVK build failed or skipped."
  fi
else
  echo "    Skipping NVK build (BUILD_NVK=0)."
fi

# 5. Package Driver
echo ""
echo "--> [5/5] Packaging Driver..."
PKGROOT="$DIST_DIR/pkgroot"
rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/Library/Extensions" \
         "$PKGROOT/Library/GPUBundles" \
         "$PKGROOT/Library/NullMoth/kexts/15" \
         "$PKGROOT/Library/NullMoth/kexts/26"

[ -d "$OUT_DIR/NVMTLDriver.bundle" ] && cp -R "$OUT_DIR/NVMTLDriver.bundle" "$PKGROOT/Library/GPUBundles/"
[ -d "$OUT_DIR/kexts/15/NVAccel.kext" ] && cp -R "$OUT_DIR/kexts/15/NVAccel.kext" "$PKGROOT/Library/NullMoth/kexts/15/"
[ -d "$OUT_DIR/kexts/26/NVAccel.kext" ] && cp -R "$OUT_DIR/kexts/26/NVAccel.kext" "$PKGROOT/Library/NullMoth/kexts/26/"
[ -d "$OUT_DIR/agdc/NVRMAGDC.kext" ] && cp -R "$OUT_DIR/agdc/NVRMAGDC.kext" "$PKGROOT/Library/Extensions/"
[ -d "$OUT_DIR/nmdrm/NMDRM.kext" ] && cp -R "$OUT_DIR/nmdrm/NMDRM.kext" "$PKGROOT/Library/Extensions/"

if [ -f "$OUT_DIR/rebase263/out/libvulkan_nouveau.dylib" ]; then
  mkdir -p "$PKGROOT/Library/GPUBundles/nvmtl"
  cp "$OUT_DIR/rebase263/out/libvulkan_nouveau.dylib" "$PKGROOT/Library/GPUBundles/nvmtl/"
fi

cp "$HERE/package/install.sh" "$PKGROOT/"
cp "$HERE/package/uninstall.sh" "$PKGROOT/"
chmod +x "$PKGROOT/install.sh" "$PKGROOT/uninstall.sh"

(cd "$PKGROOT" && find . -type f ! -name "SHA256SUMS" -exec shasum -a 256 {} + | sort > SHA256SUMS)
tar -czf "$DIST_DIR/nullmoth-nvidia-driver.tar.gz" -C "$DIST_DIR" pkgroot

echo ""
echo "=========================================="
echo "  Build & Packaging Complete!"
echo "  Artifact: $DIST_DIR/nullmoth-nvidia-driver.tar.gz"
echo "=========================================="
