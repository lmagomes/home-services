# justfile for managing systemd symlinks for quadlets and timers

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

# copy all quadlet files to systemd directory, replacing symlinks with real copies
copy-quadlets:
    #!/usr/bin/env fish
    set repo_quadlets (readlink -f ./quadlets)
    mkdir -p {{ systemd-container-dir }}

    # 1. remove symlinks that point into the repo (they will be replaced by real copies)
    find {{ systemd-container-dir }} -type l | while read -l symlink
        set target (readlink -f $symlink)
        if string match -q "$repo_quadlets/*" $target
            echo "🗑️  Replacing symlink: $(basename $symlink)"
            rm $symlink
        end
    end

    # 2. copy all quadlet files/dirs into systemd dir
    for dir in ./quadlets/*/
        for item in "$dir"*
            if string match -q '*.disabled' $item
                continue
            end
            set basename (basename $item)
            set dest "{{ systemd-container-dir }}/$basename"
            if test -d $item
                cp -r $item $dest
                echo "✅ Copied directory: $basename"
            else
                cp $item $dest
                echo "✅ Copied file: $basename"
            end
        end
    end

    # 3. remove stale files in systemd dir not present in any quadlet dir
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

    echo "✅ Quadlets copied to {{ systemd-container-dir }}"

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
