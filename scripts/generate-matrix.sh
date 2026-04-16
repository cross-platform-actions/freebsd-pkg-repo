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

        poudriere_arch=$(echo "$arch_line" | awk '{print $1}')
        binmiscctl_name=$(echo "$arch_line" | awk '{print $2}')
        qemu_binary=$(echo "$arch_line" | awk '{print $3}')
        elf_magic=$(echo "$arch_line" | awk '{print $4}')
        elf_mask=$(echo "$arch_line" | awk '{print $5}')

        # Derive a short jail name from arch and version
        # e.g. riscv64 + 15.0 -> riscv64-150
        short_arch=$(echo "$poudriere_arch" | sed 's/.*\.//')
        jail_version=$(echo "$version" | tr -d '.')
        jail_name="${short_arch}-${jail_version}"

        # Derive the FreeBSD major version for the ABI path
        major_version=$(echo "$version" | cut -d. -f1)

        if [ "$first" = true ]; then
            first=false
        else
            printf ','
        fi

        printf '{"poudriere_arch":"%s","binmiscctl_name":"%s","qemu_binary":"%s","elf_magic":"%s","elf_mask":"%s","freebsd_version":"%s","jail_name":"%s","major_version":"%s"}' \
            "$poudriere_arch" "$binmiscctl_name" "$qemu_binary" "$elf_magic" "$elf_mask" "$version" "$jail_name" "$major_version"

    done < "$ARCH_FILE"
done < "$VERSIONS_FILE"

printf ']'
