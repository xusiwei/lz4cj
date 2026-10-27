#!/usr/bin/env bash
# Activate a Cangjie toolchain by switching the ~/.local/cangjie-sdk link.
# Counterpart: scripts/download_sdk.sh installs the channels this switches to.
#
# Usage:
#   source scripts/setup_env.sh lts   # switch link + export env in this shell
#   source scripts/setup_env.sh sts
#   source scripts/setup_env.sh       # print the active channel
#   bash   scripts/setup_env.sh sts   # switch the link only (no env exports)
#
# Mechanism: ~/.local/cangjie-sdk -> ~/.local/cangjie-<channel>-<version>
# All exported paths go through the link, so the PATH entries are stable
# across switches (only the link target changes). On Windows the link is a
# junction (Git Bash `ln -s` degrades to a copy; junctions need no privileges).
#
# Channel versions are discovered from the ~/.local/cangjie-<channel>-* dirs
# installed by download_sdk.sh (newest wins if several are present).

LINK="$HOME/.local/cangjie-sdk"
STAMP="$HOME/.local/.cangjie-sdk.channel"

_is_windows() {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac
}

_normalize_channel() { # -> lts|sts, or empty when unknown
    case "$1" in
        lts|lt|1.0.5) echo lts ;;
        sts|st|1.2.0) echo sts ;;
        *) return 1 ;;
    esac
}

_resolve_channel_dir() { # _resolve_channel_dir <lts|sts> -> newest installed dir
    local channel="$1" dir best
    best=""
    for dir in "$HOME"/.local/cangjie-"$channel"-*; do
        [ -d "$dir" ] || continue
        best="$dir"                       # glob sorts oldest -> newest
    done
    [ -n "$best" ] || {
        echo "[error] no $channel SDK under ~/.local - run scripts/download_sdk.sh $channel first" >&2
        return 1
    }
    printf '%s' "$best"
}

_envsetup_of() { # _envsetup_of <sdk-root> -> path of envsetup.sh
    local root="$1"
    if [ -f "$root/envsetup.sh" ]; then
        printf '%s/envsetup.sh' "$root"
    elif [ -f "$root/cangjie/envsetup.sh" ]; then
        printf '%s/cangjie/envsetup.sh' "$root"
    fi
}

_remove_link() {
    if [ -L "$LINK" ]; then
        rm "$LINK"
    elif [ -e "$LINK" ]; then
        if _is_windows; then
            # junction: rmdir removes just the link, never the target tree
            if ! cmd //c rmdir "$(cygpath -w "$LINK")" >/dev/null 2>&1; then
                echo "[error] cannot remove $LINK (real directory?); remove it manually" >&2
                return 1
            fi
        else
            echo "[error] $LINK exists and is not a symlink; remove it manually" >&2
            return 1
        fi
    fi
}

_switch_link() { # _switch_link <dest-dir>
    local dest="$1"
    _remove_link || return 1
    if _is_windows; then
        if ! cmd //c mklink //J "$(cygpath -w "$LINK")" "$(cygpath -w "$dest")" >/dev/null; then
            echo "[error] mklink /J failed for $LINK" >&2; return 1
        fi
    else
        ln -sfn "$dest" "$LINK"
    fi
}

# Strip entries pointing through the link (or a previous CANGJIE_HOME) so
# repeated activations never stack stale toolchain paths in PATH.
_strip_stale() { # _strip_stale <varname>
    local var="$1" out="" entry _parts old_home="${OLD_CANGJIE_HOME:-}"
    local IFS=':'
    read -ra _parts <<< "${!var:-}"
    for entry in "${_parts[@]}"; do
        [ -n "$entry" ] || continue
        case "$entry" in
            "$LINK"|"$LINK"/*) continue ;;
        esac
        # only filter by the old home when there was one - an empty prefix
        # would otherwise match every absolute path
        if [ -n "$old_home" ]; then
            case "$entry" in
                "$old_home"|"$old_home"/*) continue ;;
            esac
        fi
        out="${out:+$out:}$entry"
    done
    printf '%s' "$out"
}

_setup() { # _setup <lts|sts|none>
    local channel="$1" dir setup had_u
    if [ "$channel" = "none" ]; then
        if [ -f "$STAMP" ]; then
            echo "active: $(cat "$STAMP") -> $(cd "$LINK" 2>/dev/null && pwd)"
        else
            echo "active: (none - source scripts/setup_env.sh <lts|sts>)"
        fi
        return 0
    fi
    dir="$(_resolve_channel_dir "$channel")" || return 1

    SOURCED=1
    if [ "${BASH_SOURCE[0]}" = "$0" ]; then SOURCED=0; fi
    _switch_link "$dir" || return 1
    mkdir -p "$HOME/.local"
    printf '%s' "$channel" > "$STAMP"
    echo "[switch] $channel -> $dir (link: $LINK)"

    if [ "$SOURCED" -eq 0 ]; then
        echo "[hint] link switched; for env exports run: source scripts/setup_env.sh $channel"
        return 0
    fi

    # sourced mode: sanitized env via the SDK's own envsetup through the link
    OLD_CANGJIE_HOME="${CANGJIE_HOME:-}"
    PATH="$(_strip_stale PATH)"
    LD_LIBRARY_PATH="$(_strip_stale LD_LIBRARY_PATH)"
    setup="$(_envsetup_of "$LINK")"
    if [ -z "$setup" ]; then
        echo "[error] envsetup.sh not found under $LINK" >&2; return 1
    fi
    case $- in *u*) had_u=1 ;; *) had_u=0 ;; esac
    set +u                       # envsetup.sh is not `set -u` clean
    . "$setup"
    [ "$had_u" -eq 1 ] && set -u
    echo "[env] CANGJIE_HOME=${CANGJIE_HOME:-<unset>}"
    if command -v cjpm >/dev/null 2>&1; then
        echo "[env] cjpm $(cjpm --version 2>/dev/null || echo '?')"
    fi
    return 0
}

_arg="${1:-none}"
case "$_arg" in
    none) _setup none ;;
    *)    _ch="$(_normalize_channel "$_arg")" || {
              echo "usage: source scripts/setup_env.sh [lts|sts]" >&2
              return 1 2>/dev/null || exit 1
          }
          _setup "$_ch" || { return 1 2>/dev/null || exit 1; } ;;
esac
