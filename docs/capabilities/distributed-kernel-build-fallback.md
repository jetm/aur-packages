# `distributed-kernel-build-fallback`: `PKGBUILD`-level logic that probes sccache-dist cluster health at build time and transparently falls back to a correct local build when the cluster is unhealthy, so a cold/degraded cluster never turns into a failed or silently-mis-cached package build.

**Delivered by:** linux-cachyos-jetm-sccache-dist-cluster
**Modules touched:** other

## Delivery Note

Invocation: `makepkg` inside `packages/linux-cachyos-jetm/`, with the cluster-health probe (`_sccache_dist_probe`, called from `prepare()`) deciding automatically whether `CC` routes through `sccache` or stays plain `clang`
Precondition: PC1's sccache-dist scheduler live and reachable (already true today); for the distributed path specifically, PC2 and PC3 registered as build-servers (this change's own tasks 1-3 provision that)
Success signal: a built kernel package, plus - when the cluster was healthy - `sccache --show-stats` reporting a non-zero "Successful distributed compiles" count for that build
Silent failure: none - every cluster-health failure mode (unreachable scheduler, missing `sccache` binary, malformed dist-status output, or a hung scheduler beyond the 5s timeout) is designed to fall back to an ordinary local compile rather than fail or silently mis-cache, per this change's own core requirement
