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

# Recalculate checksums
(cd "$pkgdir" && updpkgsums)

# Regenerate .SRCINFO
(cd "$pkgdir" && makepkg --printsrcinfo >.SRCINFO)

echo "$pkg updated to $ver"
