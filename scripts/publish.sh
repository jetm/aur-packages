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
		# Inside $tmp, which the EXIT trap removes. The previous fixed path
		# (/tmp/aur_ssh_key) was covered by no trap at all, so a manual run left
		# the deploy key readable on disk after the script finished.
		local keyfile="$tmp/aur_ssh_key"
		# Strip CR: a key pasted through a Windows editor or some web forms
		# arrives CRLF, which ssh rejects as "invalid format" - a message that
		# reads like an auth problem rather than a mangled secret. echo supplies
		# the trailing newline OpenSSH also requires.
		#
		# umask in a subshell rather than a chmod afterwards: writing first and
		# tightening second leaves the key briefly at the caller's umask, which
		# on a permissive one is world-readable.
		(
			umask 077
			printf '%s\n' "$AUR_SSH_KEY" | tr -d '\r' >"$keyfile"
		)

		# Fail here rather than letting git report "Permission denied
		# (publickey)", which sends you looking at the AUR account when the
		# problem is the secret itself. The key must also be passphrase-less:
		# ssh runs with no agent below and nothing can answer a prompt.
		local derived
		if ! derived=$(ssh-keygen -y -f "$keyfile" 2>/dev/null); then
			echo "error: AUR_SSH_KEY is not a usable private key." >&2
			echo "  It must be the PRIVATE half (not .pub), unencrypted, with newlines intact." >&2
			echo "  Set it straight from the file to avoid copy-paste damage:" >&2
			echo "    gh secret set AUR_SSH_KEY < ~/.ssh/aur" >&2
			exit 1
		fi

		# The public half of the key registered on the AUR account. Public key
		# material, so safe to keep in the repo.
		#
		# A warning rather than an error: if the secret really is the wrong key
		# the push fails on its own a few seconds later, and this explains why
		# instead of leaving "Permission denied (publickey)" to be read as an
		# AUR-account problem. Failing hard here would instead break the
		# legitimate case where the key was rotated and the secret updated but
		# this line was not - turning a rotation into a broken pipeline.
		#
		# Compare type and base64 only; ssh-keygen -y may append a comment
		# carried over from the private key file.
		local expected='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9hSWefUCCNjTdLmJqNibVIvdTYiIHh/wGh1CFIzIG/'
		if [[ "$(printf '%s' "$derived" | cut -d' ' -f1,2)" != "$expected" ]]; then
			echo "warning: AUR_SSH_KEY does not match the key recorded in publish.sh." >&2
			echo "  expected: $expected" >&2
			echo "  secret:   $(printf '%s' "$derived" | cut -d' ' -f1,2)" >&2
			echo "  If the AUR key was rotated, update 'expected' above; otherwise the" >&2
			echo "  secret is wrong and the push below will fail with 'Permission denied'." >&2
		fi

		export GIT_SSH_COMMAND="ssh -i $keyfile -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	fi
}

# Git identity: use env vars, fall back to existing git config
setup_git_identity() {
	: "${AUR_USER_NAME:=$(git config user.name 2>/dev/null || true)}"
	: "${AUR_USER_EMAIL:=$(git config user.email 2>/dev/null || true)}"

	if [[ -z "$AUR_USER_NAME" ]] || [[ -z "$AUR_USER_EMAIL" ]]; then
		echo "error: git user.name/user.email not configured and AUR_USER_NAME/AUR_USER_EMAIL not set" >&2
		exit 1
	fi

	git config --global user.name "$AUR_USER_NAME"
	git config --global user.email "$AUR_USER_EMAIL"
}

# Before setup_ssh, not after: the deploy key is written inside $tmp so the
# trap disposes of it, which means both have to exist first.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

setup_ssh
setup_git_identity

echo "Publishing $pkg to AUR..."

git clone "ssh://aur@aur.archlinux.org/$pkg.git" "$tmp/$pkg"

# AUR only accepts pushes to master; ensure correct branch for new (empty) repos
git -C "$tmp/$pkg" checkout -B master 2>/dev/null || true

cp "$pkgdir/PKGBUILD" "$tmp/$pkg/"
cp "$pkgdir/.SRCINFO" "$tmp/$pkg/"

# Collect the local files this package needs alongside PKGBUILD/.SRCINFO:
# every `source =` entry that is not a URL, plus `install =` and `changelog =`.
#
# Read from .SRCINFO rather than `git ls-files` (which this used to do) for two
# reasons. The workspace often has no .git at all: the CI container is
# archlinux:base-devel, which ships no git, so actions/checkout falls back to a
# REST-API tarball ("The repository will be downloaded using the GitHub REST
# API"). `git ls-files` then failed with "not a git repository" - and because it
# sat in a process substitution, set -e did not fire, so the loop read nothing
# and the AUR commit silently went out with only PKGBUILD and .SRCINFO. That was
# invisible for years because every other package has no extra files; the first
# package carrying patches got rejected by AUR's hook instead.
#
# .SRCINFO is also the more precise source of truth: it lists exactly the files
# AUR's server-side hook checks for, and a downloaded tarball sitting in the
# package directory is never a local source entry, so build artifacts are
# excluded by construction rather than by pattern-matching them out.
#
# An entry containing "://" is remote (makepkg fetches it). The `name::target`
# rename form keeps the on-disk name after the last "::".
# NOT `mapfile -t wanted < <(awk ...)`: mapfile reports its own status, never
# the process substitution's, so an awk that dies or matches nothing yields an
# empty array and a clean exit - which is precisely how the `git ls-files`
# version of this code shipped an AUR commit with no patches in it. Capture
# first, check the status, then split.
if ! wanted_raw=$(
	awk -F' = ' '
		$1 ~ /^[[:space:]]*(source(_[a-zA-Z0-9_]+)?|install|changelog)$/ {
			v = $2
			if (v ~ /:\/\//) next
			sub(/^.*::/, "", v)
			if (v != "") print v
		}
	' "$pkgdir/.SRCINFO" | sort -u
); then
	echo "error: failed to read the local source list from $pkgdir/.SRCINFO" >&2
	exit 1
fi

wanted=()
if [[ -n $wanted_raw ]]; then
	mapfile -t wanted <<<"$wanted_raw"
fi

# Independent cross-check on the parse itself. If .SRCINFO declares local
# sources but the parse produced none, the parse is wrong - a key spelling or
# separator change in a future makepkg would otherwise silently reproduce the
# original bug with a different cause.
declared_local=$(grep -E \
	'^[[:space:]]*(source(_[a-zA-Z0-9_]+)?|install|changelog) = ' \
	"$pkgdir/.SRCINFO" 2>/dev/null | grep -vc '://' || true)
if [[ ${declared_local:-0} -gt 0 ]] && ((${#wanted[@]} == 0)); then
	echo "error: $pkgdir/.SRCINFO declares $declared_local local source file(s)" >&2
	echo "  but the parser matched none. Refusing to publish an incomplete commit." >&2
	exit 1
fi

missing=()
if ((${#wanted[@]} > 0)); then
	for name in "${wanted[@]}"; do
		if [[ -f "$pkgdir/$name" ]]; then
			cp "$pkgdir/$name" "$tmp/$pkg/"
		else
			missing+=("$name")
		fi
	done
fi

# Fail here rather than letting AUR reject the push. The remote's message
# ("missing source file: ...", "hook declined to update refs/heads/master")
# arrives after the build has already run and reads like a permissions problem.
if ((${#missing[@]} > 0)); then
	echo "error: .SRCINFO lists local files that are not in $pkgdir:" >&2
	printf '  %s\n' "${missing[@]}" >&2
	echo "  AUR rejects any commit whose source files are not included." >&2
	exit 1
fi

# Drop anything the package no longer declares. This script only ever copied
# files in, so a source removed from the PKGBUILD stayed on the AUR forever.
# The kernel package was carrying six such orphans: five superseded XFS patches
# and the nofs patch dropped on 2026-07-28, whose own PKGBUILD comment says it
# was removed. That is worse than clutter - the snapshot implies patches the
# PKGBUILD does not apply, so anyone reading it to answer "what is in this
# kernel" gets the wrong answer.
#
# Keyed on the same `wanted` list the copy loop uses, so the two cannot
# disagree about what belongs. Driven by git ls-files rather than the
# directory, which leaves .git alone without special-casing it.
declare -A keep=([PKGBUILD]=1 [.SRCINFO]=1)
for name in ${wanted[@]+"${wanted[@]}"}; do
	keep["$name"]=1
done

while IFS= read -r tracked; do
	if [[ -z ${keep[$tracked]:-} ]]; then
		git -C "$tmp/$pkg" rm -q -- "$tracked"
		echo "pruned $tracked (no longer declared by the PKGBUILD)"
	fi
done < <(git -C "$tmp/$pkg" ls-files)

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
