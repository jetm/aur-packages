#!/usr/bin/env bash
set -euo pipefail

# Push an updated package to the AUR.
#
# Usage: publish.sh <package-name>
#
# Expects:
#   - SSH key at ~/.ssh/aur (set up by CI or manually)
#   - Git user.name and user.email configured
#   - packages/<name>/PKGBUILD and .SRCINFO to be up to date

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pkg="${1:?Usage: publish.sh <package-name>}"
pkgdir="$REPO_ROOT/packages/$pkg"

if [[ ! -f "$pkgdir/PKGBUILD" ]] || [[ ! -f "$pkgdir/.SRCINFO" ]]; then
	echo "error: PKGBUILD or .SRCINFO missing in $pkgdir" >&2
	exit 1
fi

# SSH setup (idempotent - safe to call multiple times)
setup_ssh() {
	if [[ -n "${AUR_SSH_KEY:-}" ]]; then
		local keyfile="/tmp/aur_ssh_key"
		echo "$AUR_SSH_KEY" >"$keyfile"
		chmod 600 "$keyfile"
		export GIT_SSH_COMMAND="ssh -i $keyfile -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	fi
}

# Git identity (idempotent)
setup_git_identity() {
	if [[ -n "${AUR_USER_NAME:-}" ]]; then
		git config --global user.name "$AUR_USER_NAME"
	fi
	if [[ -n "${AUR_USER_EMAIL:-}" ]]; then
		git config --global user.email "$AUR_USER_EMAIL"
	fi
}

setup_ssh
setup_git_identity

echo "Publishing $pkg to AUR..."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git clone "ssh://aur@aur.archlinux.org/$pkg.git" "$tmp/$pkg"

cp "$pkgdir/PKGBUILD" "$tmp/$pkg/"
cp "$pkgdir/.SRCINFO" "$tmp/$pkg/"

# Copy any extra tracked files (install scripts, changelogs), skip build artifacts
while IFS= read -r relpath; do
	name=$(basename "$relpath")
	if [[ "$name" != "PKGBUILD" ]] && [[ "$name" != ".SRCINFO" ]]; then
		cp "$pkgdir/$name" "$tmp/$pkg/"
	fi
done < <(git -C "$REPO_ROOT" ls-files "packages/$pkg/")

cd "$tmp/$pkg"

# Check if there are actual changes
if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
	echo "$pkg: no changes to publish"
	exit 0
fi

version=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2)
git add -A
git commit -m "Update to $version"
git push

echo "$pkg published to AUR (version $version)"
