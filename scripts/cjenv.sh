#!/usr/bin/env bash
# Path-independent Cangjie SDK resolver, shared by the lz4cj scripts.
# Source this file, then call:  cjenv_setup <1.0.5|1.2.0>
# which prints the absolute path of that SDK's envsetup.sh (stdout).
#
# Lookup order per version:
#   1. $LZ4CJ_SDK_105 / $LZ4CJ_SDK_120 - SDK root given by the caller.
#      May point either at the directory holding envsetup.sh (e.g. a
#      Windows archive extracted as .../cangjie-sdk-windows-x64-1.0.5/cangjie)
#      or at its parent (the archive dir itself); both layouts are accepted.
#      Windows-style backslash paths are normalized.
#   2. $HOME/sdk/cangjie-<ver> - Linux CI layout used by setup_env.sh.
cjenv_setup() {
    local ver="$1" var root cand
    case "$ver" in
        1.0.5) var="LZ4CJ_SDK_105" ;;
        1.2.0) var="LZ4CJ_SDK_120" ;;
        *) echo "[cjenv] unsupported Cangjie SDK version: $ver" >&2; return 1 ;;
    esac
    for root in "${!var:-}" "$HOME/sdk/cangjie-$ver"; do
        [ -n "$root" ] || continue
        root="${root//\\//}"
        for cand in "$root/envsetup.sh" "$root/cangjie/envsetup.sh"; do
            if [ -f "$cand" ]; then
                echo "$(cd "$(dirname "$cand")" && pwd)/envsetup.sh"
                return 0
            fi
        done
    done
    echo "[cjenv] Cangjie $ver SDK not found." >&2
    echo "[cjenv] Set LZ4CJ_SDK_105 / LZ4CJ_SDK_120 to the SDK root (the dir" >&2
    echo "[cjenv] holding envsetup.sh or cangjie/envsetup.sh), or install to" >&2
    echo "[cjenv] \$HOME/sdk/cangjie-$ver (see scripts/setup_env.sh)." >&2
    return 1
}
