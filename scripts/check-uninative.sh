#!/usr/bin/env bash
set -euo pipefail

# Emit the version for yocto-uninative-tarball: Arch's glibc pkgver, verbatim
# (e.g. "2.44+r3+g0b05bc142249").
#
# The package builds its uninative tarball from the exact glibc commit Arch
# ships, so the version that matters is Arch's, not the Yocto Project's
# uninative release cadence. Tracking Arch is what keeps the tarball's glibc
# and the host's glibc the same build, which makes the UNINATIVE_MAXGLIBCVERSION
# ceiling exact instead of a judgement call about acceptable skew.
#
# Read from the packaging repo's PKGBUILD rather than the archlinux.org package
# JSON: the JSON exposes only pkgver, whose "+g<12 hex>" suffix is a short sha
# that cannot be fetched over the git protocol. The PKGBUILD carries the full
# 40-char _commit next to it, and update-version.sh needs both.
#
# Used as an nvchecker "cmd" source.

url=https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/raw/main/PKGBUILD

pkgver=$(curl -fsSL "$url" | grep -Po '^pkgver=\K.*')

# Refuse to emit a partial or reshaped version. nvchecker treats whatever lands
# on stdout as the new version, so an empty or truncated value would be
# published as an update and would desync from the _commit that
# update-version.sh writes alongside it.
if [[ ! $pkgver =~ ^[0-9]+\.[0-9]+\+r[0-9]+\+g[0-9a-f]{12}$ ]]; then
	echo "error: unexpected Arch glibc pkgver shape: ${pkgver:-<empty>}" >&2
	exit 1
fi

echo "$pkgver"
