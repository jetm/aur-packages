#!/usr/bin/env bash
# Kernel build distributed-compile benchmark helpers.
#
#   timeline <tree>                   phase table from a finished build tree's mtimes
#   smoke <tree> [--local] [tu]       one Kbuild TU: direct clang vs sccache clang
#   self-test                         offline checks of the parsing helpers
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/kernel-dist-bench-helper.py"

usage() {
  echo "usage: $0 timeline <tree> | smoke <tree> [--local] [tu] | self-test" >&2
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
  if cmp "$tmp/$(basename "${tu%.c}").direct.o" "$tmp/$(basename "${tu%.c}").sccache.o"; then
    echo "objects: identical"
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

case "${1:-}" in
  timeline) [[ $# -eq 2 ]] || usage; py timeline "$2" ;;
  smoke) shift; cmd_smoke "$@" ;;
  self-test) py self-test ;;
  *) usage ;;
esac
