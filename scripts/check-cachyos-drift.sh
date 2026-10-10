#!/usr/bin/env bash
set -euo pipefail

# Report drift between packages/linux-cachyos-jetm/PKGBUILD and the upstream
# CachyOS/linux-cachyos PKGBUILD.
#
# nvchecker only tracks the source tarball's version, so a change upstream to
# the patch list, the pinned nvidia/zfs inputs, the makedepends or the packaging
# functions would go unnoticed. This compares the declarative lines a fork must
# mirror plus the bodies of the _package* and _sign_modules functions, and
# leaves the deliberate tuning (HZ, tickrate, bbr, suffix, scheduler) out of
# scope.
#
# The one deliberate difference inside a packaging function is dropping
# replaces=(linux-cachyos-lto[-headers]) and the matching provides, so those
# lines (and an if-block left holding only them) are removed from both sides
# before comparing.
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

# Comments and indentation are dropped so a reworded note is not drift.
normalize() {
  sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' || true
}

# Lines that must match upstream: fetched patch URLs, pinned inputs, the
# signing keys, and the build dependencies. Sorted, so order is not drift.
extract_lines() {
  normalize <"$1" \
    | grep -E '^(_patchsource=|_nv_ver=|source\+=\(.*(_patchsource|zfs\.git)|"\$\{_patchsource\}|[0-9A-F]{40}$|(bc|binutils|cpio|gettext|glibc|libelf|libgcc|openssl|pahole|perl|python|rust|rust-bindgen|rust-src|tar|xxhash|xz|zlib|zstd|clang|llvm|lld)$)' \
    | sort -u || true
}

# Packaging function bodies, in file order: a reordered step is a behavior
# change, so this one is not sorted.
extract_functions() {
  perl -0777 -pe 's/if _is_lto_kernel; then\n\s*provides\+=\(linux-cachyos-lto[^\n]*\n\s*replaces=[^\n]*\n\s*fi\n//g; s/^\s*(provides\+=|replaces=)\(linux-cachyos-lto[^\n]*\n//mg' "$1" \
    | awk '/^(_package[-a-z0-9]*|_sign_modules)\(\) *\{/ {p=1} p {print} /^}/ {p=0}' \
    | normalize
}

extract_lines "$work/upstream" >"$work/up.txt"
extract_lines "$local_pkgbuild" >"$work/local.txt"
extract_functions "$work/upstream" >"$work/up-fn.txt"
extract_functions "$local_pkgbuild" >"$work/local-fn.txt"

# A side with nothing extracted means the layout changed, not that it is in sync.
for f in up local up-fn local-fn; do
  if [[ ! -s "$work/$f.txt" ]]; then
    echo "extracted no lines for $f - the PKGBUILD layout changed" >&2
    exit 2
  fi
done

rc=0
diff -u --label upstream --label local "$work/up.txt" "$work/local.txt" || rc=1
diff -u --label upstream-functions --label local-functions "$work/up-fn.txt" "$work/local-fn.txt" || rc=1

if [[ $rc -eq 0 ]]; then
  echo "linux-cachyos-jetm: in sync with upstream ($(wc -l <"$work/up.txt") tracked lines, $(wc -l <"$work/up-fn.txt") function lines)"
else
  echo "linux-cachyos-jetm: drift from upstream (- upstream only, + local only)" >&2
fi
exit "$rc"
