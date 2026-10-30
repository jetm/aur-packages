#!/usr/bin/env bash
set -euo pipefail

# Tests the compiler-launcher selection in packages/linux-cachyos-jetm/PKGBUILD.
# Usage: test-kernel-launcher.sh [launcher|dist|march|sched|all]
#
# The PKGBUILD is sourced from a COPY of the package directory: sourcing it at
# global scope runs _purge_fetched_patches, which deletes fetched patch files
# from the directory it lives in.

mode="${1:-all}"
case "$mode" in
    launcher | dist | march | sched | all) ;;
    *) echo "usage: $0 [launcher|dist|march|sched|all]" >&2; exit 2 ;;
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
    case "$out" in *"OPT=[]"*) rc=0 ;; *) rc=1 ;; esac
    check "2 servers/64 cpus: _processor_opt stays empty (the target is detected, not pinned)" "$rc"
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

# Fake clang that answers `-march=native -###` with the CPU named in $FAKE_TARGET_CPU,
# in the shape real clang prints it on stderr.
mkdir -p "$work/clangbin"
cat > "$work/clangbin/clang" <<'FAKE'
#!/bin/sh
echo "\"/usr/bin/clang\" \"-cc1\" \"-triple\" \"x86_64-pc-linux-gnu\" \"-target-cpu\" \"${FAKE_TARGET_CPU:-x86-64}\"" >&2
FAKE
chmod +x "$work/clangbin/clang"

cpuinfo_amd="$work/cpuinfo-amd"
printf 'processor\t: 0\nvendor_id\t: AuthenticAMD\ncpu family\t: 26\n' > "$cpuinfo_amd"
cpuinfo_intel="$work/cpuinfo-intel"
printf 'processor\t: 0\nvendor_id\t: GenuineIntel\ncpu family\t: 6\n' > "$cpuinfo_intel"

# Run _amd_march against a fake /proc/cpuinfo ($1) and a compiler that reports $2.
run_march() {
    local cpuinfo="$1" target="$2"
    FAKE_TARGET_CPU="$target" run_pkg "$work/clangbin" "" "_cpuinfo='$cpuinfo'; _amd_march" 2>&1
}

march_tests() {
    local out rc sd

    out="$(run_march "$cpuinfo_amd" znver5)"
    check "AMD host, compiler says znver5: the target is znver5" "$([ "$out" = znver5 ] && echo 0 || echo 1)"

    out="$(run_march "$cpuinfo_amd" znver4)"
    check "AMD host, compiler says znver4: the target is znver4" "$([ "$out" = znver4 ] && echo 0 || echo 1)"

    rc=0
    out="$(run_march "$cpuinfo_intel" znver5)" || rc=$?
    check "Intel host: refused with a non-zero exit" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
    case "$out" in *AMD*GenuineIntel* | *GenuineIntel*AMD*) rc=0 ;; *) rc=1 ;; esac
    check "Intel host: the message names AMD and the vendor it saw" "$rc"

    rc=0
    out="$(run_march "$cpuinfo_amd" x86-64)" || rc=$?
    check "AMD host, compiler cannot name a znver target: refused" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

    # build(): the recorded target becomes an explicit -march for C and assembler, which
    # every distributed builder evaluates the same way, unlike -march=native.
    sd="$(mktemp -d -p "$work")"
    mkdir -p "$sd/src"
    printf 'znver5\n' > "$sd/src/.march"
    printf 'dist 2 64\n' > "$sd/src/.dist-decision"
    out="$(FAKE_STATUS="$sd/status.json" run_pkg "$work/distbin" "" \
        "srcdir='$sd/src'; nproc() { echo 32; }; _launcher_setup; _build_plan; printf 'FLAGS=%s\n' \"\${BUILD_FLAGS[*]:-}\"" 2>&1)"
    case "$(grep '^FLAGS=' <<< "$out")" in *"KCFLAGS=-march=znver5"*"KAFLAGS=-march=znver5"*) rc=0 ;; *) rc=1 ;; esac
    check "recorded znver5: BUILD_FLAGS carry KCFLAGS and KAFLAGS -march=znver5" "$rc"

    # A config prepared as 'local' that then finds servers used to fall back to ccache,
    # because -march=native would ship host-specific code. An explicit target is safe.
    printf '%s' "$status_2x64" > "$sd/status.json"
    printf 'local 0 0\n' > "$sd/src/.dist-decision"
    out="$(FAKE_STATUS="$sd/status.json" run_pkg "$work/distbin" "" \
        "srcdir='$sd/src'; nproc() { echo 32; }; _launcher_setup; _build_plan; printf 'FLAGS=%s\n' \"\${BUILD_FLAGS[*]:-}\"" 2>&1)"
    case "$(grep '^FLAGS=' <<< "$out")" in *"CC=sccache"*) rc=0 ;; *) rc=1 ;; esac
    check "recorded target + servers at build: sccache is kept, no ccache fallback" "$rc"

    rm -f "$sd/src/.march"
    out="$(FAKE_STATUS="$sd/status.json" run_pkg "$work/distbin" "" \
        "srcdir='$sd/src'; nproc() { echo 32; }; _launcher_setup; _build_plan; printf 'FLAGS=%s\n' \"\${BUILD_FLAGS[*]:-}\"" 2>&1)"
    case "$(grep '^FLAGS=' <<< "$out")" in *KCFLAGS*) rc=1 ;; *) rc=0 ;; esac
    check "no recorded target: no KCFLAGS or KAFLAGS are added" "$rc"
}

# One b2sums entry per source entry, whatever _cpusched is: makepkg rejects a mismatch,
# and the BORE patch is only fetched for the bore family.
run_sched() {
    local sched="$1"
    # _cpusched must be set before the PKGBUILD is sourced: it decides `source` at global scope.
    if [ -n "$sched" ]; then export _cpusched="$sched"; else unset _cpusched; fi
    run_pkg "$work/distbin" "" \
        "printf 'SCHED=%s SRC=%s SUMS=%s\n' \"\$_cpusched\" \"\${#source[@]}\" \"\${#b2sums[@]}\"" 2>&1
}

sched_tests() {
    local out s
    # updpkgsums (run by aurgen) deletes from every line matching this pattern to the next
    # line ending in ')'. A second match, e.g. `b2sums+=(`, is deleted along with whatever
    # follows it, which broke the PKGBUILD's syntax.
    check "only the b2sums array itself matches updpkgsums' start pattern" \
        "$([ "$(grep -cE '^[[:blank:]]*b2sums(_[^=]+)?\+?=' "$pkgdir/PKGBUILD")" -eq 1 ] && echo 0 || echo 1)"

    out="$(run_sched '')"
    check "default scheduler is eevdf" "$(grep -q '^SCHED=eevdf ' <<< "$out" && echo 0 || echo 1)"
    for s in '' eevdf cachyos bore; do
        out="$(run_sched "$s")"
        check "_cpusched='${s:-default}': source and b2sums have the same length ($out)" \
            "$(awk '{split($2,a,"=");split($3,b,"=");exit !(a[2]==b[2] && a[2]>0)}' <<< "$out" && echo 0 || echo 1)"
    done
}

case "$mode" in launcher | all) launcher_tests ;; esac
case "$mode" in dist | all) dist_tests ;; esac
case "$mode" in march | all) march_tests ;; esac
case "$mode" in sched | all) sched_tests ;; esac

echo "checks: $ran/$total run"
if [ "$failed" -ne 0 ]; then
    echo "$failed check(s) failed" >&2
    exit 1
fi
