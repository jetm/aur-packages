#!/usr/bin/env bash
set -euo pipefail

# Emit the version for linux-cachyos-jetm: the newest stable CachyOS/linux
# release, plus how many times CachyOS has changed the patches this package
# fetches since that release was published.
#
#   7.3.0-2     release cachyos-7.3.0-2, patches unchanged since
#   7.3.0-2.1   same release, one patch commit since (CachyOS rebuilt)
#
# CachyOS can publish a new package revision with no new release tag: linux-cachyos
# went 7.3.0-2 -> 7.3.0-3 after its BORE patch changed, while the tarball stayed
# cachyos-7.3.0-2 and the change was a commit in CachyOS/kernel-patches. This
# package fetches patches from there at build time (dkms-clang, plus the BORE
# patch when built with _cpusched=bore), so the release tag alone cannot say when
# a rebuild is due. Counting commits to exactly the files this build fetches does,
# and unlike following the distro package's revision it ignores patches this
# build never applies (nvidia, prjc, handheld). Which files those are is read
# from the PKGBUILD, not modelled here.
#
# update-version.sh splits "<tagrel>.<n>" back apart, so the tarball tag it
# writes into _srcname stays the real release tag.
#
# Used as an nvchecker "cmd" source. GITHUB_TOKEN, when set, lifts the API rate
# limit.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pkgbuild="$REPO_ROOT/packages/linux-cachyos-jetm/PKGBUILD"

# Ask the PKGBUILD which kernel-patches files this build fetches, rather than
# modelling them here. The set depends on _cpusched (the BORE family adds the
# BORE patch, eevdf adds none), on the LLVM block (dkms-clang) and on the
# nvidia and hardened options, and a copy of that logic in this script went
# stale as soon as the default scheduler changed: the script refused to run, and
# because nvchecker exits 0 when a source fails, the kernel stopped being
# reported without any visible error.
#
# The PKGBUILD is sourced in a subshell, as refresh-config.sh does. SRCDEST and
# startdir are unset, which makes its _purge_fetched_patches a no-op, so nothing
# in the package directory is deleted. Only lines shaped like a patch path are
# kept, so anything the PKGBUILD prints while being sourced cannot leak into the
# list.
fetched_paths() {
	(
		set +eu
		unset SRCDEST startdir
		# Declared so a PKGBUILD that sets neither reads as empty, and so shellcheck
		# sees an assignment: both are really set by the file sourced below.
		source=()
		_patchsource=
		# shellcheck source=/dev/null
		source "$pkgbuild" >/dev/null
		[[ ${#source[@]} -gt 0 && -n ${_patchsource:-} ]] || exit 3
		for entry in "${source[@]}"; do
			url=${entry#*::}
			[[ $url == "$_patchsource"/* ]] && printf '%s\n' "${url#"$_patchsource"/}"
		done
		exit 0
	)
}
if ! patch_paths=$(fetched_paths); then
	echo "error: could not read the fetched patch list from $pkgbuild" >&2
	exit 1
fi
patch_paths=$(grep -E '^[A-Za-z0-9_./+-]+\.patch$' <<<"$patch_paths" | sort -u || true)

auth=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
	auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi
api() {
	curl -fsSL "${auth[@]}" -H 'Accept: application/vnd.github+json' "$1"
}

# Same selection the github source made before: the highest stable
# cachyos-X.Y.Z-N release. rc releases are not flagged as prereleases by
# CachyOS, and their tags (cachyos-7.3-rc6-1) do not match this shape.
releases=$(api 'https://api.github.com/repos/CachyOS/linux/releases?per_page=50')
read -r tag published < <(python3 -I -c '
import json, re, sys
pat = re.compile(r"^cachyos-(\d+)\.(\d+)(?:\.(\d+))?-(\d+)$")
best = None
for r in json.load(sys.stdin):
    m = pat.match(r["tag_name"])
    if not m or r.get("prerelease") or r.get("draft"):
        continue
    key = tuple(int(x or 0) for x in m.groups())
    if best is None or key > best[0]:
        best = (key, r)
if best is None:
    sys.exit("no stable cachyos-X.Y.Z-N release found")
print(best[1]["tag_name"], best[1]["published_at"])
' <<<"$releases")

ver=${tag#cachyos-}
kver=${ver%-*}
tagrel=${ver##*-}
series=${kver%.*}

shas=
while IFS= read -r relpath; do
	[[ -n $relpath ]] || continue
	path="$series/$relpath"
	# A series CachyOS has not published patches for yet would make the build
	# fail in prepare(); fail here instead, before a bump is published.
	api "https://api.github.com/repos/CachyOS/kernel-patches/contents/$path" >/dev/null
	commits=$(api "https://api.github.com/repos/CachyOS/kernel-patches/commits?path=$path&since=$published&per_page=100")
	shas+=$(python3 -I -c 'import json, sys; print("\n".join(c["sha"] for c in json.load(sys.stdin)))' <<<"$commits")$'\n'
done <<<"$patch_paths"
n=$(printf '%s' "$shas" | sort -u | sed '/^$/d' | wc -l)
nfiles=$(sed '/^$/d' <<<"$patch_paths" | wc -l)
echo "tracking $nfiles kernel-patches file(s) for series $series: $(tr '\n' ' ' <<<"$patch_paths")- $n commit(s) since $published" >&2

if ((n > 0)); then
	out="$kver-$tagrel.$n"
else
	out="$kver-$tagrel"
fi

# nvchecker publishes whatever lands on stdout as the new version, so refuse a
# shape update-version.sh cannot split.
if [[ ! $out =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9]+(\.[0-9]+)?$ ]]; then
	echo "error: unexpected version shape: ${out:-<empty>}" >&2
	exit 1
fi
echo "$out"
