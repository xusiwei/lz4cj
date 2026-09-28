#!/usr/bin/env bash
# Prepare Cangjie LTS-1.0.5 & STS-1.2.0 SDKs under ~/sdk.
set -euo pipefail
SDK_ROOT="${HOME}/sdk"
mkdir -p "$SDK_ROOT"

install_from_tarball() {
    local tb="$1" dest="$2"
    if [ -x "$dest/tools/bin/cjpm" ]; then echo "[skip] $dest already installed"; return 0; fi
    if [ ! -f "$tb" ]; then echo "[error] tarball not found: $tb"; return 1; fi
    echo "[extract] $tb -> $dest"
    local tmp; tmp="$(mktemp -d)"
    tar -xzf "$tb" -C "$tmp"
    mv "$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)" "$dest"
    rm -rf "$tmp"
}

install_from_tarball "$HOME/Downloads/cangjie-sdk-linux-x64-1.0.5.tar.gz" "$SDK_ROOT/cangjie-1.0.5" \
    || { echo "请手动安装 1.0.5 SDK 至 $SDK_ROOT/cangjie-1.0.5"; exit 1; }
install_from_tarball "$HOME/cangjie-sdk-linux-x64-1.2.0.tar.gz" "$SDK_ROOT/cangjie-1.2.0" \
    || { echo "请手动安装 1.2.0 SDK 至 $SDK_ROOT/cangjie-1.2.0"; exit 1; }

bash -c "source $SDK_ROOT/cangjie-1.0.5/envsetup.sh && cjpm --version"
bash -c "source $SDK_ROOT/cangjie-1.2.0/envsetup.sh && cjpm --version"
echo "setup done"
