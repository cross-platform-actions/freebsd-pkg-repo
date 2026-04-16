#!/bin/sh
# Copy built packages from poudriere output to the workspace
# so they get synced back to the GitHub Actions runner.
#
# Required environment variables:
#   JAIL_NAME - e.g. riscv64-150

set -eux

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PORTS_TREE="default"
PKG_DIR="/usr/local/poudriere/data/packages/${JAIL_NAME}-${PORTS_TREE}"
OUTPUT_DIR="$REPO_ROOT/packages"

# Rebuild a clean output dir. Poudriere's package directory contains lots
# of internal state:
#   .real_<timestamp>/   each atomic-commit snapshot
#   .latest              symlink to the most recent .real_*
#   .building/           in-progress build
#   .jailversion, .buildname
#   logs                 symlink into the jail (broken after teardown)
# The top-level All/, Latest/, meta.conf, meta, data.pkg, packagesite.pkg
# are symlinks into .latest/ pointing at the current public view.
#
# We only want the public subset, and we dereference the symlinks so the
# workspace tree is self-contained after the rsync sync-back to the runner.
# This avoids:
#   - broken-symlink tar errors on logs
#   - N duplicate copies of every package across .real_*/.latest/.building
#   - upload-artifact failures on the colon-containing ABI path
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

for item in All Latest meta.conf meta data.pkg packagesite.pkg; do
    if [ -e "$PKG_DIR/$item" ]; then
        cp -RL "$PKG_DIR/$item" "$OUTPUT_DIR/"
    fi
done

echo "=== Built packages ==="
ls -lR "$OUTPUT_DIR/"
