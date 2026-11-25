# Home Services

This is a collection of podman quadlets that I use for selfhosting several services. Each service is defined in the `quadlets/` directory with its associated containers, volumes, and configuration, which are then managed as systemd user services.

## Project Structure

```
.
├── justfile                  # Main justfile (imports all others)
├── justfiles/                # Modular justfile commands
│   ├── containers.just       # Container image building
│   ├── podman.just           # Podman and secret management
│   ├── systemd.just          # Quadlet/timer installation and updates
│   └── validate.just         # Static validation
├── quadlets/                 # Service definitions
│   ├── transmission/         # Example: Transmission service
│   │   ├── transmission.pod
│   │   ├── transmission.container
│   │   ├── transmission-data.volume
│   │   └── transmission.env
│   └── ...                   # Other services
├── builds/                   # Custom Containerfiles
│   ├── caddy/
│   └── transmission/
├── scripts/                  # Operational helper scripts
├── docs/                     # Documentation
├── timers/                   # Systemd timers (e.g., backups)
│   ├── backup.service
│   └── backup.timer
└── .forgejo/workflows/       # CI workflows
```

## Prerequisites

- **Podman** - Container runtime
- **systemd** - Service management
- **just** - Command runner ([installation](https://github.com/casey/just))
- **fish** - Shell (used in justfile commands)
- **sops** - For encrypted secrets
- **restic** - For manual repository initialization and inspection (automated backups run in a container)
- **yq** - YAML processor, used for secrets and workflow validation

## Getting Started

### 1. Initial Setup

Install quadlet and timer files to systemd:

```bash
just install-quadlets
just install-timers
```

This copies files into `~/.config/containers/systemd/` and `~/.config/systemd/user/` respectively.

### 2. Create Secrets

Secrets live encrypted in `.secrets/secrets.yaml`. Sync them into Podman:

```bash
just sync-secrets
```

This decrypts the SOPS file with the age key and creates or updates Podman secrets. Secrets previously managed by this repo that are no longer in the file are removed; secrets owned by other projects are left alone.

### 3. Create Images

Build the custom images used by the quadlets:

```bash
just build-all
```

This builds Caddy with the Cloudflare and layer-4 plugins (for Let's Encrypt certificates and SSH over port 443), Transmission with the Flood web UI, lumo-tamer, json-path-finder, backup-restic, the Forgejo runner job image, and the development environment. Images are built from `builds/<image>/Containerfile`; upstream versions are tracked in `.upstream-version` and `build-version` files.

### 4. Container registry alias

Custom container images are stored in the **Forgejo container registry** and referenced in quadlet files using the short alias `home-services/` (e.g., `Image=home-services/caddy-cloudflare-l4:2.11.4-alpine`).

The alias mapping is generated at deploy time by `just install-quadlets` from the `registry-path` secret in `.secrets/secrets.yaml`. It writes a Podman `registries.conf.d` drop-in that maps `home-services/` to the full registry namespace. No domain appears in any file in the repository — only in the encrypted secrets file.

To push images to the registry:
```bash
just registry-login            # log in to the Forgejo container registry
just build-and-push-all        # build and push all images
```

Old image versions accumulate over time, since each build pushes a new version tag plus `:latest`. To prune them, keeping `latest` and the two most recent version tags per image:

```bash
just prune-registry-images      # keep latest + 2 versions (default)
just prune-registry-images 3    # keep latest + 3 versions
```

Only packages under this repo's registry namespace are considered. Deleting a version marks its blobs as unreferenced; Forgejo reclaims them through its `cron.cleanup_packages` job (runs at midnight, removes unreferenced data older than 24h). This recipe uses the Forgejo API with the `forgejo-registry-user` and `forgejo-registry-token` secrets, so the token needs package write/delete scope. The `prune-registry.yml` workflow also runs this weekly and can be triggered manually.

### 5. Reload systemd

Reload the systemd daemon (the install recipes above do this automatically):

```bash
systemctl --user daemon-reload
```

### 6. Start Services

Start all pod services:

```bash
just start-all
```

Or start individual services:

```bash
systemctl --user start transmission-pod.service
```

## Service Notes

### podman socket

Some services use the Podman socket (originally Docker, but this works just as well). For the current user, enable it with:

```bash
systemctl --user enable --now podman.socket
```

#### uptime kuma

uptime-kuma uses the socket and is configured to point to `/run/podman/podman.sock`. Podman containers can then be added as monitoring targets.

For direct database connections, add them through the pod (not the individual service), e.g. `postgres://authentik:******@authentik.pod:5432/authentik`.

### lumo tamer

Lumo tamer is a project that builds an OpenAI API on top of Proton's Lumo. It is mainly used by karakeep to create tags for added links.

For login, an easy flow for the initial authentication is to change the container (`lumo-tamer.container`) to just run sleep:

```
[Container]
ContainerName=lumo-tamer
...
Exec=sleep 10m

[Service]
...
```

For the browser authentication, open a port to the outside inside the pod (`llm.pod`) (here it is opened as port 8888). This only has to be done once, and the port can be disabled afterwards.

```
[Pod]
PodName=llm.pod
# port for the browser, temporarily used for logging in to lumo
PublishPort=8888:3001
...
```

Open the browser on port `8888`: https://home-services:8888/ and log in to Proton inside the browser.

Afterwards, run from a shell:
```bash
podman exec -it lumo-tamer /bin/sh
```

and inside the container:
```bash
npm run auth
```

You can then remove the `Exec` part of the container.

### llama.cpp and localai models

llama.cpp and localai share the same models directory. localai can download the models, and these can also be used by llama.cpp. It may require that files be moved from `llama-cpp/models/` to the root directory, and the companion `.yaml` file edited to change the path.

### termix

I have Tailscale installed on the host server, so these network options work for me. You may need to adjust the Podman network options to suit your needs.

## Common Commands

### Service Management

```bash
# Show status of all pod services
just show-status

# List all defined pods
just list-pods

# List all pod services
just list-pod-services

# Start all services
just start-all

# Restart all services
just restart-all

# Stop all services
just stop-all

# List containers in a specific pod
just list-pod-containers transmission.pod

# List volumes used by a container
just list-container-volumes transmission
```

### Container Image Management

```bash
# Build all custom images
just build-all

# Build specific images
just build-transmission
just build-caddy
just build-lumo-tamer
just build-dev
```

### Systemd Management

```bash
# Install quadlet files to systemd directory
just install-quadlets

# Install timer files to systemd directory
just install-timers
```

### Validation

```bash
# Run the static checks used by the pull request workflow
just validate
```

### Backup & Restore

Backups run from the `backup` pod. The `backup.timer` starts `backup.service` daily at 02:00, which starts `backup-restic.service` and then `backup-rclone.service`.

- `backup-restic` stops each pod, exports its volumes to `~/podman_volume_backup/`, runs `restic backup` against the configured repositories, and applies a 7 daily / 4 weekly / 6 monthly retention policy.
- `backup-rclone` syncs the books, audiobooks, and Podman volume backups to the configured rclone remote. The remote is configured in the `backup-rclone-config` volume.

Run a backup manually:

```bash
systemctl --user start backup.service
```

Check the timer:

```bash
systemctl --user status backup.timer
systemctl --user list-timers backup.timer
```

#### Initialize repositories

The restic repositories can be initialized with the same password used by the `restic-password` Podman secret:

```bash
export RESTIC_PASSWORD="$(podman secret inspect --showsecret restic-password | jq -r '.[0].SecretData')"
restic init --repo /mnt/nas/backup/podman-volumes/
restic init --repo /mnt/nas/backup/audiobooks/
restic init --repo /mnt/nas/backup/books/
unset RESTIC_PASSWORD
```

Backup paths and repositories are defined in `quadlets/backup/backup-restic.container` and `builds/backup-restic/entrypoint.sh`; adjust them to match your own layout.

### Version Management

Update container versions and create a pull request:

```bash
# Update a single container in a quadlet
just update-quadlet-pr <quadlet> <container> <version>

# Update multiple containers
just update-quadlet-pr immich immich-server v1.122.0 immich-machine-learning v1.122.0

# Merge a PR
just merge-quadlet-pr <pr_number>
```

This workflow:
1. Creates a new branch
2. Updates the container version in the quadlet file
3. Commits and pushes changes
4. Creates a PR using `fj` (Forgejo CLI)
5. Returns to main branch

## Development Environment

A containerized development environment accessible via SSH, a web-based pi coding agent interface (pi-web), and a browser IDE. The container runs Fedora 44 with fish, just, git, jq, yq, sops, forgejo-cli (`fj`), tmux, vim, htop, pi-web, and OpenVSCode Server.

The image clones pi-web from our Forgejo git host at build time. `just build-and-push` resolves the URL with `just forgejo-repo-url pi-web` (git host and owner derived from the `registry-path` secret, or from an optional `git-base-url` secret) and passes it to `podman build` as the `pi-web-repo` build secret, so no domain appears in any tracked file.

### Setup

**1. Add secrets** to `.secrets/secrets.yaml`:

```yaml
secrets:
  # ... existing secrets ...

  # pi-web authentication
  dev-pi-web-password: "<password>"

  # SSH public key for logging into the container (single line)
  dev-ssh-pubkey: ssh-ed25519 AAAA... user@host

  # SSH private key for the container to push to Forgejo (base64-encoded)
  dev-ssh-private-key: "<base64>"

  # SOPS age key for secret management inside the container
  dev-sops-age-key: AGE-SECRET-KEY-1...
```

Encode the private key:
```bash
# Generate a keypair for the container → Forgejo
ssh-keygen -t ed25519 -f dev-forgejo -C "dev-container"

# Add dev-forgejo.pub to your Forgejo account (Settings → SSH/GPG Keys)

# Encode the private key
base64 -w0 dev-forgejo
# Use the output as the dev-ssh-private-key secret value
```

**2. Sync secrets:**
```bash
just sync-secrets
```

**3. Build the image:**
```bash
just build-dev
```

### Usage

| Access | Address |
|---|---|
| SSH | `ssh -p 2224 root@<host>` |
| pi Web | `https://pi.<domain>` |
| IDE | `https://code.<domain>` |
| Forgejo CLI | `fj --host forgejo.<domain> auth add-key` (one-time, token persists in volume) |

On first SSH login, clone your repos into `/home/dev/projects/`. The home directory is backed by a persistent volume, so code and sessions survive container rebuilds.

### What's persisted

- `/home/dev/.ssh/` — authorized_keys, private key for Forgejo
- `/home/dev/projects/` — git repositories
- `/home/dev/.config/` — forgejo-cli auth, sops keys, pi sessions
- `/home/dev/.ssh-host/` — SSH host keys (avoids fingerprint warnings on rebuilds)

## Services

The project manages various self-hosted services. Each service is defined in its own directory under `quadlets/` with:
- `.pod` - Pod definition
- `.container` - Container definitions
- `.volume` - Volume definitions
- `<container-name>.env` - Environment variables file.
- `<container-name>-<file>` - Extra configuration files (e.g., config.yml, Caddyfile).

The quadlet files are converted to systemd units automatically by Podman, creating services like `caddy-pod.service`.

## Configuration

- **Quadlets:** Define containers, pods, and volumes in `quadlets/`
- **Secrets:** Encrypted with SOPS in `.secrets/secrets.yaml`
- **Backups:** Configure repositories and sources in `quadlets/backup/backup-restic.container` and `builds/backup-restic/entrypoint.sh`
- **Custom Images:** Containerfiles in `builds/`
