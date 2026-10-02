#!/usr/bin/env bash
set -euo pipefail

# Report the latest include-what-you-use release tag.
#
# Used as an nvchecker "cmd" source.
#
# Used to also gate on clang being "new enough" via the "IWYU 0.N needs
# clang N-4" rule, matching update-version.sh's old derivation of
# _clang_major. Dropped 2026-10-02: the rule assumed IWYU and Arch's
# rolling clang released in lockstep, which stopped holding once IWYU's
# release cadence slowed - one release (0.26) in the 13 months Arch's
# clang moved 21->23, so N-4 pointed at clang 22, a major Arch no longer
# carries at all. update-version.sh now reads _clang_major straight off
# Arch's actual clang package instead of deriving it, so there is no
# longer a version-arithmetic compatibility question to gate here - the
# real test is whether the source builds, which the CI build step for
# this package already does the same as for every other package in this
# repo, failing that one leg without blocking the rest.

auth_header=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

curl -fsSL "${auth_header[@]}" \
  "https://api.github.com/repos/include-what-you-use/include-what-you-use/releases/latest" \
  | grep -Po '"tag_name"\s*:\s*"\K[^"]+'
