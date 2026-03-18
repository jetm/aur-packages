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

# Bump pkgver and reset pkgrel
sed -i "s/^pkgver=.*/pkgver=$ver/" "$pkgdir/PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=1/" "$pkgdir/PKGBUILD"

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

# Recalculate checksums
(cd "$pkgdir" && updpkgsums)

# Regenerate .SRCINFO
(cd "$pkgdir" && makepkg --printsrcinfo >.SRCINFO)

echo "$pkg updated to $ver"
