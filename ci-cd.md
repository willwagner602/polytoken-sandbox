# Reusable GitHub Actions CI/CD Guide

This document describes the repository's GitHub Actions CI/CD system as implemented in `.github/workflows/`, how source changes become validated artifacts, how GHCR tags are produced, and how to deploy or roll back those artifacts safely.

## 1. System overview

A typical project has three workflows:

| Workflow | Trigger | Publishes an image? | Purpose |
|---|---|---:|---|
| `.github/workflows/ci.yml` | Pull requests; pushes to `main`, `phase-*`, and `v1_deployment`; reusable workflow calls | No | Test, lint, build, exercise deployment behavior, and validate a multi-architecture Docker build |
| `.github/workflows/publish-main-container.yml` | Successful completion of `CI` for `main` | Yes | Publish the tested merged-main commit as `latest` and an immutable SHA tag |
| `.github/workflows/publish-container.yml` | Git tags matching `v*.*.*`; manual dispatch | Yes | Validate and publish an exact semantic release tag as a versioned GHCR image |

The image name is computed from `github.repository`. In the examples below, replace `OWNER/PROJECT` with the GitHub owner and repository name for the project you are adapting:

```text
ghcr.io/OWNER/PROJECT
```

The Dockerfile builds four Go binaries—`migrate`, `web`, `scanner`, and `uploader`—into a Debian 12 runtime image. The runtime user is the non-root `appuser` (`UID/GID 65532`). The entrypoint runs migrations once and then supervises the selected services.

## 2. Pull requests and branch CI

### 2.1 Triggers

`ci.yml` runs for every pull request, regardless of the target branch, and for pushes to:

```yaml
on:
  push:
    branches:
      - main
      - "phase-*"
      - v1_deployment
  pull_request:
  workflow_call:
```

The branch push triggers are useful for validating long-lived phase/deployment branches. A normal feature branch still receives CI through its pull request.

The workflow declares only:

```yaml
permissions:
  contents: read
```

It does not receive package-write permission and never publishes an image.

### 2.2 Source checkout

The workflow supports both ordinary events and calls from the release workflow:

```yaml
- name: Check out source
  uses: actions/checkout@v6
  with:
    ref: ${{ inputs.source_ref || github.ref }}
```

For a pull request or branch push, `github.ref` selects the event's source. When called as a reusable workflow, `source_ref` explicitly selects the commit to validate. This distinction is important for releases: release CI validates the commit resolved from the release tag, not an unrelated default branch.

### 2.3 Go validation

The Go toolchain version comes from `go.mod`, with module caching enabled:

```yaml
- name: Set up Go
  uses: actions/setup-go@v6
  with:
    go-version-file: go.mod
    cache: true
```

The following commands run in order:

```sh
go test ./...
go test -race ./...
go vet ./...
go build ./cmd/...
```

They cover ordinary tests, race detection, static analysis, and compilation of every command under `cmd/`.

### 2.4 Frontend validation

Node.js is selected from `web/package.json`. The lockfile is used for npm caching and dependency installation:

```yaml
- name: Set up Node.js
  uses: actions/setup-node@v6
  with:
    node-version-file: web/package.json
    cache: npm
    cache-dependency-path: web/package-lock.json

- name: Install frontend dependencies
  run: npm ci --prefix web

- name: Run frontend tests
  run: npm test --prefix web
```

`npm ci` makes the checked-in `web/package-lock.json` authoritative and fails if the manifest and lockfile disagree.

### 2.5 Docker deployment tests

The deployment tests build the image locally and use Docker to verify container behavior:

```yaml
- name: Run Docker deployment tests
  env:
    DOCKER_BUILDKIT: "1"
  run: go test ./deploytest -count=1
```

The test suite checks, among other things:

- the configured runtime user is `appuser:appuser`;
- startup migrations run;
- per-service advisory locks prevent duplicate service ownership;
- the supervisor restarts a failed child;
- SQLite persists across container restarts;
- readiness and graceful shutdown work;
- the image starts with the expected non-root deployment behavior.

The tests create a temporary Docker image for the project under test (for example, `PROJECT-deploytest:latest`). The test code prepares named volumes by creating `/data/locks` and assigning ownership to `65532:65532`. This is the same ownership requirement production deployments must satisfy.

For the constrained development sandbox only, the test suite supports:

```sh
APP_DEPLOYTEST_ROOT_COMPAT=1 go test ./deploytest -count=1
```

That is a test-runner workaround and must not be set in production.

### 2.6 Multi-architecture build validation

CI also builds the production Dockerfile for both supported architectures, but does not push it:

```yaml
- name: Validate multi-architecture image build
  uses: docker/setup-qemu-action@v4

- name: Set up Docker Buildx
  uses: docker/setup-buildx-action@v4

- name: Build multi-architecture image without publishing
  uses: docker/build-push-action@v7
  with:
    context: .
    file: ./deploy/Dockerfile
    platforms: linux/amd64,linux/arm64
    push: false
    outputs: type=oci,dest=/tmp/project-image.tar
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

This catches Dockerfile and cross-platform build problems before an image can be published.

## 3. Docker image construction

The build uses `deploy/Dockerfile`:

```dockerfile
FROM golang:1.24-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/migrate ./cmd/migrate && \
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/web ./cmd/web && \
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/scanner ./cmd/scanner && \
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/uploader ./cmd/uploader

FROM debian:12-slim
COPY --from=build /out/ /app/
COPY deploy/entrypoint.sh /app/entrypoint.sh
RUN chmod 0755 /app/entrypoint.sh && useradd --system --uid 65532 appuser
USER appuser:appuser
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
```

The release and main workflows use the same build inputs:

```yaml
context: .
file: ./deploy/Dockerfile
platforms: linux/amd64,linux/arm64
```

Both publishing workflows also enable BuildKit GitHub Actions cache, OCI provenance, and an SBOM:

```yaml
provenance: true
sbom: true
cache-from: type=gha
cache-to: type=gha,mode=max
```

## 4. Merged-main publishing

### 4.1 Trigger and gate

`.github/workflows/publish-main-container.yml` listens for completion of the workflow named `CI` on `main`:

```yaml
on:
  workflow_run:
    workflows:
      - CI
    types:
      - completed
    branches:
      - main
```

The publish job has this gate:

```yaml
if: ${{ github.event.workflow_run.conclusion == 'success' }}
```

A failed or cancelled main CI run does not publish an image.

### 4.2 Commit selection

The workflow checks out the exact commit tested by CI:

```yaml
- name: Check out tested commit
  uses: actions/checkout@v6
  with:
    ref: ${{ github.event.workflow_run.head_sha }}
```

This avoids publishing whatever happens to be at the branch tip later. The workflow serializes publications:

```yaml
concurrency:
  group: publish-main-container-main
  cancel-in-progress: false
```

That reduces the chance that an older build finishes after a newer build and moves `latest` backward.

### 4.3 Tags produced

Metadata extraction produces two tags:

```yaml
tags: |
  type=raw,value=latest
  type=raw,value=sha-${{ github.event.workflow_run.head_sha }}
```

For a merge commit such as `FULL_MERGE_COMMIT_SHA`, the resulting references are:

```text
ghcr.io/OWNER/PROJECT:latest
ghcr.io/OWNER/PROJECT:sha-FULL_MERGE_COMMIT_SHA
```

`latest` is mutable. The `sha-...` tag is an immutable-by-convention audit and rollback reference to the exact source commit.

### 4.4 Push permissions and login

The workflow grants:

```yaml
permissions:
  contents: read
  packages: write
  attestations: write
  id-token: write
```

It logs in using the short-lived Actions token:

```yaml
- name: Log in to GHCR
  uses: docker/login-action@v4
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}
```

No personal token is stored in the workflow, Dockerfile, or build arguments.

## 5. Versioned release publishing

### 5.1 Release triggers

The release workflow runs for tags matching:

```yaml
on:
  push:
    tags:
      - "v*.*.*"
  workflow_dispatch:
    inputs:
      tag:
        description: Existing exact release tag to publish (for example, v2.3.4)
        required: true
        type: string
```

A normal release is therefore created by pushing a Git tag such as:

```sh
git checkout main
git pull --ff-only origin main
git tag v2.3.4
git push origin v2.3.4
```

The manual dispatch path is intended to republish an existing exact release tag. Its required input is the Git tag including the `v` prefix, for example `v1.0.2`.

### 5.2 Release environment and permissions

The release workflow has the same read/package/provenance permissions as main publishing and places the publish job in the `container-release` environment:

```yaml
environment: container-release
```

Repository administrators can use that environment for required reviewers, deployment protection rules, and controlled release approval.

### 5.3 Exact tag validation and commit resolution

The `resolve` job checks out all history:

```yaml
- name: Check out repository metadata
  uses: actions/checkout@v6
  with:
    fetch-depth: 0
```

It then validates the exact `vMAJOR.MINOR.PATCH` form and confirms the tag exists locally:

```sh
set -eu
if ! printf '%s' "$REQUESTED_TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Expected an exact release tag like v2.3.4, got: $REQUESTED_TAG" >&2
  exit 1
fi
if ! git show-ref --verify --quiet "refs/tags/$REQUESTED_TAG"; then
  echo "Release tag does not exist: $REQUESTED_TAG" >&2
  exit 1
fi
tag_sha=$(git rev-parse "refs/tags/$REQUESTED_TAG^{}")
printf 'tag=%s\n' "$REQUESTED_TAG" >> "$GITHUB_OUTPUT"
printf 'sha=%s\n' "$tag_sha" >> "$GITHUB_OUTPUT"
```

The `^{} ` dereference resolves an annotated tag to the commit it ultimately names. The resolved `tag` and `sha` become outputs for the downstream jobs.

The regular expression is deliberately written with one shell-level backslash before each dot. An earlier version used over-escaped backslashes and rejected valid `v1.0.0` tags. That failure happened before validation and publishing; it did not indicate a GHCR credential problem.

### 5.4 Reusing CI before publishing

The release workflow calls `ci.yml` as a reusable workflow:

```yaml
validate:
  needs: resolve
  uses: ./.github/workflows/ci.yml
  with:
    source_ref: ${{ needs.resolve.outputs.sha }}
```

The publish job waits for both jobs:

```yaml
needs: [resolve, validate]
```

This means a release image is built only after the exact tagged commit passes Go tests, race tests, vet, command builds, frontend tests, deployment tests, and the multi-architecture no-push build.

### 5.5 Version tag mapping

The release metadata configuration is:

```yaml
tags: |
  type=semver,pattern={{version}},value=${{ needs.resolve.outputs.tag }}
```

Therefore:

```text
Git tag:       v2.3.4
GHCR tag:      2.3.4
```

The `v` is not included in the image tag. For this example, the expected release image is:

```text
ghcr.io/OWNER/PROJECT:2.3.4
```

The release workflow does not publish `latest`, and it does not publish the `v`-prefixed Git tag as the container tag.

### 5.6 Release build and summary

The release build pushes both architectures:

```yaml
- name: Build and push image
  uses: docker/build-push-action@v7
  with:
    context: .
    file: ./deploy/Dockerfile
    push: true
    platforms: linux/amd64,linux/arm64
    tags: ${{ steps.meta.outputs.tags }}
    labels: ${{ steps.meta.outputs.labels }}
    annotations: ${{ steps.meta.outputs.annotations }}
    provenance: true
    sbom: true
```

The final workflow summary records the image tag, resolved source commit, and the registry index digest. The digest is the strongest deployment identifier because tags are mutable references.

## 6. GHCR authentication for deployment hosts

GitHub Actions authenticates to GHCR with `${{ secrets.GITHUB_TOKEN }}` and `packages: write`. A deployment host only needs to pull, so its credential needs package-read access.

For a private package, the reliable Docker login is:

```sh
export GHCR_READ_TOKEN='YOUR_TOKEN'
printf '%s' "$GHCR_READ_TOKEN" | docker login ghcr.io \
  --username YOUR_GITHUB_USERNAME \
  --password-stdin
unset GHCR_READ_TOKEN
```

A classic GitHub PAT normally needs the `read:packages` scope. The account owning the token must also be allowed to read the package; private repository/package access and organization SSO authorization may be required. Fine-grained PATs use a **Packages: Read-only** permission where supported, but GitHub's package API may still require the classic `read:packages` scope for some package-version queries.

Do not put a PAT in `compose.yaml`, a committed `.env` file, a Dockerfile, or a Docker build argument. Docker may store credentials in `~/.docker/config.json`; configure a Docker credential helper on production hosts to avoid plaintext credential storage.

## 8. Verifying and deploying an image

A version tag is convenient, but production should pin the multi-platform registry digest printed in the publish workflow summary:

```sh
image=ghcr.io/OWNER/PROJECT
version=2.3.4
expected_digest=sha256:PASTE_THE_PUBLISHED_INDEX_DIGEST_HERE

docker pull "$image:$version"
test "$(docker buildx imagetools inspect "$image:$version" --format '{{json .Manifest.Digest}}' | tr -d '"')" = "$expected_digest"
docker pull "$image@$expected_digest"
```

The image is built for `linux/amd64` and `linux/arm64`; the digest above identifies the registry index containing both platform manifests.

## 9. Runtime deployment contract

The container starts its entrypoint script. A typical supervised application might define defaults like these (replace them with the variables used by your project):

```sh
APP_DB=/data/app.db
APP_LOCK_DIR=/data/locks
APP_SUPERVISOR_INTERVAL=60s
APP_SERVICES=web,worker
```

The application should expose a documented internal listener port. In the example below, use the port your application actually binds to:

```text
:APP_PORT
```

A direct Docker deployment therefore looks like:

```sh
docker run -d --name project --restart unless-stopped \
  -p HOST_PORT:APP_PORT \
  -v project-data:/data \
  -v /srv/project-data:/app-data:ro \
  --env-file /etc/project.env \
  ghcr.io/OWNER/PROJECT:VERSION
```

Equivalent Compose configuration:

```yaml
services:
  app:
    image: ghcr.io/OWNER/PROJECT:VERSION
    ports:
      - "HOST_PORT:APP_PORT"
    volumes:
      - project-data:/data
      - /srv/project-data:/app-data:ro
    env_file:
      - /etc/project.env

volumes:
  project-data:
```

If the application exposes a configurable listener, set its address to match the internal container port. For example:

```env
APP_HTTP_ADDR=:APP_PORT
```

Set the application's public-base-URL variable to the externally visible URL, especially when a TLS reverse proxy is in front of the container:

```env
APP_PUBLIC_BASE_URL=https://app.example.com
```

## 10. Persistent volume ownership and the `/data/locks` error

`/data` is a path inside the container. It must be backed by a writable named volume or bind mount. The image intentionally runs as `appuser`, not root, so the mounted data directory must be writable by UID/GID `65532`.

For a named volume:

```sh
docker run --rm -u 0 \
  -v project-data:/data \
  alpine:3.20 \
  sh -c 'mkdir -p /data/locks && chown -R 65532:65532 /data'
```

For a host bind mount:

```sh
sudo mkdir -p /srv/project-data/locks
sudo chown -R 65532:65532 /srv/project-data
```

Inspect the mapping with:

```sh
docker inspect project \
  --format '{{range .Mounts}}{{println "Host:" .Source "Container:" .Destination "Type:" .Type}}{{end}}'
```

The data volume contains:

```text
/data/photos.db
/data/photos.db-wal
/data/photos.db-shm
/data/locks
```

SQLite WAL sidecars are part of the database state. Stop the container cleanly before a maintenance-window backup, and copy the database plus any sidecars as one consistent set.

## 11. Application environment variables

Required values depend on the services selected by the application's service-selection variable:

```env
APP_OPERATOR_USERNAME=operator
APP_OPERATOR_PASSWORD=strong-password
APP_SESSION_SECRET=at-least-32-random-bytes
APP_SCAN_ROOTS=/app-data
APP_EXTERNAL_HANDLE=operator@example.com
APP_EXTERNAL_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx
```

Important defaults and overrides:

| Variable | Default | Notes |
|---|---|---|
| `APP_DB` | `/data/app.db` in the container entrypoint example | Persistent application database path |
| `APP_LOCK_DIR` | `/data/locks` in the entrypoint example | Must be writable by the runtime UID |
| `APP_HTTP_ADDR` | `:APP_PORT` | Web listener |
| `APP_PUBLIC_BASE_URL` | application-specific | Set the real external URL in production |
| `APP_SCAN_ROOTS` | application-specific | Use paths that exist inside the container |
| `APP_EXTERNAL_SERVICE_URL` | application-specific | Override for an external service endpoint |
| `APP_POSTS_PER_DAY` | application-specific | Example application setting |
| `APP_SCANNER_INTERVAL` | application-specific | Use the application's duration syntax |
| `APP_WORKER_INTERVAL` | application-specific | Use the application's duration syntax |
| `APP_IMAGE_MAX_BYTES` | application-specific | Enforce an application-appropriate limit |
| `APP_LOG_LEVEL` | `info` | Logging level |
| `APP_SUPERVISOR_INTERVAL` | `60s` | Entrypoint restart delay |
| `APP_SERVICES` | `web,worker` | Comma-separated service list |

Secrets are deployment inputs only and are not written to SQLite.

## 12. Health checks and operational verification

The web service exposes:

```text
GET /healthz  -> process is serving HTTP
GET /readyz   -> SQLite is reachable and migrations have completed
```

After deployment, verify:

```sh
curl -fsS http://127.0.0.1:APP_PORT/healthz
curl -fsS http://127.0.0.1:APP_PORT/readyz
```

For a reverse-proxied deployment, verify the public HTTPS URL instead. Check that the review UI loads, the operator can log in, scan roots are visible, and the uploader reports publication states.

The entrypoint runs `/app/migrate` once before starting child services. Each service also opens the same SQLite database and uses advisory lock ownership to prevent duplicate role instances.

## 13. Rollback

Prefer a digest-pinned deployment. To roll back:

1. Stop the current container.
2. Deploy the previous known-good image digest.
3. Confirm `/readyz`, review data, and publication states.
4. If the newer image applied an incompatible forward migration, restore the matching database/WAL backup before starting the older image.

Migrations are forward-only. An older image does not downgrade the database. Keep schema changes additive and backward-compatible during the rollback window.

## 14. Troubleshooting checklist

### `unauthorized` or `denied` while pulling

The failure occurs before the application starts. Check:

```sh
docker login ghcr.io
docker pull ghcr.io/OWNER/PROJECT:VERSION
```

Confirm the token has package read access, the account can see the private package, organization SSO is authorized, and the requested tag exists. `PHOTO_UPLOADER_*` variables cannot fix an image-pull failure.

### `latest` is missing or stale

`latest` is published only by the successful merged-main workflow. Release publishing creates a version tag such as `2.3.4`, not `latest`. Use the exact version or SHA tag and compare its workflow source SHA with the desired commit.

### Release workflow rejects a version tag

Inspect the `Resolve immutable release commit` job. The accepted form is exactly:

```text
vMAJOR.MINOR.PATCH
```

For example, `v2.3.4` passes; `2.3.4`, `v2.3`, and `v2.3.4-rc1` fail.

### `mkdir: cannot create directory '/data/locks': Permission denied`

The mounted `/data` volume is not writable by `appuser`/UID 65532. Apply the ownership fix in section 10 rather than running the production container as root.

### Port conflict or connection refused

Use the matching internal and host ports:

```yaml
ports:
  - "HOST_PORT:APP_PORT"
```

and:

```env
APP_HTTP_ADDR=:APP_PORT
```

If a reverse proxy is used, make sure it forwards to the selected host port and that the application's public-base-URL variable matches the public origin.

## 15. Useful GitHub CLI commands

List recent CI and publish runs:

```sh
gh run list --repo OWNER/PROJECT --limit 20
```

Inspect a release run:

```sh
gh run view RUN_ID --repo OWNER/PROJECT
```

Show failed logs:

```sh
gh run view RUN_ID --repo OWNER/PROJECT --log-failed
```

Inspect a pull request and its checks:

```sh
gh pr view PR_NUMBER \
  --repo OWNER/PROJECT \
  --json state,mergeStateStatus,statusCheckRollup,url
```

List Git tags:

```sh
git ls-remote --tags origin 'v*'
```

A GitHub release page is not proof that an image was published. Confirm the corresponding workflow completed successfully and use the workflow summary or GHCR package page to verify the image tag and digest.
