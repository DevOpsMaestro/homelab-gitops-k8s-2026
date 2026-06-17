# Renovate — Dependency Automation

Configuration: `renovate.json` at repository root · Workflow: `.github/workflows/renovate.yaml` (daily schedule + `workflow_dispatch`)

---

## How Renovate Works

Renovate is an automated dependency update tool. It scans a repository for pinned dependency versions, checks upstream registries for newer releases, and opens a pull request for each detected update. Renovate operates on a schedule rather than as a persistent process — it runs, performs its work, and exits.

### Onboarding (First Run Only)

The first time Renovate scans a repository, it looks for a `renovate.json` configuration file. If none exists, it creates a branch called `renovate/configure` and opens an onboarding pull request that proposes a starter configuration. Renovate does not open any further pull requests until that onboarding pull request is merged — this design requires explicit consent before automated updates begin.

### The Pipeline

Each time Renovate runs, it follows this sequence:

1. **Initialize** — reads and merges all configuration (`renovate.json`, platform settings, and built-in defaults) and authenticates with the Git platform (GitHub, GitLab, etc.)
2. **Scan** — the Manager module walks the repository file by file, extracts every dependency and its current version, and associates each one with the appropriate datasource
3. **Look up** — the Datasource module contacts upstream registries (Docker Hub, Helm chart repositories, GitHub Releases, etc.) and retrieves all available versions
4. **Filter** — the Versioning module identifies valid upgrades based on the configured constraints (for example, "patch updates only" or "stay on `1.17.x`")
5. **Create PRs** — the Platform module creates a branch and opens a pull request for each update, including the changelog, the time elapsed since the new version was published, and adoption statistics from other projects
6. **Clean up** — branches for updates superseded by even newer versions are closed automatically

Renovate is stateless. It re-reads the repository and all registries on every run; if a run is interrupted, the next run resumes cleanly from the current repository state.

### The Four Core Modules

| Module | Responsibility |
|---|---|
| **Manager** | Locates dependency declaration files and reads the currently pinned versions |
| **Datasource** | Queries upstream registries to retrieve available versions |
| **Versioning** | Evaluates which discovered versions are valid upgrades under the configured constraints |
| **Platform** | Communicates with GitHub or GitLab to create branches and open pull requests |

Different package ecosystems use different version formats — npm uses `1.0.0-beta.1`, pip uses `1.0.0b1`, and so on. The Versioning module is swappable per manager to handle these differences correctly.

---

## What Renovate Tracks in This Cluster

Renovate scans the repository for version strings and opens pull requests when newer versions are available. It tracks:

- **Flux HelmRelease version constraints** — `1.17.x`, `3.x`, `0.x`, etc. in `apps/` and `infrastructure/`; this includes the Contour chart constraint (`0.x` in `infrastructure/controllers/contour.yaml`)
- **Direct container image tags** — images in Kubernetes manifests (BOINC, httpbin, etc.)
- **GitHub Actions** — version pins in `.github/workflows/`
- **CLI tool versions** — `versions.env` and workflow environment variables for Cilium, Istio, the Kubernetes node image, Kyverno CLI, and Kubescape

`CONTOUR_VERSION` in `versions.env` is not tracked by a custom regex manager. Unlike Cilium and Istio — which must be pre-installed by the bootstrap script before Flux runs — Contour is installed entirely by Flux. The `CONTOUR_VERSION` value in `versions.env` is recorded for reference only. Renovate tracks the chart constraint (`0.x`) through the `flux` manager; when that constraint advances, Flux deploys the updated chart automatically without requiring a change to any script or bootstrap step.

---

## Automation Tiers

| Tier | Matches | Schedule | Automerge |
|------|---------|----------|-----------|
| Container image patch | `matchManagers: kubernetes`, `matchUpdateTypes: patch` | Weekdays | Yes — after CI passes |
| Flux minor | `matchManagers: flux`, `matchUpdateTypes: minor` | Mondays | No — human review |
| GitHub Actions patch/minor | `matchManagers: github-actions` | Any | Yes — after CI passes |
| Infrastructure pins | `matchManagers: regex` (versions.env, CI tools) | Any | No — always human |
| Major updates (any) | Not grouped | Any | No — individual PRs |

Automerge is gated on GitHub branch protection: the `validate` workflow (kustomize build + Kyverno tests + Kubescape scan) must pass. If CI fails, Renovate does not merge.

---

## Why Certain Packages Are Disabled

| Package | Reason |
|---------|--------|
| `boinc/client` | `arm64v8` is a Docker manifest architecture alias, not a version tag — there is no newer version to detect |
| `kennethreitz/httpbin` | No versioned tags are published; the manifest pins the image by digest. Digest-only updates produce noise with no meaningful upgrade signal |

---

## HelmRelease Range Constraints and Renovate

Most HelmReleases in this repository use semver range constraints such as `1.17.x`. Flux resolves the latest matching chart automatically — no manual action is required for patch-level updates within the range. Renovate does not create patch PRs for these because the range already covers them.

Renovate opens a PR only when the constraint range itself must change:

- Minor update: `1.17.x → 1.18.x` — goes into the weekly `flux-minor-updates` group PR
- Major update: `1.x → 2.x` — individual PR, no automerge, human review required

---

## Day-to-Day Operations

### Manual Run

Trigger from the GitHub Actions interface: **Actions → Renovate → Run workflow → Run workflow**.

This executes the same job as the nightly scheduled run. Use this after changing `renovate.json` to verify the new configuration immediately without waiting for the next scheduled run.

### View Open Renovate PRs

```bash
gh pr list --label "renovate"
```

### Check the Dependency Dashboard

Renovate creates a **Dependency Dashboard** issue in the GitHub repository. It lists:
- All detected dependencies and their current and available versions
- Which PRs are open, pending, or rate-limited
- Error messages if a registry lookup failed

### Force a Renovate Run via the Dashboard

From the Dependency Dashboard issue, check the "Trigger dependency updates" checkbox. On the next scheduled run (midnight UTC) Renovate will act on the checked items. For an immediate run, use the `workflow_dispatch` trigger above instead.

---

## Rolling Back an Automerged PR

If an automerged update breaks the cluster:

```bash
# Find the merge commit
git log --oneline -10

# Revert it (new commit — safe for a shared branch)
git revert <merge-commit-sha>
git push origin main

# Reconcile Flux immediately
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization apps --with-source
```

---

## Disabling or Snoozing an Update

Add a `packageRules` entry to `renovate.json`:

```json
{
  "matchPackageNames": ["some/package"],
  "enabled": false
}
```

Alternatively, use the Dependency Dashboard issue — Renovate provides checkboxes to suppress specific updates without editing configuration.

---

## Further Reading

- [How Renovate Works — Renovate Docs](https://docs.renovatebot.com/key-concepts/how-renovate-works/)
- [Installing & Onboarding — Renovate Docs](https://docs.renovatebot.com/getting-started/installing-onboarding/)
- [Manager and Datasource System — DeepWiki](https://deepwiki.com/renovatebot/renovate/5-package-manager-integrations)
- [Versioning — Renovate Docs](https://docs.renovatebot.com/modules/versioning/)
