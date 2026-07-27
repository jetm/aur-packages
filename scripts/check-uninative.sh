#!/usr/bin/env bash
set -euo pipefail

# Emit the composite version for yocto-uninative-tarball as
# "<master>_<lts>+<glibc>", e.g. "5.1_5.1+2.44".
#
# The release components are the UNINATIVE_VERSION values oe-core *declares* on
# its master and LTS branches, not the newest release in the Yocto Project
# download index. The mirror is only ever consulted at a path addressed by the
# checksum the consuming oe-core declares, so a payload for a release nobody has
# adopted yet is never looked up: tracking publication would leave the package
# ahead of every consumer for the whole adoption window, silently degrading to a
# network fetch. The glibc component is Arch's current glibc, which bounds the
# ceiling the package's config fragment may raise.
#
# Emits unconditionally - the skew judgement between payload and host glibc
# lives in the PKGBUILD's build(). Exits non-zero rather than printing a partial
# or empty version when any signal is unreachable.
#
# Used as an nvchecker "cmd" source.

# Must match _lts_branch in packages/yocto-uninative-tarball/PKGBUILD. Nothing
# detects a stale branch name; both move together when the LTS moves.
lts_branch=scarthgap

auth_header=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

# Read UNINATIVE_VERSION from one oe-core branch. git.openembedded.org is a
# self-hosted cgit instance that throttles CI egress IPs, so fall back to
# raw.githubusercontent.com, which the workflow already has a token and a
# network path for.
uninative_version() {
  local branch=$1 inc

  inc=$(curl -fsSL \
    "https://git.openembedded.org/openembedded-core/plain/meta/conf/distro/include/yocto-uninative.inc?h=${branch}" \
    || curl -fsSL "${auth_header[@]}" \
      "https://raw.githubusercontent.com/openembedded/openembedded-core/${branch}/meta/conf/distro/include/yocto-uninative.inc")

  grep -Po '^UNINATIVE_VERSION\s*\??=\s*"\K[^"]+' <<<"$inc"
}

master_ver=$(uninative_version master)
lts_ver=$(uninative_version "$lts_branch")

# Arch's pkgver carries a VCS suffix ("2.44+r3+g0b05bc142249"); the ceiling only
# concerns the MAJOR.MINOR glibc release.
arch_glibc_ver=$(curl -fsSL \
  "https://archlinux.org/packages/core/x86_64/glibc/json/" \
  | grep -Po '"pkgver"\s*:\s*"\K[^"]+')
glibc_ver=$(grep -Po '^[0-9]+\.[0-9]+' <<<"$arch_glibc_ver")

echo "${master_ver}_${lts_ver}+${glibc_ver}"
