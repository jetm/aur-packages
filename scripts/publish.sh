#!/usr/bin/env bash
set -euo pipefail

# Push an updated package to the AUR.
#
# Usage: publish.sh [--committed] <package-name>
#
# Expects:
#   - SSH key at ~/.ssh/aur (set up by CI or manually)
#   - Git user.name and user.email configured
#   - packages/<name>/PKGBUILD and .SRCINFO to be up to date
#
# By default the package files are read from the working tree, which is what CI
# needs: update-version.sh bumps them there and the commit job records the bump
# only after this step, so HEAD still holds the previous version.
#
# --committed, for a manual run, publishes the package directory as it is
# committed at HEAD instead. Uncommitted edits and untracked or ignored files
# (downloaded sources, build artifacts) cannot reach the AUR, and the committed
# .SRCINFO must match `makepkg --printsrcinfo` or nothing is pushed. A stale
# checksum left uncommitted in a working tree would have gone out through the
# default mode; it was noticed before it did. Not usable as root, because
# makepkg refuses to run there.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

committed=0
if [[ "${1:-}" == "--committed" ]]; then
	committed=1
	shift
fi

pkg="${1:?Usage: publish.sh [--committed] <package-name>}"
pkgdir="$REPO_ROOT/packages/$pkg"

if ((committed)) && ((EUID == 0)); then
	echo "error: --committed runs makepkg, which refuses to run as root" >&2
	exit 1
fi

if ((!committed)) && { [[ ! -f "$pkgdir/PKGBUILD" ]] || [[ ! -f "$pkgdir/.SRCINFO" ]]; }; then
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

if ((committed)); then
	# Read the package from HEAD, not the working tree. git archive of the
	# package's own tree writes its contents at the extraction root, so the
	# rest of this script reads $pkgdir exactly as it did before.
	if ! git -C "$REPO_ROOT" cat-file -e "HEAD:packages/$pkg/.SRCINFO" 2>/dev/null ||
		! git -C "$REPO_ROOT" cat-file -e "HEAD:packages/$pkg/PKGBUILD" 2>/dev/null; then
		echo "error: packages/$pkg/PKGBUILD or .SRCINFO is not committed at HEAD" >&2
		exit 1
	fi
	if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- "packages/$pkg")" ]]; then
		echo "warning: uncommitted changes in packages/$pkg are not published" >&2
	fi
	pkgdir="$tmp/head-$pkg"
	mkdir -p "$pkgdir"
	git -C "$REPO_ROOT" archive "HEAD:packages/$pkg" | tar -x -C "$pkgdir"

	# The committed .SRCINFO must be what makepkg would write for the committed
	# PKGBUILD. An empty result is not a match, so a makepkg that failed to run
	# cannot pass this check by printing nothing.
	if ! fresh=$(cd "$pkgdir" && makepkg --printsrcinfo) || [[ -z "$fresh" ]]; then
		echo "error: makepkg --printsrcinfo failed in the committed $pkg" >&2
		exit 1
	fi
	if ! diff -u "$pkgdir/.SRCINFO" <(printf '%s\n' "$fresh"); then
		echo "error: committed .SRCINFO is stale for $pkg; regenerate it and commit before publishing" >&2
		exit 1
	fi
fi

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

pruned=()
while IFS= read -r tracked; do
	if [[ -z ${keep[$tracked]:-} ]]; then
		git -C "$tmp/$pkg" rm -q -- "$tracked"
		pruned+=("$tracked")
		echo "pruned $tracked (no longer declared by the PKGBUILD)"
	fi
done < <(git -C "$tmp/$pkg" ls-files)

cd "$tmp/$pkg"

# Check if there are actual changes
if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
	echo "$pkg: no changes to publish"
	exit 0
fi

# Read the version from .SRCINFO, not from the PKGBUILD's pkgver= assignment.
# That assignment is a literal for most packages but derived in
# linux-cachyos-jetm (pkgver=${_major}.${_minor}), where grepping it published
# the AUR commit message "Update to ${_major}.${_minor}" verbatim. .SRCINFO
# carries the expanded value because makepkg wrote it after evaluating the
# PKGBUILD, so it is right for both shapes without this script sourcing
# anything.
version=$(awk -F' = ' '$1 ~ /^[[:space:]]*pkgver$/ {print $2; exit}' .SRCINFO)
if [[ -z $version ]]; then
	echo "error: no pkgver in $pkgdir/.SRCINFO" >&2
	exit 1
fi

git add -A

# Describe what the push actually does. A push that only removes files is not
# an update, and titling it "Update to $version" hides the removal from anyone
# reading the AUR history to work out when a patch stopped being applied -
# which is the one question that history gets asked.
if git diff --cached --name-only --diff-filter=d | grep -q .; then
	subject="Update to $version"
else
	subject="Remove ${#pruned[@]} source file(s) no longer declared by the PKGBUILD"
fi

if ((${#pruned[@]} > 0)); then
	git commit -m "$subject" -m "$(printf 'Pruned:\n'; printf -- '- %s\n' "${pruned[@]}")"
else
	git commit -m "$subject"
fi
git push

echo "$pkg published to AUR (version $version)"
