#!/usr/bin/env bash
# Kernel build distributed-compile benchmark helpers.
#
#   timeline <tree>                   phase table from a finished build tree's mtimes
#   smoke <tree> [--local] [tu]       one Kbuild TU: direct clang vs sccache clang
#   probe <tree> [subdir]             local vs distributed rebuild rate (exit 3: local wins)
#   run <label> [--force] [VAR=val..] full makepkg benchmark row (exit 4: machine loaded)
#   report                            runs.tsv summary: bar, stretch, follow-on
#   self-test                         offline checks of the parsing helpers
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/kernel-dist-bench-helper.py"

usage() {
  echo "usage: $0 timeline <tree> | smoke <tree> [--local] [tu] | probe <tree> [subdir]" \
    "| run <label> [--force] [VAR=value ...] | report | self-test" >&2
  exit 2
}

py() { python3 -B -I "$HELPER" "$@"; }

cmd_smoke() {
  local tree="" local_ok=0 tu="" a
  for a in "$@"; do
    case "$a" in
      --local) local_ok=1 ;;
      *) if [[ -z "$tree" ]]; then tree="$a"; elif [[ -z "$tu" ]]; then tu="$a"; else usage; fi ;;
    esac
  done
  [[ -n "$tree" ]] || usage
  tu="${tu:-kernel/fork.c}"
  [[ -d "$tree" ]] || { echo "smoke: no such tree: $tree" >&2; exit 2; }

  local tmp
  tmp="$(mktemp -d)"
  # expand now: $tmp is function-local and gone when the EXIT trap fires
  trap "rm -rf '$tmp'" EXIT

  local -a direct=() viasc=()
  mapfile -d '' -t direct < <(py build-cmd "$tree" "$tu" "$tmp" direct)
  mapfile -d '' -t viasc < <(py build-cmd "$tree" "$tu" "$tmp" sccache)
  [[ ${#direct[@]} -gt 0 && ${#viasc[@]} -gt 0 ]] || { echo "smoke: could not build command" >&2; exit 2; }

  local before after
  before="$(sccache --show-stats | py stats)"
  echo "stats before (dist_ok dist_failed executed): $before"

  echo "== direct: ${direct[0]}"
  (cd "$tree" && "${direct[@]}")
  echo "== sccache (SCCACHE_RECACHE=1)"
  (cd "$tree" && SCCACHE_RECACHE=1 sccache "${viasc[@]}")

  after="$(sccache --show-stats | py stats)"
  echo "stats after  (dist_ok dist_failed executed): $after"

  local rc=0
  local verdict
  if verdict="$(py compare-objects "$tmp/$(basename "${tu%.c}").direct.o" "$tmp/$(basename "${tu%.c}").sccache.o")"; then
    echo "objects: $verdict"
  else
    echo "objects: DIFFER" >&2
    rc=1
  fi

  local b_ok b_fail b_exec a_ok a_fail a_exec
  read -r b_ok b_fail b_exec <<<"$before"
  read -r a_ok a_fail a_exec <<<"$after"
  if (( a_fail > b_fail )); then
    echo "failed distributed compiles rose by $((a_fail - b_fail))" >&2
    rc=1
  fi
  if (( local_ok )); then
    if (( a_exec - b_exec < 1 )); then
      echo "no compile request was executed by sccache" >&2
      rc=1
    fi
  elif (( a_ok - b_ok != 1 )); then
    echo "successful distributed compiles rose by $((a_ok - b_ok)), expected exactly 1" >&2
    rc=1
  fi
  if (( rc == 0 )); then echo "smoke: PASS"; else echo "smoke: FAIL" >&2; fi
  return "$rc"
}

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kernel-dist-bench"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PKG_DIR="$REPO_ROOT/packages/linux-cachyos-jetm"
BUILDDIR_DEFAULT=/var/tmp/makepkg-build

# Prefix each stdin line with an ISO timestamp (moreutils ts is not installed).
tsloop() {
  local line
  while IFS= read -r line; do
    printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$line"
  done
}

# Delete a subdir's objects, rebuild it, print "<objects> <seconds>".
# $1 tree, $2 subdir, $3 mode (local|dist), $4 jobs
probe_build() {
  local tree="$1" sub="$2" mode="$3" jobs="$4" marker t0 t1 n
  find "$tree/$sub" \( -name '*.o' -o -name '*.cmd' \) -type f -delete
  marker="$(mktemp)"
  t0="$(date +%s.%N)"
  if [[ "$mode" == local ]]; then
    PATH="$(py strip-ccache-path "$PATH")" make -C "$tree" LLVM=1 LLVM_IAS=1 LD=ld.lld \
      CC=/usr/bin/clang -j "$jobs" "$sub" >&2
  else
    SCCACHE_RECACHE=1 make -C "$tree" LLVM=1 LLVM_IAS=1 LD=ld.lld \
      CC="sccache /usr/bin/clang" -j "$jobs" "$sub" >&2
  fi
  t1="$(date +%s.%N)"
  n="$(find "$tree/$sub" -name '*.o' -type f -newer "$marker" | wc -l)"
  rm -f "$marker"
  echo "$n $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')"
}

cmd_probe() {
  local tree="${1:-}" sub="${2:-drivers/net/}"
  [[ -n "$tree" && -d "$tree" ]] || { echo "probe: no such tree: ${tree:-}" >&2; exit 2; }
  py safe-subdir "$sub" || { echo "probe: subdir must stay inside the tree: $sub" >&2; exit 2; }
  sub="${sub%/}/"
  [[ -d "$tree/$sub" ]] || { echo "probe: no such subdir: $tree/$sub" >&2; exit 2; }

  local ncpu cpus ln ld lsec dsec lrate drate verdict
  ncpu="$(nproc)"
  cpus="$(sccache --dist-status | py dist-cpus)"
  echo "probe: local -j$ncpu, distributed -j$((ncpu + cpus)) (scheduler cpus: $cpus)"
  read -r ln lsec <<<"$(probe_build "$tree" "$sub" local "$ncpu")"
  read -r ld dsec <<<"$(probe_build "$tree" "$sub" dist "$((ncpu + cpus))")"
  lrate="$(awk -v n="$ln" -v s="$lsec" 'BEGIN { printf "%.3f", s > 0 ? n / s : 0 }')"
  drate="$(awk -v n="$ld" -v s="$dsec" 'BEGIN { printf "%.3f", s > 0 ? n / s : 0 }')"
  echo "local: $ln objects in ${lsec}s = $lrate objects/s"
  echo "dist:  $ld objects in ${dsec}s = $drate objects/s"
  verdict="$(py verdict "$lrate" "$drate")"
  echo "$verdict"
  mkdir -p "$STATE_DIR"
  echo "$verdict" >"$STATE_DIR/probe.verdict"
  [[ "$verdict" == "verdict: dist-wins" ]] || exit 3
}

cmd_run() {
  local label="" force=0 a
  local -a overrides=()
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      *=*) overrides+=("$a") ;;
      *) if [[ -z "$label" ]]; then label="$a"; else usage; fi ;;
    esac
  done
  [[ -n "$label" ]] || usage
  if (( ! force )); then
    py load-check /proc/loadavg || {
      echo "run: one-minute load average above 4 (use --force to override): $(cut -d' ' -f1 /proc/loadavg)" >&2
      exit 4
    }
  fi
  [[ -d "$PKG_DIR" ]] || { echo "run: no package dir: $PKG_DIR" >&2; exit 2; }

  local builddir="${BUILDDIR:-$BUILDDIR_DEFAULT}" pkgdest="$STATE_DIR/pkgs"
  local log="$STATE_DIR/${label}-$(date +%Y%m%dT%H%M%S).log"
  mkdir -p "$pkgdest"
  : >"$log"
  echo "log: $log"

  local marker start end rc
  marker="$(mktemp)"
  start="$(date +%s.%N)"
  echo "== makepkg label=$label overrides=${overrides[*]:-none}" | tsloop >>"$log"
  set +e
  (cd "$PKG_DIR" && env BUILDDIR="$builddir" PKGDEST="$pkgdest" SCCACHE_RECACHE=1 CCACHE_RECACHE=1 \
    "${overrides[@]}" makepkg -fC --noconfirm) 2>&1 | tsloop >>"$log"
  rc="${PIPESTATUS[0]}"
  set -e
  end="$(date +%s.%N)"

  {
    echo "== makepkg exit $rc"
    local p
    for p in "$pkgdest"/*.pkg.tar.zst "$PKG_DIR"/*.pkg.tar.zst; do
      if [[ -e "$p" ]]; then echo "package $(basename "$p") $(stat -c %s "$p") bytes"; fi
    done
  } | tsloop >>"$log"
  find "$pkgdest" -maxdepth 1 -name '*.pkg.tar.zst' -type f -delete
  find "$PKG_DIR" -maxdepth 1 -name '*.pkg.tar.zst' -type f -newer "$marker" -delete
  rm -f "$marker"
  (( rc == 0 )) || { echo "run: makepkg failed (exit $rc), see $log" >&2; exit "$rc"; }

  # Trailing slash keeps directories only: src/ also holds cachyos-*.tar.gz and
  # .tar.gz.asc symlinks, which a bare cachyos-* glob counted as extra trees.
  local -a trees=("$builddir"/linux-cachyos-jetm/src/cachyos-*/)
  trees=("${trees[@]%/}")
  if [[ ${#trees[@]} -ne 1 || ! -d "${trees[0]}" ]]; then
    echo "run: expected exactly one build tree under $builddir/linux-cachyos-jetm/src, got ${#trees[@]}" >&2
    exit 2
  fi
  py run-row "$label" "$(date +%F)" "${trees[0]}" "$start" "$end" "$log" \
    "$(git -C "$REPO_ROOT" rev-parse --short HEAD)" "${overrides[@]}" >>"$STATE_DIR/runs.tsv"
  echo "row appended to $STATE_DIR/runs.tsv"
  tail -n 1 "$STATE_DIR/runs.tsv"
}

cmd_report() {
  py report "$STATE_DIR/runs.tsv" "$STATE_DIR/probe.verdict"
}

case "${1:-}" in
  probe) shift; cmd_probe "$@" ;;
  run) shift; cmd_run "$@" ;;
  report) cmd_report ;;
  timeline) [[ $# -eq 2 ]] || usage; py timeline "$2" ;;
  smoke) shift; cmd_smoke "$@" ;;
  self-test) py self-test ;;
  *) usage ;;
esac
