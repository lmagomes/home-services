# justfile for static validation of repository files

# run static checks that do not need systemd or podman
validate:
    #!/usr/bin/env fish
    set -l failed 0

    # fish syntax for all justfile recipes
    for f in justfiles/*.just
        if not fish -n $f
            echo "❌ fish syntax error: $f"
            set failed 1
        end
    end

    # justfile imports and recipes parse
    if not just --list >/dev/null
        echo "❌ justfile failed to parse"
        set failed 1
    end

    # JSON files parse
    if command -q jq
        for f in renovate.json
            if not jq empty $f
                echo "❌ invalid JSON: $f"
                set failed 1
            end
        end
    else
        echo "⏭️  jq not found, skipping JSON validation"
    end

    # workflow YAML parses
    if command -q yq
        for f in .forgejo/workflows/*.yml
            if test -f $f
                if not yq '.' $f >/dev/null
                    echo "❌ invalid YAML: $f"
                    set failed 1
                end
            end
        end
    else
        echo "⏭️  yq not found, skipping workflow YAML validation"
    end

    # shell scripts lint
    if command -q shellcheck
        for f in builds/*/*.sh
            if test -f $f
                if not shellcheck $f
                    echo "❌ shellcheck failed: $f"
                    set failed 1
                end
            end
        end
    else
        echo "⏭️  shellcheck not found, skipping shell lint"
    end

    # systemd timer and service syntax
    if command -q systemd-analyze
        if not systemd-analyze verify timers/*.service timers/*.timer
            echo "❌ systemd unit verification failed"
            set failed 1
        end
    else
        echo "⏭️  systemd-analyze not found, skipping unit verification"
    end

    if test $failed -ne 0
        echo "❌ Validation failed"
        exit 1
    end

    echo "✅ Validation passed"
