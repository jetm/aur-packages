# aur-packages

AUR package automation with nvchecker + GitHub Actions.

## How it works

1. **Daily check**: nvchecker compares upstream releases against `old.json`
2. **Update**: For each outdated package, bumps pkgver, recalculates checksums, regenerates .SRCINFO
   (`yocto-uninative-tarball` skips the checksum step - its only remote source is a git commit pinned
   by hash, and its other sources are local files whose sums a pkgver bump does not change)
3. **Build**: Builds the package in an Arch container to verify it works
4. **Publish**: Pushes to AUR via SSH

## Packages

| Package | Upstream | Auto-update |
|---------|----------|-------------|
| c | [ryanmjacobs/c](https://github.com/ryanmjacobs/c) | Yes |
| easy-conflict | [chojs23/ec](https://github.com/chojs23/ec) | Yes |
| easy-conflict-bin | [chojs23/ec](https://github.com/chojs23/ec) | Yes |
| git-add-interactive | [cwarden/git-add--interactive](https://github.com/cwarden/git-add--interactive) | Yes |
| lavacli | [lava/lavacli](https://gitlab.com/lava/lavacli) | Yes |
| include-what-you-use | [include-what-you-use](https://github.com/include-what-you-use/include-what-you-use) | Yes |
| ytcui | [MilkmanAbi/ytcui](https://github.com/MilkmanAbi/ytcui) | Yes |
| virtio-win | Fedora infra | No (manual) |
| avocado-cli | [avocado-linux/avocado-cli](https://github.com/avocado-linux/avocado-cli) | Yes |
| yocto-uninative-tarball | [Arch glibc packaging](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc) | Yes |
| linux-cachyos-jetm | [CachyOS/linux](https://github.com/CachyOS/linux) releases | Yes |

## Secrets required

- `AUR_SSH_KEY`: SSH private key registered with AUR
- `AUR_USER_NAME`: Git user.name for AUR commits
- `AUR_USER_EMAIL`: Git user.email for AUR commits

## Manual trigger

Run the workflow manually from the Actions tab, or:

```bash
gh workflow run update.yml
```
