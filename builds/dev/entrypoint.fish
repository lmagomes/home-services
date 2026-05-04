#!/usr/bin/env fish

function cleanup
    echo "Shutting down..."
    kill %1 %2 2>/dev/null
    exit 0
end

trap cleanup SIGTERM SIGINT

sed -i '/^root:/s|:/root:|:/home/dev:|' /etc/passwd
set -gx HOME /home/dev

mkdir -p /home/dev/.ssh
chmod 700 /home/dev/.ssh

if test -n "$DEV_SSH_PUBKEY"
    set pubkey_file /home/dev/.ssh/authorized_keys
    grep -qF "$DEV_SSH_PUBKEY" $pubkey_file 2>/dev/null || echo "$DEV_SSH_PUBKEY" >>$pubkey_file
    chmod 600 $pubkey_file
end

if test -n "$DEV_SSH_PRIVATE_KEY"
    echo "$DEV_SSH_PRIVATE_KEY" | base64 -d >/home/dev/.ssh/id_ed25519
    chmod 600 /home/dev/.ssh/id_ed25519
end

mkdir -p /home/dev/.config/sops/age
if test -f /run/secrets/sops-age-key
    cp /run/secrets/sops-age-key /home/dev/.config/sops/age/keys.txt
    chmod 600 /home/dev/.config/sops/age/keys.txt
end

set port $OPENCODE_SERVER_PORT
if test -z "$port"
    set port 3000
end

mkdir -p /home/dev/.ssh-host
if not test -f /home/dev/.ssh-host/ssh_host_ed25519_key
    ssh-keygen -t ed25519 -f /home/dev/.ssh-host/ssh_host_ed25519_key -N "" -q
end
if not test -f /home/dev/.ssh-host/ssh_host_rsa_key
    ssh-keygen -t rsa -f /home/dev/.ssh-host/ssh_host_rsa_key -N "" -q
end

/usr/sbin/sshd -D &

opencode web --hostname 0.0.0.0 --port $port &

wait
