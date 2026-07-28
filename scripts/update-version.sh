#!/usr/bin/env bash
set -euo pipefail

# Update a package's PKGBUILD with a new version, recalculate checksums,
# and regenerate .SRCINFO.
#
# Usage: update-version.sh <package-name> <new-version>

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pkg="${1:?Usage: update-version.sh <package-name> <new-version>}"
ver="${2:?Usage: update-version.sh <package-name> <new-version>}"
pkgdir="$REPO_ROOT/packages/$pkg"

if [[ ! -f "$pkgdir/PKGBUILD" ]]; then
	echo "error: $pkgdir/PKGBUILD not found" >&2
	exit 1
fi

echo "Updating $pkg to $ver..."

# linux-cachyos-jetm: nvchecker reports the CachyOS source-tag version, which
# carries the tag's release suffix (7.1.5-1). pkgver may not contain a hyphen,
# and here it is derived rather than literal - pkgver=${_major}.${_minor}, with
# the suffix living in _tagrel because _srcname must reproduce the tag name
# exactly. Writing the whole string into pkgver produced
# "pkgver is not allowed to contain ... hyphens" and no package could be built.
#
# pkgrel follows _tagrel rather than resetting to 1: it is pinned to the distro
# package's pkgrel so that `uname -r` differs from stock only by the -cachyos-jetm
# suffix, and CachyOS's source tag and their package's pkgrel move together.
if [[ "$pkg" == "linux-cachyos-jetm" ]]; then
	kver="${ver%-*}"    # 7.1.5-1 -> 7.1.5
	tagrel="${ver##*-}" # 7.1.5-1 -> 1
	sed -i "s/^_major=.*/_major=${kver%.*}/" "$pkgdir/PKGBUILD"
	sed -i "s/^_minor=.*/_minor=${kver##*.}/" "$pkgdir/PKGBUILD"
	sed -i "s/^_tagrel=.*/_tagrel=$tagrel/" "$pkgdir/PKGBUILD"
	sed -i "s/^pkgrel=.*/pkgrel=$tagrel/" "$pkgdir/PKGBUILD"
else
	# Bump pkgver and reset pkgrel
	sed -i "s/^pkgver=.*/pkgver=$ver/" "$pkgdir/PKGBUILD"
	sed -i "s/^pkgrel=.*/pkgrel=1/" "$pkgdir/PKGBUILD"
fi

# IWYU: also update _clang_major and _clang_minor
if [[ "$pkg" == "include-what-you-use" ]]; then
	iwyu_minor=${ver#0.}
	clang_major=$((iwyu_minor - 4))
	clang_minor=$(curl -fsSL "https://archlinux.org/packages/extra/x86_64/clang/json/" |
		grep -Po '"pkgver"\s*:\s*"\K[^"]+' |
		cut -d. -f2)
	sed -i "s/^_clang_major=.*/_clang_major=$clang_major/" "$pkgdir/PKGBUILD"
	sed -i "s/^_clang_minor=.*/_clang_minor=$clang_minor/" "$pkgdir/PKGBUILD"
fi

# yocto-uninative-tarball: also update _commit. pkgver carries only the
# 12-char short sha, which cannot be fetched over the git protocol, so the
# PKGBUILD pins the full 40-char hash separately. Both are read from the same
# Arch PKGBUILD; if Arch publishes a new glibc between the nvchecker run and
# this fetch, the two desync and the PKGBUILD's prepare() guard catches it.
if [[ "$pkg" == "yocto-uninative-tarball" ]]; then
	commit=$(curl -fsSL \
		"https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/raw/main/PKGBUILD" |
		grep -Po '^_commit=\K[0-9a-f]{40}')
	sed -i "s/^_commit=.*/_commit=$commit/" "$pkgdir/PKGBUILD"
fi

# Recalculate checksums. Skipped for yocto-uninative-tarball: its only remote
# source is a git commit whose checksum is SKIP by definition, and updpkgsums
# would clone glibc's full history to recompute the static local patch hashes
# that a pkgver bump does not change.
if [[ "$pkg" != "yocto-uninative-tarball" ]]; then
	(cd "$pkgdir" && updpkgsums)
fi

# Regenerate .SRCINFO
(cd "$pkgdir" && makepkg --printsrcinfo >.SRCINFO)

echo "$pkg updated to $ver"
