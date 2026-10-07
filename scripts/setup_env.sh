#!/usr/bin/env bash
# Prepare Cangjie LTS-1.0.5 & STS-1.2.0 SDKs under ~/sdk (Linux helper).
# Targets honor LZ4CJ_SDK_105 / LZ4CJ_SDK_120 so a pre-extracted SDK
# (e.g. a Windows archive at D:\...\cangjie-sdk-windows-x64-<ver>) is
# detected and skipped instead of reinstalled.
set -euo pipefail
SDK_ROOT="${HOME}/sdk"
mkdir -p "$SDK_ROOT"

install_from_tarball() {
    local tb="$1" dest="$2"
    # accept both Linux (cjpm) and Windows (cjpm.exe) layouts, and both
    # dest/envsetup.sh and dest/cangjie/envsetup.sh nestings
    if [ -x "$dest/tools/bin/cjpm" ] || [ -x "$dest/tools/bin/cjpm.exe" ] \
       || [ -x "$dest/cangjie/tools/bin/cjpm" ] || [ -x "$dest/cangjie/tools/bin/cjpm.exe" ]; then
        echo "[skip] $dest already installed"; return 0
    fi
    if [ ! -f "$tb" ]; then echo "[error] tarball not found: $tb"; return 1; fi
    echo "[extract] $tb -> $dest"
    local tmp; tmp="$(mktemp -d)"
    tar -xzf "$tb" -C "$tmp"
    mv "$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)" "$dest"
    rm -rf "$tmp"
}

install_from_tarball "${LZ4CJ_TARBALL_105:-$HOME/Downloads/cangjie-sdk-linux-x64-1.0.5.tar.gz}" \
    "${LZ4CJ_SDK_105:-$SDK_ROOT/cangjie-1.0.5}" \
    || { echo "请手动安装 1.0.5 SDK 至 ${LZ4CJ_SDK_105:-$SDK_ROOT/cangjie-1.0.5}"; exit 1; }
install_from_tarball "${LZ4CJ_TARBALL_120:-$HOME/cangjie-sdk-linux-x64-1.2.0.tar.gz}" \
    "${LZ4CJ_SDK_120:-$SDK_ROOT/cangjie-1.2.0}" \
    || { echo "请手动安装 1.2.0 SDK 至 ${LZ4CJ_SDK_120:-$SDK_ROOT/cangjie-1.2.0}"; exit 1; }

SDK_105="${LZ4CJ_SDK_105:-$SDK_ROOT/cangjie-1.0.5}"
SDK_120="${LZ4CJ_SDK_120:-$SDK_ROOT/cangjie-1.2.0}"
SETUP_105="$([ -f "$SDK_105/envsetup.sh" ] && echo "$SDK_105" || echo "$SDK_105/cangjie")/envsetup.sh"
SETUP_120="$([ -f "$SDK_120/envsetup.sh" ] && echo "$SDK_120" || echo "$SDK_120/cangjie")/envsetup.sh"
bash -c "source '$SETUP_105' && cjpm --version"
bash -c "source '$SETUP_120' && cjpm --version"
echo "setup done"
