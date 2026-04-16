#!/bin/sh
# Install and configure poudriere, create a jail and ports tree.
#
# Required environment variables:
#   FREEBSD_VERSION  - e.g. 15.0
#   JAIL_NAME        - e.g. riscv64-150
#   POUDRIERE_ARCH   - e.g. riscv.riscv64

set -eux

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Install poudriere. git is required for the default ports tree fetch method
# (git shallow clone).
pkg install -y poudriere git

# Install the configuration
cp "$REPO_ROOT/config/poudriere.conf" /usr/local/etc/poudriere.conf

# Create distfiles cache directory
mkdir -p /usr/local/poudriere/distfiles

# Create the jail for the target architecture.
# -m http fetches the pre-built binary release from download.FreeBSD.org.
# -X disables native-xtools (cross-compilation toolchain). Since poudriere
# PR #455 (merged 2021), native-xtools is built by default for cross-arch
# jails. We don't need it -- we're using QEMU user-mode emulation -- and
# building it fails on riscv64/15.0 (see poudriere issue #1268).
poudriere jail -c \
    -j "$JAIL_NAME" \
    -v "${FREEBSD_VERSION}-RELEASE" \
    -a "$POUDRIERE_ARCH" \
    -m http \
    -X

# Fetch the ports tree (uses git shallow clone by default)
poudriere ports -c
