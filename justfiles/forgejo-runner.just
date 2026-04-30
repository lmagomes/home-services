# Justfile for managing the Forgejo Runner binary and service

forgejo-runner-binary := "/usr/local/bin/forgejo-runner"

# update forgejo runner binary to the latest release
update-forgejo-runner:
    #!/usr/bin/env fish
    set arch (uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

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

# show forgejo runner status (version and service state)
forgejo-runner-status:
    echo "🔍 Forgejo Runner status:"
    echo "   Binary: {{ forgejo-runner-binary }}"
    {{ forgejo-runner-binary }} -v
    systemctl --user status forgejo-runner.service --lines=0
