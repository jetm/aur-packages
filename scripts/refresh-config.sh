#!/usr/bin/env bash
set -euo pipefail

# Refresh linux-cachyos-jetm's tracked config baseline from a real local
# build, and commit the result. Not parameterized like its siblings: the
# "config-<pkgver>-<pkgrel><suffix>" artifact this reads is written only by
# this PKGBUILD's own prepare() ("Save configuration for later reuse"), and
# no other package in this repo produces one.
#
# Usage: refresh-config.sh
#
# Run this after a successful local `makepkg` for linux-cachyos-jetm. CI
# never builds this package (see the exemption in
# .github/workflows/update.yml) - a hosted runner has neither the disk/time
# for a ThinLTO kernel build nor a config worth trusting, since
# CONFIG_X86_NATIVE_CPU ties the result to the building CPU. This is the
# only place the baseline can be refreshed from.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pkgdir="$REPO_ROOT/packages/linux-cachyos-jetm"

if [[ ! -f "$pkgdir/PKGBUILD" ]]; then
	echo "error: $pkgdir/PKGBUILD not found" >&2
	exit 1
fi

# This script commits on its own with no review step (by request), so it
# must not fold in unrelated edits sitting in these files. A dirty PKGBUILD
# here means someone was mid-edit; bail rather than guess what belongs in
# the commit.
if ! git -C "$pkgdir" diff --quiet -- PKGBUILD .SRCINFO config; then
	echo "error: PKGBUILD, .SRCINFO, or config has uncommitted changes already." >&2
	echo "  Commit or stash those first - this script commits on its own and" >&2
	echo "  would otherwise bundle them in with the config refresh." >&2
	exit 1
fi

# Pure variable assignments and function/array definitions - no network
# calls, no _die branch taken with the default BUILD OPTIONS - so sourcing
# is safe and reuses the PKGBUILD's own suffix-selection logic instead of
# re-deriving it here. Pre-declared so shellcheck sees an assignment before
# the uses below (source's own target is dynamic, so it can't follow it).
pkgver=
pkgrel=
pkgbase=
# shellcheck source=/dev/null
source "$pkgdir/PKGBUILD"

saved_config="$pkgdir/config-${pkgver}-${pkgrel}${pkgbase#linux}"

if [[ ! -f "$saved_config" ]]; then
	echo "error: $saved_config not found" >&2
	echo "  Run a local 'makepkg' for linux-cachyos-jetm first - prepare()'s" >&2
	echo "  own 'save configuration for later reuse' step writes this file." >&2
	exit 1
fi

if diff -q "$pkgdir/config" "$saved_config" >/dev/null; then
	echo "linux-cachyos-jetm: config baseline already matches the $pkgver-$pkgrel build"
	exit 0
fi

changed=$(diff "$pkgdir/config" "$saved_config" | grep -c '^[<>]' || true)

cp "$saved_config" "$pkgdir/config"
(cd "$pkgdir" && updpkgsums)
(cd "$pkgdir" && makepkg --printsrcinfo >.SRCINFO)

cd "$pkgdir"
git add config .SRCINFO PKGBUILD

git commit -s -m "linux-cachyos-jetm: Refresh the config baseline from the $pkgver-$pkgrel build" -m "$(
	cat <<EOF
Read back from this host's own config-$pkgver-$pkgrel${pkgbase#linux},
the artifact prepare()'s own "save configuration for later reuse" step
writes after \`yes "" | make config\` resolves that release's new Kconfig
defaults - the post-prepare() state, not an upstream drop. $changed line(s)
changed from the previous baseline.
EOF
)"

echo "linux-cachyos-jetm: config baseline refreshed to $pkgver-$pkgrel ($changed line(s) changed)"
