---
name: remove-quadlet
description: Step-by-step checklist for removing Podman quadlet services — covers full pod folder removal, single container removal from a pod, and journaling removals in removed-quadlets.md
---

## Overview

When a self-hosted service is no longer needed, follow this checklist to cleanly remove it from the repository. The process covers:
1. **Full service removal** — deleting the entire `quadlets/<service>/` directory
2. **Single container removal** — removing one container from within a multi-container pod
3. **Journal recording** — documenting the removal in `removed-quadlets.md` so it can be restored later

**Important:** This development environment runs inside a container and cannot control systemd services or podman resources. The user is responsible for all host-side actions (stopping services, disabling units, cleaning containers/volumes, restarting dependent services, running `just install-quadlets`).

The journal is at the repo root (`removed-quadlets.md`). Record removals with `just record-removed-quadlet <service> [notes]` after committing the deletion. This saves the last commit SHA where the service files existed, enabling restoration via `git show <commit>:quadlets/<service>/`.

## Agent Behavior

When changes have host-side implications (stopping services, restarting Caddy, cleaning podman resources, running `just install-quadlets`), **ask the user** if they want a list of what needs to be done on the host. Do not automatically list systemctl or podman commands unless the user requests it.

**Exception — secrets:** Always tell the user which secrets they can remove from `.secrets/secrets.yaml` without being asked. **Never edit `.secrets/secrets.yaml` yourself.**

## Full Service Removal

Use this when removing an entire pod and all its containers.

### 1. Delete quadlet files

Delete the entire service directory:

```bash
rm -rf quadlets/<service>/
```

### 2. Remove Caddy reverse proxy entry

Remove the host block for this service from `quadlets/caddy/caddy-Caddyfile`.

### 3. Remove from Release Argus config

Remove the service's webhook/monitor entry from `quadlets/monitor/monitor-argus-config.yml`.

### 4. Remove from Service-Hub config

Remove the service's entry from `quadlets/monitor/monitor-service-hub-config.yml`.

### 5. Remove custom container builds

If the service uses locally-built images from `builds/<image>/`, remove the build directory. If it was referenced in `justfiles/containers.just` (e.g., a `build-<image>` recipe or a switch case in `build-and-push-changed`), clean up those references.

### 6. Handle secrets

Tell the user which secrets they can remove from `.secrets/secrets.yaml`. **Never edit `.secrets/secrets.yaml` yourself** — list the secret names for the user to handle manually.

### 7. Commit and record the removal

```bash
git add -A
git commit -m "Remove <service>"
```

Then journal it:

```bash
just record-removed-quadlet <service> "notes about why it was removed"
```

The recipe appends a row to `removed-quadlets.md` with the service name, date, last commit SHA, and notes. It sorts the table by date (oldest first). Commit the updated journal:

```bash
git add removed-quadlets.md
git commit -m "Record removal of <service> in removed-quadlets.md"
```

### 8. Ask about host-side cleanup

After committing, ask the user if they want a list of host-side actions needed (stopping/disabling services, running `just install-quadlets`, restarting dependent services like Caddy, cleaning podman pods and volumes).

## Single Container Removal

Use this when removing one container from a multi-container pod while keeping the rest of the service.

### 1. Identify the container

Determine which `.container` file in `quadlets/<service>/` to remove (e.g., `quadlets/paperless/paperless-gpt.container`).

### 2. Check for dependencies

Search for `Requires=` and `After=` references to this container in other `.container` files:

```bash
grep -r "Requires=.*<container-name>" quadlets/
grep -r "After=.*<container-name>" quadlets/
```

Remove or update any dependency references found.

### 3. Delete container files

Remove the `.container` file and its companion files:
- The `.env` file (`<container-name>.env` or `<container-name>.service.d/env` depending on repo convention)
- Any config files specific to this container (e.g., `<container-name>-config.yml`)
- Any `.volume` files used only by this container

```bash
rm quadlets/<service>/<container-name>.container
rm quadlets/<service>/<container-name>.service.d/env
rm quadlets/<service>/<container-name>.service.d/config.yml    # if it exists
```

### 4. Handle secrets

If the removed container referenced any secrets that are no longer used by the remaining service, tell the user which secrets can be removed from `.secrets/secrets.yaml`. **Never edit `.secrets/secrets.yaml` yourself.**

### 5. Update monitor configs

If the removed container had its own entry in `monitor-argus-config.yml` or `monitor-service-hub-config.yml`, remove it.

### 6. Commit

```bash
git add -A
git commit -m "Remove <container-name> from <service>"
```

### 7. Record the removal

After committing, run:

```bash
just record-removed-quadlet <container-name> "removed from <service>"
```

Then commit the updated journal:

```bash
git add removed-quadlets.md
git commit -m "Record removal of <container-name> in removed-quadlets.md"
```

**Note:** Single container removals are also recorded in `removed-quadlets.md`.

### 8. Ask about host-side cleanup

After committing, ask the user if they want a list of host-side actions needed (stopping/disabling the removed container, running `just install-quadlets`).

## Restoring a Removed Service

To restore a service that was previously removed and journaled, the user should:

```bash
# Find the last commit where the service existed
grep "<service>" removed-quadlets.md

# Restore the files from that commit
git show <last-commit>:quadlets/<service>/ > quadlets/<service>/

# Deploy and start
just install-quadlets
systemctl --user start <service>.pod
```

## Common Pitfalls

- **Forgetting dependent services**: If Caddy or other services reference the removed service, they may fail. Check `Caddyfile` and `Requires=`/`After=` directives.
- **Secrets cleanup**: Tell the user which secrets to remove. The agent must never modify `.secrets/secrets.yaml` directly.
- **Data volumes**: Named volumes are not automatically removed. The user must manually run `podman volume rm` to free disk space.
- **Record before pushing**: Run `just record-removed-quadlet` after committing the removal but before pushing, so the `removed-quadlets.md` update is included in the same PR.
