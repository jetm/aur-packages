#!/usr/bin/env bash
set -euo pipefail

# Tests the compiler-launcher selection in packages/linux-cachyos-jetm/PKGBUILD.
# Usage: test-kernel-launcher.sh [launcher|dist|all]
#
# The PKGBUILD is sourced from a COPY of the package directory: sourcing it at
# global scope runs _purge_fetched_patches, which deletes fetched patch files
# from the directory it lives in.

mode="${1:-all}"
case "$mode" in
    launcher | dist | all) ;;
    *) echo "usage: $0 [launcher|dist|all]" >&2; exit 2 ;;
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

# Fake sccache whose --dist-status output comes from the file in $FAKE_STATUS.
mkdir -p "$work/distbin"
cat > "$work/distbin/sccache" <<'FAKE'
#!/bin/sh
case "${1:-}" in
    --dist-status) cat "$FAKE_STATUS"; exit "${FAKE_RC:-0}" ;;
    *) exit 0 ;;
esac
FAKE
chmod +x "$work/distbin/sccache"
status_2x64='{"SchedulerStatus":["https://s:10600",{"num_servers":2,"num_cpus":64,"in_progress":0,"servers":{"a":{"num_cpus":32},"b":{"num_cpus":32}}}]}'
status_off='{"Disabled":null}'

# Run a snippet with a fake scheduler status ($1), nproc stubbed to 32, and a
# fresh srcdir per call.
run_dist() {
    local status="$1" snippet="$2" sd
    sd="$(mktemp -d -p "$work")"
    printf '%s' "$status" > "$sd/status.json"
    mkdir -p "$sd/src"
    FAKE_STATUS="$sd/status.json" run_pkg "$work/distbin" "" \
        "srcdir='$sd/src'; nproc() { echo 32; }; $snippet" 2>&1
}

dist_tests() {
    local out rc dump
    dump='_launcher_setup; _dist_decide; printf "DECISION=%s\n" "$(cat "$srcdir/.dist-decision")"; printf "OPT=[%s]\n" "$_processor_opt"; _build_plan; printf "JOBS=%s\n" "$_jobs"'

    out="$(run_dist "$status_2x64" "$dump")"
    case "$out" in *"DECISION=dist 2 64"*) rc=0 ;; *) rc=1 ;; esac
    check "2 servers/64 cpus: decision is 'dist 2 64'" "$rc"
    case "$out" in *"OPT=[zen4]"*) rc=0 ;; *) rc=1 ;; esac
    check "2 servers/64 cpus: _processor_opt pinned to zen4" "$rc"
    case "$out" in *"JOBS=96"*) rc=0 ;; *) rc=1 ;; esac
    check "2 servers/64 cpus on 32-cpu host: 96 jobs" "$rc"

    out="$(run_dist "$status_off" "$dump")"
    case "$out" in *"DECISION=local 0 0"*) rc=0 ;; *) rc=1 ;; esac
    check "Disabled: decision is 'local 0 0'" "$rc"
    case "$out" in *"OPT=[]"*) rc=0 ;; *) rc=1 ;; esac
    check "Disabled: _processor_opt stays empty" "$rc"
    case "$out" in *"JOBS=32"*) rc=0 ;; *) rc=1 ;; esac
    check "Disabled: 32 jobs" "$rc"

    out="$(run_dist "$status_2x64" "_processor_opt=native; $dump")"
    case "$out" in *"OPT=[native]"*) rc=0 ;; *) rc=1 ;; esac
    check "explicit _processor_opt=native is kept while distributing" "$rc"

    out="$(run_dist "$status_2x64" "_make_jobs=120; $dump")"
    case "$out" in *"JOBS=120"*) rc=0 ;; *) rc=1 ;; esac
    check "_make_jobs=120 overrides the computed job count" "$rc"

    # decision local at configure time, servers visible by build time
    out="$(run_dist "$status_2x64" '_launcher_setup; echo "local 0 0" > "$srcdir/.dist-decision"; _build_plan; printf "FLAGS=%s\n" "${BUILD_FLAGS[*]:-}"; printf "PATH=%s\n" "$PATH"; printf "JOBS=%s\n" "$_jobs"')"
    case "$(grep '^PATH=' <<< "$out")" in "PATH=/usr/lib/ccache/bin"*) rc=0 ;; *) rc=1 ;; esac
    check "local decision + servers at build: PATH regains /usr/lib/ccache/bin first" "$rc"
    case "$(grep '^FLAGS=' <<< "$out")" in *sccache*) rc=1 ;; *"CC=clang"*) rc=0 ;; *) rc=1 ;; esac
    check "local decision + servers at build: BUILD_FLAGS CC is plain clang" "$rc"
    case "$out" in *"JOBS=32"*) rc=0 ;; *) rc=1 ;; esac
    check "local decision + servers at build: 32 jobs" "$rc"
}

case "$mode" in launcher | all) launcher_tests ;; esac
case "$mode" in dist | all) dist_tests ;; esac

echo "checks: $ran/$total run"
if [ "$failed" -ne 0 ]; then
    echo "$failed check(s) failed" >&2
    exit 1
fi
