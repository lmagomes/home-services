---
name: add-service
description: Step-by-step checklist for adding a new self-hosted service with Podman quadlets, plus common pitfalls and Caddy reverse proxy setup
---

## Overview

When adding a new self-hosted service to this repository, follow this checklist to ensure consistency with existing services.

## Checklist

### 1. Create the service directory

```
quadlets/<service>/
```

All files go here. Name in kebab-case.

### 2. Create the pod file

`quadlets/<service>/<service>.pod`:

```ini
[Unit]
Description=<Service> pod managed by Podman
After=network-online.target

[Pod]
PodName=<service>.pod
Network=services.network
# PublishPort=<host>:<container>  (only if externally exposed)

[Install]
WantedBy=default.target
```

### 3. Create container files

`quadlets/<service>/<service>[-component].container` — one per component (app, database, redis, etc.).

Follow the standard container template from AGENTS.md:
- Section order: `[Unit]` → `[Container]` → `[Service]` → `[Install]`
- `ContainerName=<service>-<component>` (kebab-case)
- `Pod=<service>.pod`
- `EnvironmentFile=./%n.d/env`
- Pin image versions — no `:latest` for upstream images
- Add `Requires=` and `After=` for inter-container dependencies
- Place `HealthCmd`, `HealthInterval`, etc. at the end of `[Container]`

### 4. Create volume files

`quadlets/<service>/<volume-name>.volume`:

```ini
[Unit]
Description=<Name> volume

[Volume]
VolumeName=<service>-<purpose>
```

One volume per persistent data directory.

### 5. Create environment files

`quadlets/<service>/<container-name>.service.d/env` — one per container that needs env vars.

- `SCREAMING_SNAKE_CASE` names
- `KEY=value` format (no export, no quoting unless value requires it)
- Comment out secrets that will be injected via `Secret=`:
  ```
  #DATABASE_PASSWORD is set via Secret in the .container file
  ```

### 6. Add secrets

Add any required secrets to `.secrets/secrets.yaml` (encrypted with **sops**).

- Secret names in **kebab-case**: `<service>-<purpose>-password`
- Run `just sync-secrets` after adding

Reference in container files:
```ini
Secret=<name>,type=env,target=<ENV_VAR>
```

### 7. Add Caddy reverse proxy entry

Add a host entry in `quadlets/caddy/caddy.service.d/Caddyfile`. Match the style of existing entries.

### 8. Symlink and reload

```bash
just symlink-quadlets
systemctl --user daemon-reload
```

### 9. Optional: automated updates

Add the service to Release Argus (`quadlets/monitor/monitor-argus.service.d/config.yml`) and Service-Hub for automatic update PRs.

## Common pitfalls

- **`PUID`/`PGID` images (LSIO, s6-overlay)**: Set `PUID=0` and `PGID=0`. Do not use `UserNS=keep-id` — it breaks s6-applyuidgid. Rootless Podman maps container root (UID 0) to the host user.
- **`idmap` on bind mounts**: Don't use it in rootless Podman — `mount_setattr` requires `CAP_SYS_ADMIN` and fails with `OCI permission denied`.
- **`:Z` on volumes**: Required for SELinux relabeling on bind mounts and named volumes.
- **`:ro,Z` on config files**: Config files mounted from `.service.d/` should be read-only.
- **`:latest` tags**: Don't use for upstream images. Pin explicit versions.

## Example: Adding a simple single-container service

```
quadlets/example/
├── example.container
├── example.pod
├── example.service.d/
│   └── env
└── example-data.volume
```
