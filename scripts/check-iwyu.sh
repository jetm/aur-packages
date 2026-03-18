#!/usr/bin/env bash
set -euo pipefail

# Check for a new include-what-you-use release that is compatible with the
# clang version currently available in the Arch Linux repos.
#
# IWYU 0.N requires clang (N - 4). This script outputs the latest IWYU
# version only if the matching clang is available, otherwise outputs nothing.
#
# Used as an nvchecker "cmd" source.

# Query latest IWYU release tag from GitHub
auth_header=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

iwyu_tag=$(curl -fsSL "${auth_header[@]}" \
  "https://api.github.com/repos/include-what-you-use/include-what-you-use/releases/latest" \
  | grep -Po '"tag_name"\s*:\s*"\K[^"]+')

# Extract minor version: "0.26" -> 26
iwyu_minor=${iwyu_tag#0.}

# Required clang major = iwyu_minor - 4
required_clang_major=$((iwyu_minor - 4))

# Query current clang version from Arch repos
arch_clang_ver=$(curl -fsSL \
  "https://archlinux.org/packages/extra/x86_64/clang/json/" \
  | grep -Po '"pkgver"\s*:\s*"\K[^"]+')

# Extract clang major
arch_clang_major=${arch_clang_ver%%.*}

# Only output the version if clang is ready
if (( arch_clang_major >= required_clang_major )); then
  echo "$iwyu_tag"
fi
