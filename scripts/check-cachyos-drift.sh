#!/usr/bin/env bash
set -euo pipefail

# Report drift between packages/linux-cachyos-jetm/PKGBUILD and the upstream
# CachyOS/linux-cachyos PKGBUILD.
#
# nvchecker only tracks the source tarball's version, so a change upstream to
# the patch list, the pinned nvidia/zfs inputs or the makedepends would go
# unnoticed. This compares just those lines - the ones a fork must mirror -
# and leaves the deliberate tuning (HZ, tickrate, bbr, suffix, scheduler)
# out of scope.
#
# Usage: check-cachyos-drift.sh [upstream-PKGBUILD-file]
# Exit: 0 in sync, 1 drift found, 2 could not compare.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
local_pkgbuild="$REPO_ROOT/packages/linux-cachyos-jetm/PKGBUILD"
upstream_url="https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/linux-cachyos/PKGBUILD"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -n "${1:-}" ]]; then
  cp "$1" "$work/upstream"
elif ! curl -fsSL "$upstream_url" -o "$work/upstream"; then
  echo "could not fetch $upstream_url" >&2
  exit 2
fi

# Lines that must match upstream: fetched patch URLs, pinned inputs, the
# signing keys, and the build dependencies. Comments and indentation are
# dropped so a reworded note is not drift.
extract() {
  sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$1" \
    | grep -E '^(_patchsource=|_nv_ver=|source\+=\(.*(_patchsource|zfs\.git)|"\$\{_patchsource\}|[0-9A-F]{40}$|(bc|binutils|cpio|gettext|glibc|libelf|libgcc|openssl|pahole|perl|python|rust|rust-bindgen|rust-src|tar|xxhash|xz|zlib|zstd|clang|llvm|lld)$)' \
    | sort -u || true
}

extract "$work/upstream" >"$work/up.txt"
extract "$local_pkgbuild" >"$work/local.txt"

if [[ ! -s "$work/up.txt" || ! -s "$work/local.txt" ]]; then
  echo "extracted no tracked lines (upstream: $(wc -l <"$work/up.txt"), local: $(wc -l <"$work/local.txt")) - the PKGBUILD layout changed" >&2
  exit 2
fi

if diff -u --label upstream --label local "$work/up.txt" "$work/local.txt"; then
  echo "linux-cachyos-jetm: in sync with upstream ($(wc -l <"$work/up.txt") tracked lines)"
else
  echo "linux-cachyos-jetm: drift from upstream (- upstream only, + local only)" >&2
  exit 1
fi
