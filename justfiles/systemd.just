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
            set full_path "$(readlink -f "$dir")/$(basename "$item")"
            set systemd_path "{{ systemd-container-dir }}/$(basename "$item")"

            # check if a symlink already exists
            if [ -L $systemd_path ]
                echo "🔗 symlink for '$full_path' already exists. Skipping..."
            else
                ln -s $full_path $systemd_path
                echo "✅ created a symlink for '$full_path' at '$systemd_path'"
            end
        end
    end

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
        else
            ln -s $full_path $systemd_path
            echo "✅ created a symlink for '$full_path' at '$systemd_path'"
        end
    end

# update container version in quadlet and restart service
update-version service container version:
    #!/usr/bin/env fish

    # update the file
    set container_file "quadlets/{{ service }}/{{ container }}.container"
    sed -i "s|^\(Image=.*:\).*|\1{{ version }}|" $container_file

    # pull the new image and restart the service
    set image_path (sed -n 's/^Image=//p' $container_file)
    podman image pull $image_path
    systemctl --user daemon-reload
    systemctl --user restart {{ service }}-pod.service

    # commit and push changes to git
    git add $container_file
    git commit -m "Update {{ container }} to version {{ version }} in {{ service }}"
    git push

    echo "✅ Updated {{ container }} in {{ service }} to version {{ version }} (Image: $image_path)"

# update quadlet container versions and create a PR
update-quadlet-pr quadlet *pairs:
    #!/usr/bin/env fish

    if test (count $pairs) -eq 0
        echo "Usage: just update-quadlet-pr <quadlet> <container1> <version1> [<container2> <version2> ...]"
        exit 1
    end

    if test (math (count $pairs) % 2) -ne 0
        echo "Error: pairs must be container version pairs."
        exit 1
    end

    if test -n (git status --porcelain)
        echo "Error: working tree has uncommitted changes. Commit or stash first."
        exit 1
    end

    set date (date +%Y%m%d)
    set branch "updates/{{ quadlet }}-$date"
    git checkout -b $branch

    set updates
    set touched
    for i in (seq 1 2 (count $pairs))
        set container $pairs[$i]
        set version $pairs[(math $i + 1)]
        set container_file "quadlets/{{ quadlet }}/$container.container"

        if not test -f $container_file
            echo "Error: $container_file not found."
            exit 1
        end

        sed -i "s|^\(Image=.*:\).*|\1$version|" $container_file
        set updates $updates "$container=$version"
        set touched $touched $container_file
    end

    git add $touched
    set title "Update {{ quadlet }}: "(string join ", " $updates)
    git commit -m "$title"
    git push -u origin $branch

    fj pr create --base main --head $branch --title "$title" --description "Updates: "(string join ", " $updates)

    echo "✅ Created PR for $branch"
