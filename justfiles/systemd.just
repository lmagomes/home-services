# justfile for managing systemd units for quadlets and timers

systemd-container-dir := "$HOME/.config/containers/systemd"
systemd-user-dir := "$HOME/.config/systemd/user"

# copy quadlet files to systemd directory, decrypting encrypted configs first
install-quadlets:
    #!/usr/bin/env fish
    set repo_quadlets (readlink -f ./quadlets)

    # 0. generate registries.conf from secrets
    just generate-registries-conf

    # 1. decrypt any encrypted config files
    just decrypt-quadlet-configs

    # 2. remove old symlinks (if any, from previous symlink approach)
    find {{ systemd-container-dir }} -type l | while read -l symlink
        set target (readlink -f $symlink)
        if string match -q "$repo_quadlets/*" $target
            echo "🗑️  Removing old symlink: $(basename $symlink)"
            rm $symlink
        end
    end

    # 3. copy all quadlet files/dirs into systemd dir (skip encrypted source files)
    for dir in ./quadlets/*/
        for item in "$dir"*
            set basename (basename $item)
            # Skip encrypted source files — only decrypted copies are installed
            if string match -q '*.encrypted.*' $basename
                continue
            end
            set dest "{{ systemd-container-dir }}/$basename"
            if test -d $item
                cp -r $item $dest
            else
                cp $item $dest
            end
        end
    end

    # 4. remove stale files in systemd dir not present in any quadlet dir
    for item in {{ systemd-container-dir }}/*
        set basename (basename $item)
        set found 0
        for dir in ./quadlets/*/
            if test -e "$dir$basename"
                set found 1
                break
            end
        end
        if test $found -eq 0
            echo "🗑️  Removing stale file: $basename"
            rm -rf $item
        end
    end

    # 5. reload systemd
    echo "🔄 Reloading systemd user daemon..."
    systemctl --user daemon-reload

    echo "✅ All quadlets installed to {{ systemd-container-dir }}"


# generate the podman registries alias config from SOPS secrets
generate-registries-conf:
    #!/usr/bin/env fish
    set registry_path (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-path')
    if test -z "$registry_path" -o "$registry_path" = "null"
        echo "❌ registry-path not set in .secrets/secrets.yaml"
        exit 1
    end

    if test (id -u) -eq 0
        set dest_dir "/etc/containers/registries.conf.d"
    else
        set dest_dir "$HOME/.config/containers/registries.conf.d"
    end
    mkdir -p $dest_dir

    set dest_file "$dest_dir/50-home-services-registries.conf"
    printf 'short-name-mode = "permissive"\n\n[aliases]\n"home-services" = "%s"\n' "$registry_path" > $dest_file

    echo "✅ Generated $dest_file"

# copy timer files to systemd directory, removing old symlinks and stale files
install-timers:
    #!/usr/bin/env fish
    set repo_timers (readlink -f ./timers)

    # 1. remove old symlinks (if any, from previous symlink approach)
    find {{ systemd-user-dir }} -type l | while read -l symlink
        set target (readlink -f $symlink)
        if string match -q "$repo_timers/*" $target
            echo "🗑️  Removing old symlink: $(basename $symlink)"
            rm $symlink
        end
    end

    # 2. copy all timer files into systemd dir
    for item in ./timers/*
        set basename (basename $item)
        set dest "{{ systemd-user-dir }}/$basename"
        cp $item $dest
    end

    # 3. remove stale files in systemd dir not present in timers/
    for item in {{ systemd-user-dir }}/*
        set basename (basename $item)
        if not test -e "./timers/$basename"
            echo "🗑️  Removing stale file: $basename"
            rm -f $item
        end
    end

    # 4. reload systemd
    echo "🔄 Reloading systemd user daemon..."
    systemctl --user daemon-reload

    # 5. enable and start all timer units
    for timer_file in ./timers/*.timer
        set timer_name (basename $timer_file)
        echo "🔛 Enabling and starting $timer_name"
        systemctl --user enable --now $timer_name
    end

    echo "✅ All timers installed to {{ systemd-user-dir }}"

# update quadlet container versions and create a PR
update-quadlet-pr quadlet *pairs:
    #!/usr/bin/env fish
    set -l all_pairs {{ pairs }}

    # Check inputs
    if test (count $all_pairs) -eq 0
        echo "Usage: just update-quadlet-pr <quadlet> <container1> <version1> [<container2> <version2> ...]"
        exit 1
    end

    if test (math (count $all_pairs) % 2) -ne 0
        echo "Error: pairs must be container version pairs."
        exit 1
    end

    # Check for uncommitted changes, since otherwise we might accidentally commit unrelated changes
    if not git diff --cached --quiet
        echo "Error: working tree has uncommitted changes. Commit them first."
        exit 1
    end

    # Create branch name based on updated containers
    set updated_containers
    for i in (seq 1 2 (count $all_pairs))
        set container $all_pairs[$i]
        set updated_containers $updated_containers $container
    end

    set date (date +%Y%m%d)
    set branch "updates/{{ quadlet }}-$date-"(string join "-" $updated_containers)
    git checkout -b $branch

    # do the updates
    set updates
    for i in (seq 1 2 (count $all_pairs))
        set container $all_pairs[$i]
        set updated_version $all_pairs[(math $i + 1)]
        echo ">> $updated_version"
        set container_file "quadlets/{{ quadlet }}/$container.container"

        if not test -f $container_file
            echo "Error: $container_file not found."
            exit 1
        end

        sed -i "s|^\(Image=.*:\).*|\1$updated_version|" $container_file
        set updates $updates "$container=$updated_version"
        git add $container_file
    end

    # commit and push changes to git, and then create a PR
    set title "Update {{ quadlet }}: "(string join ", " $updates)
    git commit -m "$title"
    git push -u origin $branch

    fj pr create --autofill

    git checkout main

    echo "✅ Created PR for $branch"

merge-quadlet-pr pr_number:
    #!/usr/bin/env fish
    fj pr merge {{ pr_number }}

    # pull the merged changes from the remote repository
    git pull

    echo "✅ Merged PR #$pr_number into main"

# restart podman services so they pull new images on start
# pass optional quadlet directories to restart only specific pods (default: auto-detect from git or restart all)
update-podman-images *dirs:
    #!/usr/bin/env fish
    set root_dirs

    set -l explicit_dirs {{ dirs }}
    if test (count $explicit_dirs) -gt 0
        for dir in $explicit_dirs
            set -a root_dirs $dir
        end
        echo "🔄 Restarting explicitly specified pod(s)"
    else
        set changed_files (git diff --name-only HEAD~1 -- 'quadlets/*.container' 2>/dev/null)
        if test (count $changed_files) -gt 0
            echo "🔄 Detected changed container files from git diff"
            for file in $changed_files
                set -a root_dirs (dirname $file)
            end
        else
            for container_file in (find quadlets/ -name "*.container")
                set -a root_dirs (dirname $container_file)
            end
        end
    end

    if test (count $root_dirs) -eq 0
        echo "No container files found."
        exit 0
    end

    set root_dirs (printf '%s\n' $root_dirs | sort -u)

    # Pre-pull images so quadlet doesn't create temp storage in /var/tmp on restart
    for dir in $root_dirs
        for container_file in (find $dir -name "*.container")
            set image (grep '^Image=' $container_file | head -1 | string split -f 2 '=')
            if test -n "$image"
                echo "📥 Pre-pulling $image"
                podman pull $image 2>&1 | tail -1
            end
        end
    end

    systemctl --user daemon-reload

    for dir in $root_dirs
        for pod_file in (find $dir -name "*.pod")
            set service_name (basename $pod_file .pod)-pod.service
            echo "🔄 Restarting $service_name"
            systemctl --user restart $service_name
        end
    end

    echo "✅ Updated services restarted."

# record a removed quadlet service in the removed-quadlets.md journal (run after committing the removal)
record-removed-quadlet service *notes:
    #!/usr/bin/env fish
    set repo_root (git rev-parse --show-toplevel 2>/dev/null)
    if test -z "$repo_root"
        echo "❌ Not in a git repository."
        exit 1
    end

    set service_dir "$repo_root/quadlets/{{ service }}"

    if test -d $service_dir
        echo "❗ Warning: $service_dir still exists on disk. Did you forget to delete the files?"
        set last_commit (git -C $repo_root rev-parse --short HEAD)
    else if git -C $repo_root ls-tree -r HEAD --name-only quadlets/ | grep -q "^quadlets/{{ service }}/"
        echo "Files deleted but not yet committed — using HEAD as last commit."
        set last_commit (git -C $repo_root rev-parse --short HEAD)
    else
        set last_commit (git -C $repo_root rev-parse --short HEAD~1 2>/dev/null)
        if test -z "$last_commit"
            echo "HEAD has no parent — using HEAD itself (deletion commit still shows files in tree)."
            set last_commit (git -C $repo_root rev-parse --short HEAD)
        end

        if not git -C $repo_root ls-tree -r "$last_commit" --name-only quadlets/ | grep -q "^quadlets/{{ service }}/"
            echo "❗ Service {{ service }} not found in commit $last_commit either. Nothing to record."
            exit 1
        end
    end

    set date (date +%Y-%m-%d)
    set notes_str ""
    set raw_notes "{{ notes }}"
    if test "$raw_notes" != ""
        set notes_str "$raw_notes"
    end

    echo "| {{ service }} | $date | $last_commit | $notes_str |" >> removed-quadlets.md

    # sort table by date (oldest first)
    set sep_line (grep -n '^|---' removed-quadlets.md | head -1 | string split -f1 ':')
    if test -z "$sep_line"
        echo "❌ Could not find separator line in removed-quadlets.md. Table may be malformed."
        exit 1
    end
    set data_start (math $sep_line + 1)
    head -n $sep_line removed-quadlets.md > /tmp/removed-quadlets-tmp.md
    tail -n +$data_start removed-quadlets.md | sort -t'|' -k3,3 >> /tmp/removed-quadlets-tmp.md
    mv /tmp/removed-quadlets-tmp.md removed-quadlets.md

    echo "✅ Recorded removal of {{ service }} (last commit: $last_commit) in removed-quadlets.md"

# backfill the removed-quadlets.md journal from git history for past service removals
backfill-removed-quadlets:
    #!/usr/bin/env fish
    if not test -f removed-quadlets.md
        echo "❌ removed-quadlets.md not found. Create it first."
        exit 1
    end

    set found 0
    set commits (git log --diff-filter=D --format="%H" -- 'quadlets/*.pod')
    for commit in $commits
        set deleted_pods (git diff-tree --no-commit-id --diff-filter=D --name-only -r $commit -- 'quadlets/*.pod')
        for pod_file in $deleted_pods
            set service (basename -s .pod $pod_file)

            # skip if already in journal
            if grep -qF "| $service |" removed-quadlets.md
                echo "⏭️  $service already in journal, skipping."
                continue
            end

            # check if a .pod for this service still exists in the current tree (full-removal check)
            if test -f "quadlets/$service/$service.pod"
                echo "⏭️  $service.pod still exists in quadlets/$service/, skipping (not a full-service removal)."
                continue
            end

            # get parent commit
            set parent (git rev-parse --short $commit~1 2>/dev/null)
            if test -z "$parent"
                echo "❗ $commit is a root commit (no parent), skipping $service."
                continue
            end

            set date (git log -1 --format="%as" $commit)
            echo "| $service | $date | $parent | |" >> removed-quadlets.md
            echo "✅ Recorded $service (removed $date, last commit: $parent)"
            set found (math $found + 1)
        end
    end

    if test $found -eq 0
        echo "No past removals to backfill."
    else
        # sort table by date (oldest first)
        set sep_line (grep -n '^|---' removed-quadlets.md | head -1 | string split -f1 ':')
        set data_start (math $sep_line + 1)
        head -n $sep_line removed-quadlets.md > /tmp/removed-quadlets-tmp.md
        tail -n +$data_start removed-quadlets.md | sort -t'|' -k3,3 >> /tmp/removed-quadlets-tmp.md
        mv /tmp/removed-quadlets-tmp.md removed-quadlets.md

        echo ""
        echo "🔄 Backfill complete. Review removed-quadlets.md and commit manually."
    end
