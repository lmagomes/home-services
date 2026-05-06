---
name: update-container-image
description: Workflow for updating locally-built container images — covers the Containerfile → build-version → .container file chain
---

## Overview

When a locally-built container image needs changes (Containerfile modifications, Go source updates, entrypoint changes, etc.), follow this workflow to ensure the image gets a distinct version tag and the quadlet references stay in sync.

## Images with build-version tracking

Three images have in-repo source/config that changes independently of their base image:

| Image | Build dir | Base version source | Composed version |
|-------|-----------|---------------------|------------------|
| `dev` | `builds/dev/` | FROM line (`fedora:44` → `44`) | `44-r<N>` |
| `forgejo-runner-job` | `builds/forgejo-runner-job/` | Literal (`44`) | `44-r<N>` |
| `service-hub` | `builds/service-hub/` | First FROM line (`golang:1.24-alpine` → `1.24-alpine`) | `1.24-alpine-r<N>` |

## Images without build-version tracking

These images derive their version solely from their base image — no build-version file exists:

| Image | Build dir |
|-------|-----------|
| `caddy-cloudflare-l4` | `builds/caddy/` |
| `transmission-flood` | `builds/transmission/` |
| `json-path-finder` | `builds/json-path-finder/` |
| `jsonlint` | `builds/jsonlint/` |

## Workflow for changing a tracked image

### 1. Make your Containerfile changes

Edit the Containerfile in `builds/<image>/`.

### 2. Bump the build-version

Increment the integer in `builds/<image>/build-version`. Example:

```
# Before
1

# After
2
```

This changes the composed version from e.g. `44-r1` to `44-r2`.

### 3. Update the .container file

Update the `Image=` directive in the quadlet `.container` file to match the new composed version:

```ini
# Before
Image=home-services/dev:44-r1

# After
Image=home-services/dev:44-r2
```

The `.container` file locations:
- `dev`: `quadlets/dev/dev.container`
- `service-hub`: `quadlets/monitor/monitor-service-hub.container`
- `forgejo-runner-job`: No quadlet file — the runner config (`quadlets/forgejo-runner/forgejo-runner-config.encrypted.yml`) uses `:latest` via a runner label, so no update needed

### 4. Build and test

For local testing:
```
just build-<image>
```

For pushing to the registry:
```
just build-and-push <image> builds/<image> <version-strategy>
```

The `build-and-push` recipe and individual build recipes automatically compose the final version as `<base-version>-r<build-number>` when a `build-version` file exists, and also tag as `:latest`.

### 5. Reinstall quadlets

After the image is pushed, reinstall quadlets so the systemd units pick up the new image reference:
```
just install-quadlets
```

## Version composition rules

- **`build-version` file exists**: Final version = `<base-version>-r<build-number>` (e.g., `44-r2`)
- **No `build-version` file**: Final version = base version only (e.g., `2.11.2-alpine`)
- The `-r` prefix stands for "revision" — each change to the in-repo source increments this

All locally-built images are also tagged as `:latest` for convenience (the runner uses `:latest`, dev environments can pull the latest build without knowing the exact revision).

## CI workflow

The `.forgejo/workflows/build-images.yml` workflow uses `build-and-push` internally, so it automatically picks up the composed version. No CI changes needed when bumping build versions.

## Common pitfalls

- **Forgetting to bump build-version**: The image rebuilds with the same tag, overwriting the previous version. No rollback possible.
- **Forgetting to update the .container file**: The quadlet still references the old tag — `podman auto-update` won't trigger a restart.
- **Changing the base image in FROM**: This changes the base version component. Make sure the new base version matches what the `.container` file expects.
