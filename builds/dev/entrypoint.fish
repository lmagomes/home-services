#!/usr/bin/env fish

function cleanup
    echo "Shutting down..."
    pkill -f 'server.js --host 0.0.0.0' 2>/dev/null
    kill %1 %2 %3 2>/dev/null
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

set port $PI_WEB_PORT
if test -z "$port"
    set port 3000
end

set ide_port $OPENVSCODE_SERVER_PORT
if test -z "$ide_port"
    set ide_port 8080
end

mkdir -p /home/dev/.ssh-host
if not test -f /home/dev/.ssh-host/ssh_host_ed25519_key
    ssh-keygen -t ed25519 -f /home/dev/.ssh-host/ssh_host_ed25519_key -N "" -q
end
if not test -f /home/dev/.ssh-host/ssh_host_rsa_key
    ssh-keygen -t rsa -f /home/dev/.ssh-host/ssh_host_rsa_key -N "" -q
end

/usr/sbin/sshd -D &

# pi-web is the browser UI for the pi coding agent.
#
# It runs from the checkout in the persistent volume when one exists, so updating is
# `git pull` + restart (or the Reload button) instead of a new image: rebuilding takes
# minutes, pulling takes seconds. The image copy is the fallback for a fresh volume.
function pi_web_source
    set -l checkout /home/dev/projects/pi-web/server.js
    if test -f $checkout
        # A broken checkout must never lock the UI out; fall back to the image copy.
        if node --check $checkout >/dev/null 2>&1
            echo volume
            return
        end
        echo "⚠️  $checkout does not parse; using the image copy" >&2
    end
    echo image
end

function pi_web_run
    set -l forced_source $argv[1]
    set -l source (pi_web_source)
    if test "$forced_source" = image; and test "$source" = volume
        echo "⚠️  volume checkout keeps failing; using the image copy" >&2
        set source image
    end
    echo "pi-web source: $source"
    if test "$source" = volume
        set -lx PI_WEB_SOURCE volume
        node /home/dev/projects/pi-web/server.js --host 0.0.0.0 --port $port --cwd /home/dev
    else
        set -lx PI_WEB_SOURCE image
        pi-web --host 0.0.0.0 --port $port --cwd /home/dev
    end
end

# Respawn loop: killing pi-web reloads it from disk, which is what POST /api/reload does.
function pi_web_loop
    set -l failures 0
    while true
        set -lx PI_WEB_SUPERVISED 1
        set -l forced_source ""
        if test $failures -ge 3
            set forced_source image
            echo "⚠️  3 consecutive failures; trying the image copy" >&2
        end
        pi_web_run $forced_source
        set -l code $status
        if test "$forced_source" = image; or test $code -eq 0
            set failures 0
        else
            set failures (math $failures + 1)
        end
        echo "pi-web exited ($code); restarting in 2s" >&2
        sleep 2
    end
end

pi_web_loop &

openvscode-server --host 0.0.0.0 --port $ide_port --without-connection-token &

wait
