#!/usr/bin/env bash
set -euo pipefail

# Refresh linux-cachyos-jetm's tracked config baseline from a real local
# build, and commit the result. Not parameterized like its siblings: the
# config it reads is written only by this PKGBUILD's own prepare(), and no
# other package in this repo produces one.
#
# Usage: refresh-config.sh [--from-installed]
#
#   (no flag)         read the "config-<pkgver>-<pkgrel><suffix>" artifact that
#                     prepare()'s "Save configuration for later reuse" step wrote
#                     into this package directory. Run it after a successful
#                     local `makepkg`.
#   --from-installed  read the .config shipped in the installed
#                     linux-cachyos-jetm-headers package instead. That file is
#                     the same post-prepare() artifact (byte-identical to
#                     /proc/config.gz once that kernel is the one booted; before
#                     the reboot /proc/config.gz still describes the old one),
#                     and it exists after an AUR helper built the package in its
#                     own cache, where the local artifact never reaches this
#                     checkout.
#
# CI never builds this package (see the exemption in
# .github/workflows/update.yml) - a hosted runner has neither the disk/time
# for a ThinLTO kernel build nor a config worth trusting, since
# CONFIG_X86_NATIVE_CPU ties the result to the building CPU. A local build is
# the only place the baseline can be refreshed from.
#
# Exit: 0 refreshed or already current, 1 could not refresh.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pkgdir="$REPO_ROOT/packages/linux-cachyos-jetm"

mode=local
case "${1:-}" in
"") ;;
--from-installed) mode=installed ;;
*)
	echo "usage: ${0##*/} [--from-installed]" >&2
	exit 1
	;;
esac

if [[ ! -f "$pkgdir/PKGBUILD" ]]; then
	echo "error: $pkgdir/PKGBUILD not found" >&2
	exit 1
fi

# This script commits on its own with no review step (by request), so it
# must not fold in unrelated edits sitting in these files. A dirty PKGBUILD
# here means someone was mid-edit; bail rather than guess what belongs in
# the commit. Compared against HEAD, so a refresh left staged by a commit that
# failed (an armed guard, a hook) is caught too instead of reading as current.
if ! git -C "$pkgdir" diff --quiet HEAD -- PKGBUILD .SRCINFO config; then
	echo "error: PKGBUILD, .SRCINFO, or config has uncommitted changes already." >&2
	echo "  Commit or stash those first - this script commits on its own and" >&2
	echo "  would otherwise bundle them in with the config refresh." >&2
	exit 1
fi

if [[ "$mode" == installed ]]; then
	headers=linux-cachyos-jetm-headers
	if ! installed_version=$(pacman -Q "$headers" 2>/dev/null | awk '{print $2}') || [[ -z "$installed_version" ]]; then
		echo "error: $headers is not installed, so there is no installed config to read" >&2
		exit 1
	fi
	saved_config=$(pacman -Ql "$headers" | awk '$2 ~ /\/build\/\.config$/ {print $2; exit}')
	if [[ -z "$saved_config" || ! -r "$saved_config" ]]; then
		echo "error: $headers ships no readable build/.config (got '${saved_config:-nothing}')" >&2
		exit 1
	fi
	label="$installed_version"
	origin="the installed $headers package's build/.config ($saved_config),
the artifact prepare()'s own \"save configuration for later reuse\" step
produces after \`yes \"\" | make config\` resolves that release's new Kconfig
defaults - the post-prepare() state, not an upstream drop. An AUR helper
built that package in its own cache, so the local artifact never reached
this checkout."

	# The commit is made on whatever is checked out, so it must be the branch
	# that gets pushed, and it must sit on top of what the remote has - a
	# refresh committed on a stale checkout would diverge from origin.
	branch=$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD || true)
	if [[ "$branch" != main ]]; then
		echo "error: $REPO_ROOT is on '${branch:-a detached HEAD}', not main - refusing to commit the refresh there" >&2
		exit 1
	fi
	if ! git -C "$REPO_ROOT" pull --ff-only --quiet; then
		echo "error: could not fast-forward $REPO_ROOT from origin; reconcile it and rerun" >&2
		exit 1
	fi
else
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

	label="$pkgver-$pkgrel"
	origin="this host's own config-$pkgver-$pkgrel${pkgbase#linux},
the artifact prepare()'s own \"save configuration for later reuse\" step
writes after \`yes \"\" | make config\` resolves that release's new Kconfig
defaults - the post-prepare() state, not an upstream drop."
fi

if diff -q "$pkgdir/config" "$saved_config" >/dev/null; then
	echo "linux-cachyos-jetm: config baseline already matches the $label build"
	exit 0
fi

changed=$(diff "$pkgdir/config" "$saved_config" | grep -c '^[<>]' || true)

cp "$saved_config" "$pkgdir/config"
(cd "$pkgdir" && updpkgsums)
(cd "$pkgdir" && makepkg --printsrcinfo >.SRCINFO)

cd "$pkgdir"
git add config .SRCINFO PKGBUILD

git commit -s -m "linux-cachyos-jetm: Refresh the config baseline from the $label build" \
	-m "Read back from $origin" \
	-m "$changed line(s) changed from the previous baseline."

echo "linux-cachyos-jetm: config baseline refreshed to $label ($changed line(s) changed)"
