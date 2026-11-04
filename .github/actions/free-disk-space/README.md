# free-disk-space

Frees disk space on a GitHub-hosted Ubuntu runner by removing preinstalled toolchains and caches the job does not need. It replaces `jlumbroso/free-disk-space`, whose repo moved to `lumbroso-commons` in November 2026 and broke every job that used it ("Unable to resolve action. Repository not found").

## Inputs

Each input is `'true'` (remove, the default) or `'false'` (keep).

| Input | Removes |
| --- | --- |
| `android` | Android SDK, `/usr/local/lib/android` |
| `dotnet` | .NET, `/usr/share/dotnet` |
| `haskell` | `/opt/ghc` and `/usr/local/.ghcup` |
| `tool-cache` | Hosted tool cache, `$AGENT_TOOLSDIRECTORY`. Keep it (`'false'`) when later steps use `setup-go`, `setup-node` or similar |
| `large-packages` | Large apt packages: dotnet, llvm, php, mongodb, mysql, browsers, cloud CLIs. Takes about a minute |
| `docker-images` | All Docker images on the runner |
| `swap-storage` | Swap, `/mnt/swapfile` |

No outputs. Needs no token or permissions. Failures of `apt-get`, `docker` or `swapoff` are warnings, never job failures.

## Usage

```yaml
- uses: loft-sh/github-actions/.github/actions/free-disk-space@free-disk-space/v1
  with:
    tool-cache: false
```

## Tests

```bash
bats .github/actions/free-disk-space/test/*.bats
```
