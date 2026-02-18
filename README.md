# aur-packages

AUR package automation with nvchecker + GitHub Actions.

## How it works

1. **Daily check**: nvchecker compares upstream releases against `old.json`
2. **Update**: For each outdated package, bumps pkgver, recalculates checksums, regenerates .SRCINFO
3. **Build**: Builds the package in an Arch container to verify it works
4. **Publish**: Pushes to AUR via SSH

## Packages

| Package | Upstream | Auto-update |
|---------|----------|-------------|
| c | [ryanmjacobs/c](https://github.com/ryanmjacobs/c) | Yes |
| difi | [oug-t/difi](https://github.com/oug-t/difi) | Yes |
| difi-bin | [oug-t/difi](https://github.com/oug-t/difi) | Yes |
| easy-conflict | [chojs23/ec](https://github.com/chojs23/ec) | Yes |
| easy-conflict-bin | [chojs23/ec](https://github.com/chojs23/ec) | Yes |
| git-add-interactive | [cwarden/git-add--interactive](https://github.com/cwarden/git-add--interactive) | Yes |
| lavacli | [lava/lavacli](https://gitlab.com/lava/lavacli) | Yes |
| include-what-you-use | [include-what-you-use](https://github.com/include-what-you-use/include-what-you-use) | No (clang coupling) |
| virtio-win | Fedora infra | No (manual) |

## Secrets required

- `AUR_SSH_KEY`: SSH private key registered with AUR
- `AUR_USER_NAME`: Git user.name for AUR commits
- `AUR_USER_EMAIL`: Git user.email for AUR commits

## Manual trigger

Run the workflow manually from the Actions tab, or:

```bash
gh workflow run update.yml
```
