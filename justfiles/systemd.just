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