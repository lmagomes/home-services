# Justfile for managing the Forgejo Runner (host binary and container)

forgejo-runner-binary := "/usr/local/bin/forgejo-runner"

# update the host forgejo runner binary to the latest release
# (if using the containerized runner, use just update-podman-images instead)
update-forgejo-runner:
    #!/usr/bin/env fish
    set arch (uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

    # check if containerized runner is active instead
    if systemctl --user is-active forgejo-runner-pod.service 2>/dev/null >/dev/null
        echo "❗ Containerized runner is active. Use 'just update-podman-images' to update it instead."
        exit 1
    end

    echo "🔄 Fetching latest Forgejo Runner release..."
    set latest (curl -sS https://data.forgejo.org/api/v1/repos/forgejo/runner/releases/latest | jq -r .tag_name)
    set runner_ver (string sub -s 2 $latest)

    echo "🔄 Latest release: $latest"

    set current_version ({{ forgejo-runner-binary }} -v 2>/dev/null | string match -r 'v\d+\.\d+\.\d+')
    if test "$current_version" = "$latest"
        echo "⏭️  Already running latest version ($latest). Skipping..."
        exit 0
    end

    set url "https://code.forgejo.org/forgejo/runner/releases/download/$latest/forgejo-runner-$runner_ver-linux-$arch"
    set tmp_dir (mktemp -d)

    echo "📥 Downloading forgejo-runner $runner_ver ($arch)..."
    if not wget -q -O $tmp_dir/forgejo-runner "$url"
        echo "❌ Failed to download binary from $url"
        rm -rf $tmp_dir
        exit 1
    end

    echo "🔏 Verifying GPG signature..."
    wget -q -O $tmp_dir/forgejo-runner.asc "$url.asc"

    gpg --keyserver hkps://keys.openpgp.org --recv EB114F5E6C0DC2BCDD183550A4B61A2DC5923710 2>/dev/null
    if gpg --verify $tmp_dir/forgejo-runner.asc $tmp_dir/forgejo-runner 2>&1 >/dev/null
        echo "✅ Signature verified"
    else
        echo "❗ Signature verification failed — aborting"
        rm -rf $tmp_dir
        exit 1
    end

    chmod +x $tmp_dir/forgejo-runner

    echo "⏸️  Stopping forgejo-runner service..."
    systemctl --user stop forgejo-runner.service

    echo "📋 Installing binary to /usr/local/bin/ (sudo required)..."
    sudo cp $tmp_dir/forgejo-runner {{ forgejo-runner-binary }}

    echo "▶️  Starting forgejo-runner service..."
    systemctl --user start forgejo-runner.service

    rm -rf $tmp_dir

    echo "✅ Forgejo Runner updated to $runner_ver (was $current_version)"

# register the containerized runner with the Forgejo instance
# requires forgejo-runner-token to be set in .secrets/secrets.yaml
forgejo-runner-register:
    #!/usr/bin/env fish
    set token (sops decrypt .secrets/secrets.yaml | yq '.secrets.forgejo-runner-token')
    set instance_url (sops decrypt .secrets/secrets.yaml | yq '.secrets.forgejo-url')

    if test -z "$token"
        echo "❌ forgejo-runner-token is empty."
        echo "   Get a registration token from Forgejo Admin → Actions → Runners → Create new runner"
        echo "   Then add it: sops .secrets/secrets.yaml"
        exit 1
    end

    if test -z "$instance_url"
        echo "❌ forgejo-url is empty in secrets."
        exit 1
    end

    echo "🔄 Registering runner with $instance_url..."
    podman run --rm \
        -v forgejo-runner-data.volume:/data:Z \
        -v (pwd)/quadlets/forgejo-runner/forgejo-runner.service.d/config.yml:/data/config.yml:ro,Z \
        data.forgejo.org/forgejo/runner:12 \
        /bin/forgejo-runner register \
            --config /data/config.yml \
            --instance $instance_url \
            --token $token \
            --name mila \
            --labels "host:docker://localhost/forgejo-runner-job:latest" \
            --no-interactive

    echo "✅ Runner registered. The .runner file is stored in forgejo-runner-data.volume"
    echo "   Start the service: systemctl --user start forgejo-runner-pod.service"

# show forgejo runner status (both host binary and containerized service)
forgejo-runner-status:
    #!/usr/bin/env fish
    echo "🔍 Forgejo Runner status:"
    echo ""
    echo "   Host binary: {{ forgejo-runner-binary }}"
    if test -x {{ forgejo-runner-binary }}
        {{ forgejo-runner-binary }} -v
    else
        echo "   (not installed)"
    end
    echo ""
    echo "   Containerized runner:"
    set container_status (systemctl --user is-active forgejo-runner-pod.service 2>/dev/null; or echo "inactive")
    echo "   Service state: $container_status"
    if test "$container_status" = active
        podman exec forgejo-runner /bin/forgejo-runner -v 2>/dev/null || echo "   (could not get version)"
    end
