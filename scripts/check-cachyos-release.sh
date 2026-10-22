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
# package fetches the BORE and dkms-clang patches from there at build time, so
# the release tag alone cannot say when a rebuild is due. Counting commits to
# exactly the files this package fetches does, and unlike following the distro
# package's revision it ignores patches this build never applies (nvidia,
# prjc, handheld).
#
# update-version.sh splits "<tagrel>.<n>" back apart, so the tarball tag it
# writes into _srcname stays the real release tag.
#
# Used as an nvchecker "cmd" source. GITHUB_TOKEN, when set, lifts the API rate
# limit.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pkgbuild="$REPO_ROOT/packages/linux-cachyos-jetm/PKGBUILD"

# The fetched patch set is derived from _cpusched. Only the BORE layout is
# modelled here, so another default fails loudly instead of counting the wrong
# files and never reporting a change.
sched=$(grep -Po '^: "\$\{_cpusched:=\K[^}]+' "$pkgbuild" || true)
if [[ "$sched" != bore ]]; then
	echo "error: _cpusched default is '${sched:-<not found>}', but this script models only 'bore'; teach it the patch files for that scheduler" >&2
	exit 1
fi

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
for path in "$series/sched/0001-bore-cachy.patch" "$series/misc/dkms-clang.patch"; do
	# A series CachyOS has not published patches for yet would make the build
	# fail in prepare(); fail here instead, before a bump is published.
	api "https://api.github.com/repos/CachyOS/kernel-patches/contents/$path" >/dev/null
	commits=$(api "https://api.github.com/repos/CachyOS/kernel-patches/commits?path=$path&since=$published&per_page=100")
	shas+=$(python3 -I -c 'import json, sys; print("\n".join(c["sha"] for c in json.load(sys.stdin)))' <<<"$commits")$'\n'
done
n=$(printf '%s' "$shas" | sort -u | sed '/^$/d' | wc -l)

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
