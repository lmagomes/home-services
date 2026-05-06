# justfile for managing systemd units for quadlets and timers

systemd-container-dir := "$HOME/.config/containers/systemd"
systemd-user-dir := "$HOME/.config/systemd/user"

# remove broken symlinks in systemd directory
clean-symlinks:
    #!/usr/bin/env fish
    find {{ systemd-container-dir }} -type l | while read -l symlink
        set target (readlink $symlink)
        if not test -e $target
            echo "❗ Removing broken symlink: $symlink"
            rm $symlink
        end
    end

# run all pending migration scripts in order (idempotent)
apply-migrations:
    #!/usr/bin/env fish
    set state_file "{{ systemd-container-dir }}/.quadlet-migrations"
    touch $state_file

    if not test -d migrations
        echo "No migrations directory found."
        exit 0
    end

    for script in (ls migrations/*.fish | sort)
        set mig_id (basename $script .fish)
        if grep -qF -- "$mig_id" $state_file
            echo "⏭️  Skipping (already applied): $mig_id"
            continue
        end

        echo ""
        echo "🔄 Running migration: $mig_id"
        echo ""
        if fish $script
            echo ""
            echo "✅ Migration applied: $mig_id"
            echo $mig_id >> $state_file
        else
            echo ""
            echo "❌ Migration FAILED: $mig_id — aborting"
            exit 1
        end
    end

    echo ""
    echo "✅ All migrations applied."

    echo ""
    echo "🔄 Updating quadlet symlinks..."
    just symlink-quadlets

    echo "🔄 Reloading systemd user daemon..."
    systemctl --user daemon-reload

# create symlinks for quadlets in the systemd directory
symlink-quadlets:
    #!/usr/bin/env fish
    if [ ! -d "{{ systemd-container-dir }}" ]
        mkdir -p "{{ systemd-container-dir }}"
    end

    # go thorugh each quadlet directory
    for dir in ./quadlets/*/
        # go through each item in the quadlet directory
        for item in "$dir"*
            # skip disabled files
            if string match -q '*.disabled' $item
                echo "⏭️  skipping disabled file: $item"
                continue
            end

            set full_path "$(readlink -f "$dir")/$(basename "$item")"
            set systemd_path "{{ systemd-container-dir }}/$(basename "$item")"

            # check if a symlink already exists
            if [ -L $systemd_path ]
                echo "🔗 symlink for '$full_path' already exists. Skipping..."
            else if [ -e $systemd_path ]
                echo "❗ real file at '$systemd_path' already exists. Skipping..."
            else
                ln -s $full_path $systemd_path
                echo "✅ created a symlink for '$full_path' at '$systemd_path'"
            end
        end
    end

# remove symlinks that point into this repo's quadlets directory (real files are untouched)
unsymlink-quadlets:
    #!/usr/bin/env fish
    set repo_quadlets (readlink -f ./quadlets)
    find {{ systemd-container-dir }} -type l | while read -l symlink
        set target (readlink -f $symlink)
        if string match -q "$repo_quadlets/*" $target
            echo "🗑️  Removing symlink: $(basename $symlink)"
            rm $symlink
        end
    end
    echo "✅ Repo symlinks removed."

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

    # 3. copy all quadlet files/dirs into systemd dir
    for dir in ./quadlets/*/
        for item in "$dir"*
            set basename (basename $item)
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

    set dest_dir "$HOME/.config/containers/registries.conf.d"
    mkdir -p $dest_dir

    set dest_file "$dest_dir/50-home-services-registries.conf"
    printf '[aliases]\n"home-services" = "%s"\n' "$registry_path" > $dest_file

    echo "✅ Generated $dest_file"

# create symlinks for timers in the systemd directory
symlink-timers:
    #!/usr/bin/env fish
    # go through each item in the timer directory
    set dir "./timers/"
    for item in "$dir"*
        set full_path "$(readlink -f "$dir")/$(basename "$item")"
        set systemd_path "{{ systemd-user-dir }}/$(basename "$item")"

        # check if a symlink already exists
        if [ -L $systemd_path ]
            echo "🔗 symlink for '$full_path' already exists. Skipping..."
        else if [ -e $systemd_path ]
            echo "❗ real file at '$systemd_path' already exists. Skipping..."
        else
            ln -s $full_path $systemd_path
            echo "✅ created a symlink for '$full_path' at '$systemd_path'"
        end
    end

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

# pull new podman images and restart affected services
update-podman-images:
    #!/usr/bin/env fish
    set root_dirs

    for container_file in (find quadlets/ -name "*.container")
        set image_name (grep "Image=" $container_file | cut -d'=' -f2)

        # If this is not :latest (or default latest), keep the original behavior.
        if not string match -qr ':latest$' $image_name; and string match -q '*:*' $image_name
            if podman image exists $image_name
                echo "Image $image_name already exists, skipping pull."
                continue
            else
                echo "Pulling image $image_name."
                podman pull $image_name
                set -a root_dirs (dirname $container_file)
                continue
            end
        end

        echo "Checking image $image_name for updates..."

        # Get current digest if image exists
        set old_digest ""
        if podman image exists $image_name
            set old_digest (podman image inspect $image_name --format '{{ "{{.Digest}}" }}' 2>/dev/null)
        end

        # Pull the image
        podman pull $image_name

        # Get new digest
        set new_digest (podman image inspect $image_name --format '{{ "{{.Digest}}" }}' 2>/dev/null)

        # Check if digest changed (or image was new)
        if test "$old_digest" != "$new_digest"
            echo "✅ Image $image_name was updated."
            set -a root_dirs (dirname $container_file)
        else
            echo "Image $image_name is already up to date."
        end
    end

    # check if root_dirs list is not empty
    if test (count $root_dirs) -ne 0
        # reload systemd user daemon to recognize any new/updated services
        systemctl --user daemon-reload

        # go through each root dir and get the .pod file
        for dir in $root_dirs
            set service_name (find $dir -name "*.pod" -exec basename {} \; | sed 's/\.pod/-pod.service/')

            echo "Restarting service $service_name to create container with new image."
            systemctl --user restart $service_name
        end
    end

# record a removed quadlet service in the removed-quadlets.md journal (run after committing the removal)
record-removed-quadlet service *notes:
    #!/usr/bin/env fish
    set service_dir "quadlets/{{ service }}"

    if test -d $service_dir
        echo "❗ Warning: $service_dir still exists on disk. Did you forget to delete the files?"
        set last_commit (git rev-parse --short HEAD)
    else if git ls-tree -r HEAD --name-only quadlets/ | grep -q "^$service_dir/"
        echo "Files deleted but not yet committed — using HEAD as last commit."
        set last_commit (git rev-parse --short HEAD)
    else
        set last_commit (git rev-parse --short HEAD~1 2>/dev/null)
        if test -z "$last_commit"
            echo "❌ HEAD has no parent (first commit). Cannot determine last commit."
            exit 1
        end

        # safety check: verify the parent commit actually contains the service
        if not git ls-tree -r "$last_commit" --name-only quadlets/ | grep -q "^$service_dir/"
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
    set data_start (math $sep_line + 1)
    head -n $sep_line removed-quadlets.md > /tmp/removed-quadlets-tmp.md
    tail -n +$data_start removed-quadlets.md | sort -t'|' -k2,2 >> /tmp/removed-quadlets-tmp.md
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
        tail -n +$data_start removed-quadlets.md | sort -t'|' -k2,2 >> /tmp/removed-quadlets-tmp.md
        mv /tmp/removed-quadlets-tmp.md removed-quadlets.md

        echo ""
        echo "🔄 Backfill complete. Review removed-quadlets.md and commit manually."
    end
