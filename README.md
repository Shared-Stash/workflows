# Shared-Stash/workflows

Reusable GitHub Actions workflows + helper scripts shared across the bitsnbites image components. The point: each image repo (e.g. `image-playwright`, future `image-node`, etc.) keeps only what's actually image-specific (its `Dockerfile` and a `versions.yml`) and delegates everything else here.

## What's in here

```
.github/workflows/
  ci-image.yml            reusable: nightly build + deprecate + cleanup
  pr-validate.yml         reusable: PR lint + smoke build

scripts/
  get-versions.py         resolves versions.yml -> .matrix.json (live every run)
  should-build.sh         skip-if-unchanged gate (build-hash compare)
  find-deprecated.sh      diff registry vs supported matrix
  cleanup-deprecated.sh   hard-delete tags deprecated > 90 days
```

## How it works end-to-end

For an image repo (say `image-playwright`):

1. The repo has a `Dockerfile` and a `versions.yml`.
2. The repo's nightly workflow is one job: `uses: Shared-Stash/workflows/.github/workflows/ci-image.yml@main`.
3. The reusable workflow checks out both the calling repo and this repo, runs `get-versions.py` against the calling repo's `versions.yml` to get the live supported matrix, then drives:
   - **build** — matrix-fans-out, skip-if-unchanged gate per combo, multi-arch buildx, pushes to ghcr.io and (optionally) Docker Hub.
   - **deprecate** — diffs registry contents against today's supported matrix; combos that fell off get an OCI annotation + a `<tag>-deprecated` alias tag.
   - **cleanup** — hard-deletes any `*-deprecated` tag whose `org.bitsnbites.deprecated.at` is older than `retention_days` (default 90), from both registries.

The supported set is **always** computed live from upstream every run, so EOL'd Node lines and old Playwright minors get noticed and dropped automatically.

## The contract: `versions.yml`

```yaml
axes:
  pw:
    source: github-releases       # microsoft/playwright -> latest 3 minors
    repo: microsoft/playwright
    keep_minors: 3
    include_prereleases: false

  node:
    source: endoflife             # endoflife.date/api/nodejs.json -> active LTS lines
    product: nodejs
    only_lts: true
    min_major: 22

# Templates use {axis_name.field} placeholders.
# Available fields per source:
#   endoflife:        cycle, latest, lts, eol, support, major (parsed)
#   github-releases:  tag, full, minor, major

tag_key: "{pw.minor}-node{node.cycle}"
tags:
  - "{pw.minor}-node{node.cycle}"
  - "{pw.full}-node{node.cycle}"

# The combo that matches newest on every named axis (by the named field)
# also gets the literal `latest` tag.
latest_when:
  pw: full
  node: cycle

build_args:
  PLAYWRIGHT_VERSION: "{pw.full}"
  NODE_MAJOR:         "{node.cycle}"
```

`get-versions.py` reads this, fetches each axis live, takes the cartesian product, and writes `.matrix.json` in the normalized shape `ci-image.yml` consumes:

```json
{
  "include": [
    { "tag_key": "1.59-node24",
      "tags": ["1.59-node24", "1.59.1-node24", "latest"],
      "build_args": { "PLAYWRIGHT_VERSION": "1.59.1", "NODE_MAJOR": "24" } }
  ]
}
```

## Calling `ci-image.yml`

```yaml
# .github/workflows/nightly.yml in your image repo
name: Nightly Build

on:
  schedule:
    - cron: "0 6 * * *"
  push:
    branches: [main]
    paths: [Dockerfile, versions.yml, .github/workflows/**]
  workflow_dispatch:
    inputs:
      dry_run_cleanup: { type: boolean, default: false }
      force_build:     { type: boolean, default: false }

permissions:
  contents: read
  packages: write

jobs:
  ci:
    uses: Shared-Stash/workflows/.github/workflows/ci-image.yml@main
    with:
      image_name: playwright
      versions_config_path: versions.yml
      dry_run_cleanup: ${{ inputs.dry_run_cleanup || false }}
      force_build:     ${{ inputs.force_build || false }}
    secrets:
      DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
      DOCKERHUB_TOKEN:    ${{ secrets.DOCKERHUB_TOKEN }}
```

That's the whole nightly workflow on the consumer side.

## Calling `pr-validate.yml`

```yaml
# .github/workflows/pr.yml in your image repo
name: PR Validation

on:
  pull_request:
    paths: [Dockerfile, .dockerignore, versions.yml, .github/workflows/**]

permissions:
  contents: read

jobs:
  validate:
    uses: Shared-Stash/workflows/.github/workflows/pr-validate.yml@main
    with:
      image_name: playwright
      versions_config_path: versions.yml
      smoke_command: |
        node --version && playwright --version
```

## Inputs reference (`ci-image.yml`)

| input | type | default | meaning |
|---|---|---|---|
| `image_name` | string | required | image name without namespace |
| `versions_config_path` | string | `versions.yml` | path in calling repo to the versions config |
| `dockerfile_path` | string | `Dockerfile` | relative to calling repo root |
| `context_path` | string | `.` | build context |
| `ghcr_owner` | string | `shared-stash` | GHCR namespace (must match the GitHub org running the workflow) |
| `dockerhub_namespace` | string | `bitsnbites` | Docker Hub namespace |
| `push_to_dockerhub` | boolean | `true` | mirror push to Docker Hub |
| `platforms` | string | `linux/amd64,linux/arm64` | buildx platforms |
| `retention_days` | number | `90` | days before deprecated tags get hard-deleted |
| `tag_pattern` | string | `^[0-9]+(\.[0-9]+){1,2}-.+$` | which tags to consider for deprecation |
| `dry_run_cleanup` | boolean | `false` | skip actual deletes |
| `force_build` | boolean | `false` | bypass skip-if-unchanged gate |
| `workflows_repo` | string | `Shared-Stash/workflows` | where the helper scripts live |
| `workflows_ref` | string | `main` | ref to check out |

## Required secrets in the calling repo

| name | purpose |
|---|---|
| `GITHUB_TOKEN` | provided automatically; `packages: write` must be set in caller's `permissions:` |
| `DOCKERHUB_USERNAME` | Docker Hub robot account |
| `DOCKERHUB_TOKEN` | Docker Hub access token (read/write/delete) |

## Lifecycle behavior the reusable workflow enforces

1. **Skip-if-unchanged** — each matrix entry computes `sha256(Dockerfile) | sha256(sorted-build-args) | sha256(base-image-digest)`. If the existing manifest at the target tag carries the same `org.bitsnbites.build-hash`, the build is a no-op.
2. **Deprecate, don't delete** — combos that fall off today's supported matrix get an OCI annotation (`org.opencontainers.image.deprecated=true` + a date stamp) plus a `<tag>-deprecated` alias tag. Existing pulls keep working.
3. **90-day janitor** — anything tagged `*-deprecated` whose `org.bitsnbites.deprecated.at` is older than `retention_days` gets hard-deleted from both registries. Nothing rots forever.

## Adding a new image component

You only write two files in the new image repo:

1. A **Dockerfile** that takes whatever build args your `versions.yml` declares.
2. A **`versions.yml`** declaring the axes, tag templates, and `build_args` mapping.

Plus a six-line `nightly.yml` and `pr.yml` (copy from `image-playwright/`). That's the whole component.

## Status

This component lives in [`shared-stash`](https://github.com/Shared-Stash/shared-stash) under `workflows/`. Structured to be split out into its own `Shared-Stash/workflows` GitHub repo when ready — `git subtree split --prefix=workflows -b workflows` and push.

> **Note:** when split out, `Shared-Stash/workflows` must be **public** (or you'll need to provide a PAT to every consuming repo). GitHub Actions' default `GITHUB_TOKEN` can't read other private repos, which is required for the `actions/checkout` step that pulls the shared scripts.
