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

# linux-cachyos-jetm: nvchecker reports "<kernel>-<tagrel>[.<n>]" from
# check-cachyos-release.sh: the CachyOS source-tag version (7.1.5-1), plus ".n"
# when CachyOS changed the patches this package fetches n times since that tag
# was published (7.1.5-1.2). pkgver may not contain a hyphen, and here it is
# derived rather than literal - pkgver=${_major}.${_minor}, with the tag suffix
# living in _tagrel because _srcname must reproduce the tag name exactly.
# Writing the whole string into pkgver produced "pkgver is not allowed to
# contain ... hyphens" and no package could be built.
#
# pkgrel is tagrel + n, which matches how CachyOS numbered a patch-only rebuild
# (linux-cachyos 7.3.0-2 -> 7.3.0-3), so `uname -r` stays comparable with the
# distro kernel. It must also grow with every build at the same kernel version:
# an equal pkgrel reinstalls over the running kernel's module tree. So when the
# kernel version is unchanged, pkgrel is at least one above the current one.
if [[ "$pkg" == "linux-cachyos-jetm" ]]; then
	kver="${ver%-*}"           # 7.1.5-1.2 -> 7.1.5
	rev="${ver##*-}"           # 7.1.5-1.2 -> 1.2
	tagrel="${rev%%.*}"        # 1.2 -> 1
	patches=0
	[[ "$rev" == *.* ]] && patches="${rev#*.}" # 1.2 -> 2
	pkgrel=$((tagrel + patches))
	current_kver="$(sed -n 's/^_major=//p' "$pkgdir/PKGBUILD").$(sed -n 's/^_minor=//p' "$pkgdir/PKGBUILD")"
	current_pkgrel="$(sed -n 's/^pkgrel=//p' "$pkgdir/PKGBUILD")"
	if [[ "$current_kver" == "$kver" && "$current_pkgrel" -ge "$pkgrel" ]]; then
		pkgrel=$((current_pkgrel + 1))
	fi
	sed -i "s/^_major=.*/_major=${kver%.*}/" "$pkgdir/PKGBUILD"
	sed -i "s/^_minor=.*/_minor=${kver##*.}/" "$pkgdir/PKGBUILD"
	sed -i "s/^_tagrel=.*/_tagrel=$tagrel/" "$pkgdir/PKGBUILD"
	sed -i "s/^pkgrel=.*/pkgrel=$pkgrel/" "$pkgdir/PKGBUILD"
else
	# Bump pkgver and reset pkgrel
	sed -i "s/^pkgver=.*/pkgver=$ver/" "$pkgdir/PKGBUILD"
	sed -i "s/^pkgrel=.*/pkgrel=1/" "$pkgdir/PKGBUILD"
fi

# IWYU: also update _clang_major and _clang_minor
if [[ "$pkg" == "include-what-you-use" ]]; then
	# IWYU pins depends=(clang>=X.Y clang<(X+1).0) to one exact clang major -
	# Arch ships only the current rolling major, so X must be THAT major, not
	# a version-arithmetic guess. The "IWYU 0.N needs clang N-4" rule used to
	# track Arch in lockstep but drifted once IWYU's release cadence slowed:
	# IWYU shipped one release (0.26) in the 13 months Arch's clang moved
	# 21->23, so N-4 pointed at clang 22, which Arch no longer carries at
	# all (confirmed 2026-10-02: 0.26 built and ran correctly against the
	# installed clang/llvm 23.1.1, two majors past what N-4 predicted). Read
	# the major Arch actually ships instead of deriving it.
	arch_clang_ver=$(curl -fsSL "https://archlinux.org/packages/extra/x86_64/clang/json/" |
		grep -Po '"pkgver"\s*:\s*"\K[^"]+')
	clang_major=${arch_clang_ver%%.*}
	clang_minor=$(cut -d. -f2 <<<"$arch_clang_ver")
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
