#!/bin/sh
# Generate a JSON matrix from config/architectures and config/versions
# for use with GitHub Actions' fromJSON() matrix strategy.
#
# Runs on the Linux runner, so must be plain sh-compatible.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARCH_FILE="$REPO_ROOT/config/architectures"
VERSIONS_FILE="$REPO_ROOT/config/versions"

first=true
printf '['

while IFS= read -r version || [ -n "$version" ]; do
    # Skip empty lines and comments
    case "$version" in ''|\#*) continue ;; esac

    while IFS= read -r arch_line || [ -n "$arch_line" ]; do
        # Skip empty lines and comments
        case "$arch_line" in ''|\#*) continue ;; esac

        target_arch=$(echo "$arch_line" | awk '{print $1}')
        release_machine=$(echo "$arch_line" | awk '{print $2}')

        # A short slug for job names and artifact names,
        # e.g. powerpc64 + 15.0 -> powerpc64-150
        build_name="${target_arch}-$(echo "$version" | tr -d '.')"

        # The FreeBSD major version, for the pkg ABI path
        major_version=$(echo "$version" | cut -d. -f1)

        if [ "$first" = true ]; then
            first=false
        else
            printf ','
        fi

        printf '{"target_arch":"%s","release_machine":"%s","freebsd_version":"%s","build_name":"%s","major_version":"%s"}' \
            "$target_arch" "$release_machine" "$version" "$build_name" "$major_version"

    done < "$ARCH_FILE"
done < "$VERSIONS_FILE"

printf ']'
