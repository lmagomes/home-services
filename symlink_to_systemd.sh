#!/bin/bash

# check if the systemd directory exists, if not create it
systemd_dir="$HOME/.config/containers/systemd"
if [ ! -d "$systemd_dir" ]; then
    mkdir -p "$systemd_dir"
fi

# go thorugh each quadlet directory
for dir in ./quadlets/*/; do
    # go through each item in the quadlet directory
    for item in "$dir"*; do
        full_path="$(readlink -f "$dir")/$(basename "$item")"
        systemd_path="$systemd_dir/$(basename "$item")"

        # check if a symlink already exists
        if [ -L $systemd_path ]; then
            echo "symlink for '$full_path' already exists. Skipping..."
        else
            ln -s $full_path $systemd_path
            echo "created a symlink for '$full_path' at '$systemd_path'"
        fi
    done
done