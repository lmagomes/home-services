# Justfile for building container images for various services.

# build all images described by builds/*/build.conf without pushing
build-all:
    #!/usr/bin/env fish
    for conf in builds/*/build.conf
        just build-from-conf $conf false
    end

# create a container image for transmission
build-transmission:
    #!/usr/bin/env fish
    just build-from-conf builds/transmission/build.conf false

# create a container image for caddy with cloudflare and l4 plugins
build-caddy:
    #!/usr/bin/env fish
    just build-from-conf builds/caddy/build.conf false

# create a container image for lumo-tamer
build-lumo-tamer:
    #!/usr/bin/env fish
    just build-from-conf builds/lumo-tamer/build.conf false

# create a container image for backup-restic
build-backup-restic:
    #!/usr/bin/env fish
    just build-from-conf builds/backup-restic/build.conf false

# create a container image for the dev environment
build-dev:
    #!/usr/bin/env fish
    just build-from-conf builds/dev/build.conf false

# create a container image for json-path-finder
build-json-path-finder:
    #!/usr/bin/env fish
    just build-from-conf builds/json-path-finder/build.conf false

# create a container image for the forgejo runner job execution environment
build-forgejo-runner-job:
    #!/usr/bin/env fish
    just build-from-conf builds/forgejo-runner-job/build.conf false

# build or build+push an image described by a build.conf file
build-from-conf conf push="true":
    #!/usr/bin/env fish
    set -l conf "{{ conf }}"
    if not test -f $conf
        echo "❌ Build config not found: $conf"
        exit 1
    end
    set -l image (sed -n 's/^image=//p' $conf | head -1)
    set -l strategy (sed -n 's/^version-strategy=//p' $conf | head -1)
    if test -z "$image" -o -z "$strategy"
        echo "❌ $conf must define image= and version-strategy="
        exit 1
    end
    just build-and-push $image (dirname $conf) $strategy "{{ push }}"

# fetch the latest release version from a GitHub repository
github-latest-version repo:
    curl -s https://api.github.com/repos/{{ repo }}/releases/latest | jq -r '.tag_name'

# print the clone URL for one of our forgejo repos. The git host and owner are
# derived from the registry-path secret so no domain appears in tracked files;
# set git-base-url (e.g. https://example.com/owner) to override the derivation.
forgejo-repo-url repo:
    #!/usr/bin/env fish
    set -l secrets (sops decrypt .secrets/secrets.yaml)

    set -l override (printf '%s\n' $secrets | yq '.secrets.git-base-url // ""' | string trim)
    if test -n "$override"
        echo "$override/{{ repo }}"
        exit 0
    end

    set -l parts (string split '/' (printf '%s\n' $secrets | yq '.secrets.registry-path'))
    if test (count $parts) -lt 2 -o -z "$parts[1]" -o -z "$parts[2]" -o "$parts[1]" = "null"
        echo "❌ Could not derive the git URL from registry-path; set git-base-url in .secrets/secrets.yaml"
        exit 1
    end

    echo "https://$parts[1]/$parts[2]/{{ repo }}"

# build and push a container image to the forgejo container registry.
# version-strategy: "first" (first FROM line), "last" (last FROM line), "github:owner/repo", "rpm:package-name", "upstream-file:<path>", or literal version string.
# pass push=false to build and tag locally without pushing or decrypting registry secrets.
build-and-push image dir version-strategy push="true":
    #!/usr/bin/env fish
    set -l image_version
    set -l skip_build false
    set -l build_secrets
    set -l secret_file

    # Build-time values that must not live in tracked files (e.g. the pi-web clone
    # URL) are resolved here and handed to podman as build secrets, which stay out
    # of the image history. Only images whose Containerfile mounts the secret pay
    # for the sops decrypt.
    if grep -q 'type=secret,id=pi-web-repo' "{{ dir }}/Containerfile" 2>/dev/null
        set -l repo_url (just forgejo-repo-url pi-web)
        if test $status -ne 0 -o -z "$repo_url"
            echo "❌ Could not resolve the pi-web repo URL (try 'just forgejo-repo-url pi-web')"
            exit 1
        end
        set secret_file (mktemp)
        printf '%s' "$repo_url" > $secret_file
        set build_secrets --secret id=pi-web-repo,src=$secret_file
    end

    if test "{{ version-strategy }}" = "first"
        set image_version (sed -n 's/^FROM .*:\([^ ]*\).*/\1/p' {{ dir }}/Containerfile | head -1)
    else if test "{{ version-strategy }}" = "last"
        set image_version (sed -n 's/^FROM .*:\([^ ]*\).*/\1/p' {{ dir }}/Containerfile | tail -1)
    else if string match -q 'github:*' "{{ version-strategy }}"
        set repo (string replace 'github:' '' "{{ version-strategy }}")
        set image_version (just github-latest-version $repo)
    else if string match -q 'rpm:*' "{{ version-strategy }}"
        set package (string replace 'rpm:' '' "{{ version-strategy }}")
        echo "🔄 Building {{ image }} with temp tag for RPM version extraction..."
        podman build $build_secrets -t localhost/{{ image }}:temp {{ dir }}
        set image_version (podman run --rm localhost/{{ image }}:temp rpm -q --qf '%{VERSION}-%{RELEASE}' $package)
        podman tag localhost/{{ image }}:temp localhost/{{ image }}:$image_version
        podman tag localhost/{{ image }}:temp localhost/{{ image }}:latest
        podman rmi localhost/{{ image }}:temp 2>/dev/null
        set skip_build true
    else if string match -q 'upstream-file:*' "{{ version-strategy }}"
        set file (string replace 'upstream-file:' '' "{{ version-strategy }}")
        set image_version (cat "{{ dir }}/$file" | string trim)
    else
        set image_version "{{ version-strategy }}"
    end

    if test -f {{ dir }}/build-version
        set build_version (cat {{ dir }}/build-version | string trim)
        set image_version "$image_version-r$build_version"
    end

    if not $skip_build
        echo "🔄 Building {{ image }}:$image_version..."
        podman build $build_secrets --build-arg CACHEBUST=(date +%s) -t localhost/{{ image }}:$image_version {{ dir }}
        podman tag localhost/{{ image }}:$image_version localhost/{{ image }}:latest
    end

    if test -n "$secret_file"
        rm -f $secret_file
    end

    if test "{{ push }}" = "false"
        echo "✅ Built localhost/{{ image }}:$image_version"
        exit 0
    end

    set registry_path (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-path')
    set remote_image "$registry_path/{{ image }}:$image_version"

    echo "🔖 Tagging $remote_image..."
    podman tag localhost/{{ image }}:$image_version $remote_image
    podman tag localhost/{{ image }}:$image_version "$registry_path/{{ image }}:latest"

    echo "📤 Pushing $remote_image..."
    podman push $remote_image
    podman push "$registry_path/{{ image }}:latest"

    echo "✅ Pushed $remote_image"

# detect changed build directories since a base ref and build+push them (for CI)
build-and-push-changed base_ref="":
    #!/usr/bin/env fish
    # base_ref defaults to HEAD~1; pass the push event's before SHA from CI
    set -l base "{{ base_ref }}"
    if test -z "$base" -o "$base" = "0000000000000000000000000000000000000000"
        set base (git rev-parse HEAD~1 2>/dev/null)
    end

    # If the base is missing or unusable, rebuild everything rather than skipping work
    set -l base_ok 1
    if test -z "$base"
        set base_ok 0
    else if not git cat-file -e "$base^{commit}" 2>/dev/null
        set base_ok 0
    end
    if test $base_ok -eq 0
        echo "❗ No usable base ref; building all images."
        just build-and-push-all
        exit 0
    end

    set changed_dirs (git diff --name-only "$base" HEAD -- builds/ | cut -d'/' -f2 | sort -u)

    if test (count $changed_dirs) -eq 0
        echo "No build directories changed."
        exit 0
    end

    echo "Changed build directories: $changed_dirs"

    for dir in $changed_dirs
        set -l conf "builds/$dir/build.conf"
        if not test -f $conf
            echo "⏭️  No build.conf for builds/$dir"
            continue
        end
        just build-from-conf $conf
    end

# build and push all images to the forgejo container registry
build-and-push-all:
    #!/usr/bin/env fish
    for conf in builds/*/build.conf
        just build-from-conf $conf
    end


# log in to the forgejo container registry (for CI, uses Actions secrets as env vars)
registry-login-ci:
    #!/usr/bin/env fish
    set registry_domain (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-domain')
    echo "$REGISTRY_TOKEN" | podman login $registry_domain -u "$REGISTRY_USER" --password-stdin
    echo "✅ Logged in to $registry_domain container registry"

# prune old container image versions from the forgejo registry, keeping `latest` and the <keep> most recent versions per image
prune-registry-images keep="2":
    #!/usr/bin/env fish
    set keep {{ keep }}

    set registry_domain (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-domain')
    set registry_path (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-path')
    set user (sops decrypt .secrets/secrets.yaml | yq '.secrets.forgejo-registry-user')
    set token (sops decrypt .secrets/secrets.yaml | yq '.secrets.forgejo-registry-token')

    if test -z "$registry_domain" -o "$registry_domain" = "null" -o -z "$registry_path" -o "$registry_path" = "null" -o -z "$user" -o "$user" = "null" -o -z "$token" -o "$token" = "null"
        echo "❌ registry-domain, registry-path, forgejo-registry-user and forgejo-registry-token must be set in .secrets/secrets.yaml"
        exit 1
    end

    # derive the package owner and the repo's image-name prefix from registry-path
    # e.g. <domain>/<owner>/<namespace> -> owner=<owner>, prefix=<namespace>
    set path_parts (string split '/' $registry_path)
    set owner $path_parts[2]
    set prefix (string join '/' $path_parts[3..-1])

    if test -z "$owner" -o -z "$prefix"
        echo "❗ Could not derive owner/prefix from registry-path"
        exit 1
    end

    set api "https://$registry_domain/api/v1"

    # fetch all container packages for the owner, paginating through the API
    set packages_file (mktemp)
    printf '[]' > $packages_file
    set page 1
    while true
        set page_file (mktemp)
        curl -sf -u "$user:$token" "$api/packages/$owner?type=container&limit=50&page=$page" -o $page_file
        if test $status -ne 0
            echo "❌ Failed to list packages (page $page). Check the registry credentials."
            rm -f $packages_file $page_file
            exit 1
        end
        if test (jq 'length' $page_file) -eq 0
            rm -f $page_file
            break
        end
        set merged_file (mktemp)
        jq -s '.[0] + .[1]' $packages_file $page_file > $merged_file
        mv $merged_file $packages_file
        rm -f $page_file
        set page (math $page + 1)
    end

    # every non-latest version beyond the newest `keep` per image is pruned
    set delete_file (mktemp)
    jq -r --arg prefix "$prefix/" --argjson keep $keep '
        [ .[] | select(.type == "container") | select(.name | startswith($prefix)) ]
        | group_by(.name)
        | .[]
        | (.[0].name) as $name
        | [ .[] | select(.version != "latest") ]
        | sort_by(.created_at) | reverse
        | .[$keep:]
        | .[]
        | "\($name) \(.version)"
    ' $packages_file > $delete_file

    set total (count (cat $delete_file))
    if test $total -eq 0
        echo "✅ Nothing to prune — every image already has $keep or fewer versions (plus latest)."
        rm -f $packages_file $delete_file
        exit 0
    end

    echo "🗑️  Pruning $total old image version(s), keeping latest + the newest $keep per image:"
    set deleted 0
    set failed 0
    for line in (cat $delete_file)
        set parts (string split ' ' $line)
        set pkg_name $parts[1]
        set tag $parts[2]
        set encoded_name (string replace -a '/' '%2F' -- $pkg_name)
        set code (curl -s -o /dev/null -w '%{http_code}' -X DELETE -u "$user:$token" "$api/packages/$owner/container/$encoded_name/$tag")
        if test "$code" = "204"
            echo "  🗑️  $pkg_name:$tag"
            set deleted (math $deleted + 1)
        else
            echo "  ❌ Failed to delete $pkg_name:$tag (HTTP $code)"
            set failed (math $failed + 1)
        end
    end

    rm -f $packages_file $delete_file

    echo "✅ Deleted $deleted version(s)."
    if test $failed -gt 0
        echo "❗ $failed deletion(s) failed."
        exit 1
    end
