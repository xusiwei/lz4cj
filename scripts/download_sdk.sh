#!/usr/bin/env bash
# Download and install Cangjie LTS/STS SDKs under ~/.local (Linux helper,
# also runs under Git Bash / macOS). Counterpart: scripts/setup_env.sh
# switches ~/.local/cangjie-sdk between the installed channels.
#
# Usage: scripts/download_sdk.sh [lts|sts|both]   (default: both; lt/st aliases)
#
# Layout produced (both channels coexist; switching never re-extracts):
#   ~/.local/cangjie-lts-<ver>/     extracted LTS SDK
#   ~/.local/cangjie-sts-<ver>/     extracted STS SDK
# Archives come from cangjie-lang.cn direct links, pinned by sha256.
# Idempotent: a channel with tools/bin/cjpm(.exe) already present is skipped,
# so this is safe to run on every CI job behind an actions/cache restore.
#
# Override the platform probe with LZ4CJ_SDK_OS=<linux-x64|linux-aarch64|
# windows-x64|mac-aarch64> (e.g. when testing the script itself).
set -euo pipefail

# --------------------------------------------------------------------------
# Channel table - the ONLY place to edit when a new LTS/STS ships.
# Rows: <platform>|<archive-name>|<objectKey>|<sha256>
# --------------------------------------------------------------------------
LTS_VERSION="1.0.5"
LTS_PLATFORMS=(
  "linux-x64|cangjie-sdk-linux-x64-1.0.5.tar.gz|698acf46bd66ae22b62330b0|BACAD84DF8E0281C5395BAB4C40E481E3EA6CC712EED5C953903B0D561A14562"
  "linux-aarch64|cangjie-sdk-linux-aarch64-1.0.5.tar.gz|698acfa3bd66ae22b62330b1|C0DC48B8851FD87853308BF0EF5CCE7040F8681AE8A53005D5DAC81657745A35"
  "windows-x64|cangjie-sdk-windows-x64-1.0.5.zip|698acebfbd66ae22b62330af|08C6C1DD0DE73396F63AC85085D635E79CE84FEF98D330CB00869B4FC8F1CB2E"
  "mac-aarch64|cangjie-sdk-mac-aarch64-1.0.5.tar.gz|698acea5bd66ae22b62330ae|E07D22584237F065B30A771B7110A87A8931334C40BE3A148090944AE916ED1F"
)
STS_VERSION="1.2.0"
STS_PLATFORMS=(
  "linux-x64|cangjie-sdk-linux-x64-1.2.0.tar.gz|6ab1e26eece1f87ff5befa73|8c5fd944cd9cc51ee63d4a240e3ecc4f540345dae1468e8b47c927ecf2ba998f"
  "linux-aarch64|cangjie-sdk-linux-aarch64-1.2.0.tar.gz|6ab1e26eece1f87ff5befa72|40e3962472d6d1b181e685198b193b904a385ac8dbbdff8aa9c52c4bb6f6e0f1"
  "windows-x64|cangjie-sdk-windows-x64-1.2.0.zip|6ab1eafae4bd101f57762f5e|7bd5088ad56fb03c1214e73ea076de5ac08580cc419a8cbd46a524ee1ca250bf"
  "mac-aarch64|cangjie-sdk-mac-aarch64-1.2.0.tar.gz|6ab1e6451320215435b23d52|de88d6ba2185c94979e0ab2fe8ac1d81535dfdff3fcb51fbba71e4b99d851f97"
)
DL_URL_TMPL="https://cangjie-lang.cn/v1/files/auth/downLoad?nsId=142267&fileName=%s&objectKey=%s"

LOCAL_ROOT="$HOME/.local"

detect_platform() {
    if [ -n "${LZ4CJ_SDK_OS:-}" ]; then
        printf '%s' "$LZ4CJ_SDK_OS"; return 0
    fi
    local sys arch
    sys="$(uname -s)"; arch="$(uname -m)"
    case "$sys/$arch" in
        Linux/x86_64)         echo linux-x64 ;;
        Linux/aarch64|Linux/arm64) echo linux-aarch64 ;;
        MINGW*/*|MSYS*/*|CYGWIN*/*) echo windows-x64 ;;
        Darwin/arm64)         echo mac-aarch64 ;;
        *) echo "[error] unsupported platform: $sys/$arch (override with LZ4CJ_SDK_OS=...)" >&2; return 1 ;;
    esac
}

sha_check() { # sha_check <expected-sha256> <file>
    local want got cmd
    want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    if command -v sha256sum >/dev/null 2>&1; then cmd=sha256sum
    elif command -v shasum >/dev/null 2>&1; then cmd="shasum -a 256"   # macOS
    else echo "[error] no sha256 tool found (sha256sum / shasum)" >&2; return 1; fi
    got="$($cmd "$2" | awk '{print tolower($1)}')"
    if [ "$got" != "$want" ]; then
        echo "[error] sha256 mismatch for $2" >&2
        echo "  want: $want" >&2
        echo "  got : $got" >&2
        return 1
    fi
}

extract_archive() { # extract_archive <archive> <dest-parent-tmpdir>
    local archive="$1" tmpdir="$2"
    case "$archive" in
    *.tar.gz)
        tar -xzf "$archive" -C "$tmpdir"
        ;;
    *.zip)
        # Git Bash's GNU tar cannot read zip and shadows System32 bsdtar;
        # call the Windows one explicitly (bsdtar handles zip fine).
        if [ -x /c/Windows/System32/tar.exe ]; then
            /c/Windows/System32/tar.exe -xf "$archive" -C "$tmpdir"
        elif command -v unzip >/dev/null 2>&1; then
            unzip -q "$archive" -d "$tmpdir"
        else
            echo "[error] no zip extractor found (System32 tar.exe / unzip)" >&2; return 1
        fi
        ;;
    *)
        echo "[error] unknown archive type: $archive" >&2; return 1
        ;;
    esac
}

install_channel() { # install_channel <lts|sts>
    local channel="$1" version row platform archive objkey sha url dest tb tmpdir top
    case "$channel" in
        lts) version="$LTS_VERSION"; PLATFORMS_TABLE=("${LTS_PLATFORMS[@]}") ;;
        sts) version="$STS_VERSION"; PLATFORMS_TABLE=("${STS_PLATFORMS[@]}") ;;
        *) echo "[error] unknown channel: $channel" >&2; return 1 ;;
    esac
    platform="$(detect_platform)" || return 1
    dest="$LOCAL_ROOT/cangjie-$channel-$version"

    # idempotency: accept both flat and nested-cangjie layouts
    if [ -x "$dest/tools/bin/cjpm" ] || [ -x "$dest/tools/bin/cjpm.exe" ] \
       || [ -x "$dest/cangjie/tools/bin/cjpm" ] || [ -x "$dest/cangjie/tools/bin/cjpm.exe" ]; then
        echo "[skip] $dest already installed"
        return 0
    fi

    row=""
    for r in "${PLATFORMS_TABLE[@]}"; do
        [ "${r%%|*}" = "$platform" ] && { row="$r"; break; }
    done
    if [ -z "$row" ]; then
        echo "[error] no $channel package for platform '$platform' in the table" >&2; return 1
    fi
    IFS='|' read -r _ archive objkey sha <<< "$row"
    url="$(printf "$DL_URL_TMPL" "$archive" "$objkey")"

    echo "[download] $channel $version ($platform)"
    echo "  url: $url"
    mkdir -p "$LOCAL_ROOT"
    tb="$(mktemp -t cangjie-sdk-XXXXXX)"   # suffix added per-platform below
    case "$archive" in
        *.tar.gz) tb="$tb.tar.gz" ;;
        *.zip)    tb="$tb.zip" ;;
    esac
    if ! curl -fL --retry 3 --connect-timeout 30 -o "$tb" "$url"; then
        rm -f "$tb"; echo "[error] download failed: $url" >&2; return 1
    fi

    echo "[verify] sha256"
    if ! sha_check "$sha" "$tb"; then rm -f "$tb"; return 1; fi

    echo "[extract] -> $dest"
    tmpdir="$(mktemp -d)"
    if ! extract_archive "$tb" "$tmpdir"; then rm -rf "$tmpdir" "$tb"; return 1; fi
    top="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1)"
    if [ -z "$top" ]; then
        rm -rf "$tmpdir" "$tb"; echo "[error] archive has no top-level directory" >&2; return 1
    fi
    mv "$top" "$dest"
    rm -rf "$tmpdir" "$tb"

    # post-check in the new layout (both flat and nested-cangjie accepted)
    if [ -f "$dest/envsetup.sh" ] || [ -f "$dest/cangjie/envsetup.sh" ]; then
        echo "[ok] $channel $version -> $dest (envsetup found)"
    else
        echo "[error] envsetup.sh not found under $dest" >&2; return 1
    fi
}

normalize_arg() {
    case "$1" in
        lts|lt|1.0.5) echo lts ;;
        sts|st|1.2.0) echo sts ;;
        both)         echo both ;;
        *) return 1 ;;
    esac
}

main() {
    local sel="${1:-both}"
    sel="$(normalize_arg "$sel")" || { echo "usage: $0 [lts|sts|both]"; exit 1; }
    case "$sel" in
        lts)  install_channel lts ;;
        sts)  install_channel sts ;;
        both) install_channel lts; install_channel sts ;;
    esac
    echo "download done (activate with: source scripts/setup_env.sh <lts|sts>)"
}

main "$@"
