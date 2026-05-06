# Home Services

This is a collection of podman quadlets that I use for selfhosting several services. Each service is defined in the `quadlets/` directory with its associated containers, volumes, and configuration, which are then managed as systemd user services.

## Project Structure

```
.
├── justfile                  # Main justfile (imports all others)
├── justfiles/                # Modular justfile commands
│   ├── backup.just           # Backup and restore operations
│   ├── containers.just       # Container image building
│   ├── podman.just           # Podman management commands
│   └── systemd.just          # Systemd linking and updates
├── quadlets/                 # Service definitions
│   ├── argus/                # Example: Argus service
│   │   ├── argus.pod
│   │   ├── argus.container
│   │   ├── argus-data.volume
│   │   └── argus.env
│   │   └── argus-config.yml
│   └── ...                   # Other services
├── builds/                   # Custom Containerfiles
│   ├── caddy/
│   └── transmission/
└── timers/                   # Systemd timers (e.g., backups)
    ├── backup.service
    └── backup.timer
```

## Prerequisites

- **Podman** - Container runtime
- **systemd** - Service management
- **just** - Command runner ([installation](https://github.com/casey/just))
- **fish** - Shell (used in justfile commands)
- **sops** - For encrypted secrets
- **restic** - For automated backups
- **yq** - YAML processor, for handling the secrets

## Getting Started

### 1. Initial Setup

Create systemd symlinks for quadlets and timers:

```bash
just symlink-quadlets
just symlink-timers
```

This creates symlinks in `~/.config/containers/systemd/` and `~/.config/systemd/user/` respectively.

### 2. Create Secrets

If your services require secrets (stored in `.secrets/secrets.yaml`):

```bash
just create-secrets
```

This decrypts the SOPS-encrypted secrets file and creates Podman secrets.

### 3. Create images

Run the just recipe to create all the necessary custom images for the containers:

```bash
just build-all
```

This will create a few custom containers:
- caddy with cloudflare (used for let's encrypt certificates), l4 (layer 4 to redirect ssh through port 443)
- transmission with the flood Web UI
- lumo tamer. Note that it will clone the lumo tamer repository into a temporary folder, in order to build the necessary images.

### 4. Container registry alias

Custom container images are stored in the **Forgejo container registry** and referenced in quadlet files using the short alias `home-services/` (e.g., `Image=home-services/caddy-cloudflare-l4:2.11.2-alpine`).

The alias mapping is generated at deploy time by `just install-quadlets` from the `registry-path` secret in `.secrets/secrets.yaml`. It writes a Podman `registries.conf.d` drop-in that maps `home-services/` to the full registry namespace. No domain appears in any file in the repository — only in the encrypted secrets file.

To push images to the registry:
```bash
just registry-login            # log in to the Forgejo container registry
just build-and-push-all        # build and push all images
```

### podman socket

Some services use the podman socket (originally docker, but this works just as well). For the user, this can be enabled with:

#### uptime kuma

uptime-kuma is one of the services that use a socket. This is configured to point to `/run/podman/podman.sock`. Podman containers can now be added as a monitoring

For direct database connections, they can can be added through the pod (not the individual service). e.g. `postgres://authentik:******@authentik.pod:5432/authentik`

```bash
sudo systemctl enable --now
```

### lumo tamer

Lumo tamer is a project that builds an openai API on top of proton's lumo. Mainly used by karakeep to create tags for the added links.

For login, an easy enough flow for the initial authentication is to change the container (`lumo-tamer.container`) to just run sleep.

```
[Container]
ContainerName=lumo-tamer
...
Exec=sleep 10m

[Service]
...
```

For the browser authentication, open a port to the outside inside the pod (`llm.pod`) (here it is open as port 8888). This only has to be done once, and the port can be disabled afterwards.

```
[Pod]
PodName=llm.pod
# port for the browser, temporarly used for logging in to lumo
PublishPort=8888:3001
...
```

Open the browser, on port `8888`: https://home-services:8888/ and login to proton inside the browser.

Afterwards, run from a shell:
```bash
podman exec -it lumo-tamer /bin/sh
```

and inside the container
```bash
npm run auth
```

You can then remove the `Exec` part of the container.

### llama.cpp and localai models

llama.cpp and localai share the same models directory. localai can download the models and these can also be used by llama.cpp. It may require that files be moved from `llama-cpp/models/` to the root directory, and the companion `.yaml` file edited to change the path.

### termix

I have tailscale installed on the host server, so these network options work for me. You may need to adjust the podman network options to suite your needs.

### 3. Reload systemd

After creating symlinks, reload the systemd daemon:

```bash
systemctl --user daemon-reload
```

### 4. Start Services

Start all pod services:

```bash
just start-all
```

Or start individual services:

```bash
systemctl --user start argus-pod.service
```

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
just list-pod-containers argus.pod

# List volumes used by a container
just list-container-volumes argus
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
# Create symlinks for quadlets
just symlink-quadlets

# Create symlinks for timers
just symlink-timers

# Remove broken symlinks
just clean-symlinks
```

### Backup & Restore

#### initialize

The backup repositories can be initialized with something like (adjust for your own needs):

```bash
restic init --password-command 'just get-restic-password' --repo /mnt/nas/backup/podman-volumes/
restic init --password-command 'just get-restic-password' --repo /mnt/nas/backup/audiobooks/
restic init --password-command 'just get-restic-password' --repo /mnt/nas/backup/books/
```

These all use the same password, but the `just get-restic-password` could be adjusted to have a different password per backup repository.

```bash
# Run full backup (volumes + restic backup)
just backup

# Backup only podman volumes
just backup-volumes

# Backup to remote location with restic
just backup-with-restic
```

**Backup Process:**
1. Stops each service
2. Exports volumes to tar archives in `~/podman_volume_backup/`
3. Restarts the service
4. Uses restic to backup to remote location (NAS)
5. Applies retention policy (7 daily, 4 weekly, 6 monthly)

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

A containerized development environment accessible via SSH and a web-based OpenCode interface. The container runs Fedora 44 with fish, just, git, jq, yq, sops, forgejo-cli, tmux, vim, htop, and opencode.

### Setup

**1. Add secrets** to `.secrets/secrets.yaml`:

```yaml
secrets:
  # ... existing secrets ...

  # OpenCode web authentication
  dev-opencode-server-password: "<password>"

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
| OpenCode Web | `https://opencode.<domain>` |
| Forgejo CLI | `fj --host forgejo.<domain> auth add-key` (one-time, token persists in volume) |

On first SSH login, clone your repos into `/home/dev/projects/`. The home directory is backed by a persistent volume, so code and sessions survive container rebuilds.

### What's persisted

- `/home/dev/.ssh/` — authorized_keys, private key for Forgejo
- `/home/dev/projects/` — git repositories
- `/home/dev/.config/` — forgejo-cli auth, sops keys, opencode sessions
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
- **Backups:** Configure paths in `justfiles/backup.just`
- **Custom Images:** Containerfiles in `builds/`

## Automated Backups

A systemd timer runs automated backups:

```bash
# Check timer status
systemctl --user status backup.timer

# View timer schedule
systemctl --user list-timers backup.timer
```
