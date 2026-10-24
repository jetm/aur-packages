#!/usr/bin/env bash
set -euo pipefail

# Tests the compiler-launcher selection in packages/linux-cachyos-jetm/PKGBUILD.
# Usage: test-kernel-launcher.sh [launcher|all]
#
# The PKGBUILD is sourced from a COPY of the package directory: sourcing it at
# global scope runs _purge_fetched_patches, which deletes fetched patch files
# from the directory it lives in.

mode="${1:-all}"
case "$mode" in
    launcher | all) ;;
    *) echo "usage: $0 [launcher|all]" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pkgdir="$repo/packages/linux-cachyos-jetm"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

cp -r "$pkgdir" "$work/pkg"
mkdir -p "$work/bin"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/sccache"
chmod +x "$work/bin/sccache"

total=0
ran=0
failed=0

check() { # check <name> <condition-exit-status>
    local name="$1" rc="$2"
    total=$((total + 1))
    ran=$((ran + 1))
    if [ "$rc" -eq 0 ]; then
        echo "ok   - $name"
    else
        echo "FAIL - $name"
        failed=$((failed + 1))
    fi
}

# Run a snippet after sourcing the PKGBUILD copy with makepkg's output helpers
# stubbed. $1 = extra PATH prefix, $2 = _cc_launcher value ("" leaves it unset).
run_pkg() {
    local pathprefix="$1" launcher="$2" snippet="$3"
    (
        PATH="$pathprefix:/usr/lib/ccache/bin:$PATH"
        # shellcheck disable=SC2329
        msg() { :; }; msg2() { :; }; warning() { :; }; plain() { :; }
        error() { echo "error: $*" >&2; }
        [ -z "$launcher" ] || _cc_launcher="$launcher"
        cd "$work/pkg"
        startdir="$work/pkg"
        # shellcheck disable=SC1091
        source ./PKGBUILD
        eval "$snippet"
    )
}

# A real sccache may live in /usr/bin, so "absent" is simulated by making
# `command -v sccache` fail.
hide_sccache='command() { if [ "${1:-}" = -v ] && [ "${2:-}" = sccache ]; then return 1; fi; builtin command "$@"; }'
setup_dump='_launcher_setup; printf "FLAGS=%s\n" "${BUILD_FLAGS[*]:-}"; printf "PATH=%s\n" "$PATH"'

launcher_tests() {
    local out rc

    # (1) sccache present, launcher unset
    out="$(run_pkg "$work/bin" "" "$setup_dump" 2>&1)"
    case "$out" in *"CC=sccache /usr/bin/clang"*) rc=0 ;; *) rc=1 ;; esac
    check "sccache on PATH, unset: BUILD_FLAGS holds CC=sccache /usr/bin/clang" "$rc"
    case "$(grep '^PATH=' <<< "$out")" in *"/usr/lib/ccache/bin"*) rc=1 ;; *) rc=0 ;; esac
    check "sccache on PATH, unset: PATH has no /usr/lib/ccache/bin" "$rc"

    # (2) sccache absent: PATH must exclude the fake sccache dir
    out="$(run_pkg "$work/empty" "" "$hide_sccache; $setup_dump" 2>&1)"
    case "$out" in *"CC=clang"*) rc=0 ;; *) rc=1 ;; esac
    check "sccache absent: BUILD_FLAGS keeps CC=clang" "$rc"
    case "$out" in *sccache*) rc=1 ;; *) rc=0 ;; esac
    check "sccache absent: no sccache prefix anywhere in BUILD_FLAGS" "$rc"
    case "$(grep '^PATH=' <<< "$out")" in *"/usr/lib/ccache/bin"*) rc=0 ;; *) rc=1 ;; esac
    check "sccache absent: PATH keeps /usr/lib/ccache/bin" "$rc"

    # (3) ccache forced with sccache present
    out="$(run_pkg "$work/bin" ccache "$setup_dump" 2>&1)"
    case "$out" in *"CC=clang"*) rc=0 ;; *) rc=1 ;; esac
    check "_cc_launcher=ccache: BUILD_FLAGS keeps CC=clang" "$rc"
    case "$out" in *sccache*) rc=1 ;; *) rc=0 ;; esac
    check "_cc_launcher=ccache: no sccache prefix" "$rc"
    case "$(grep '^PATH=' <<< "$out")" in *"/usr/lib/ccache/bin"*) rc=0 ;; *) rc=1 ;; esac
    check "_cc_launcher=ccache: PATH keeps /usr/lib/ccache/bin" "$rc"

    # (4) bogus value
    rc=0
    out="$(run_pkg "$work/bin" bogus '_launcher_select' 2>&1)" || rc=$?
    local named=1
    case "$out" in *auto*sccache*ccache*) named=0 ;; esac
    check "_cc_launcher=bogus: _launcher_select exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
    check "_cc_launcher=bogus: message names auto, sccache and ccache" "$named"

    # (5) .SRCINFO unchanged, with and without sccache on PATH
    local info
    for p in "$work/bin" "$work/empty"; do
        rc=0
        info="$(cd "$work/pkg" && PATH="$p:$PATH" makepkg --printsrcinfo 2>/dev/null)" || rc=1
        [ "$rc" -ne 0 ] || [ "$info" = "$(cat "$pkgdir/.SRCINFO")" ] || rc=1
        check "makepkg --printsrcinfo matches .SRCINFO (PATH prefix ${p##*/})" "$rc"
    done

    # (6) global scope is safe under set -u
    rc=0
    (cd "$work/pkg" && startdir="$work/pkg" bash -u -c '
        msg() { :; }; msg2() { :; }; warning() { :; }; plain() { :; }; error() { :; }
        source ./PKGBUILD') >/dev/null 2>&1 || rc=1
    check "PKGBUILD sources cleanly under bash -u" "$rc"
}

launcher_tests

echo "checks: $ran/$total run"
if [ "$failed" -ne 0 ]; then
    echo "$failed check(s) failed" >&2
    exit 1
fi
