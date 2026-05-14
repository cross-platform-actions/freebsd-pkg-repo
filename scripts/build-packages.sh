#!/bin/sh
# Main build orchestration script. Runs inside the FreeBSD VM.
#
# Required environment variables (passed from GitHub Actions matrix):
#   POUDRIERE_ARCH  - e.g. riscv.riscv64
#   BINMISCCTL_NAME - e.g. riscv64
#   QEMU_BINARY     - e.g. qemu-riscv64-static
#   ELF_MAGIC       - ELF magic bytes in hex
#   ELF_MASK        - ELF mask bytes in hex
#   FREEBSD_VERSION - e.g. 15.0
#   JAIL_NAME       - e.g. riscv64-150
#
# Optional:
#   QEMU_ARGS       - extra arguments to the qemu interpreter (e.g.
#                     "-cpu power9"). May be empty.

set -eux

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Step 1: Set up QEMU user-mode emulation
sudo -E sh "$SCRIPT_DIR/setup-emulation.sh"

# Step 2: Install and configure poudriere, create jail and ports tree
sudo -E sh "$SCRIPT_DIR/setup-poudriere.sh"

# Step 2.5: Dump emulation diagnostics. Non-fatal -- we want to see what's
# happening even if some probes fail.
sudo -E sh "$SCRIPT_DIR/diagnose-emulation.sh" || true

# Step 3: Pre-seed poudriere's package dir from the restored cache, if any.
# poudriere bulk checks existing packages against current port definitions
# and reuses anything still valid -- so progressive runs resume where the
# previous timed-out run left off.
PKG_OUT="/usr/local/poudriere/data/packages/${JAIL_NAME}-default"
if [ -d "$REPO_ROOT/packages" ] && [ -n "$(ls -A "$REPO_ROOT/packages" 2>/dev/null)" ]; then
    echo "Seeding $PKG_OUT from cached packages"
    sudo mkdir -p "$PKG_OUT"
    sudo cp -R "$REPO_ROOT/packages/." "$PKG_OUT/"
fi

# Step 4: Build the packages.
# Wrap in timeout(1) so we stop *before* the GitHub Actions step timeout
# (340 min), leaving ~15 min for collect + rsync-back + VM shutdown.
# Without this, a step timeout kills the VM mid-bulk, collect never runs,
# the workspace packages/ dir stays empty, and the cache save has nothing
# to save -- losing all progress from this run.
# -k 60: escalate to SIGKILL if poudriere doesn't honor SIGTERM within 60s.
# `|| echo` prevents `set -e` from aborting on timeout/build failures so
# we always fall through to collect-packages.sh.
sudo timeout -k 60 325m \
    poudriere bulk -j "$JAIL_NAME" -p default -f "$REPO_ROOT/config/pkglist" \
    || echo "poudriere bulk did not complete normally (exit $?)"

# Step 5: Copy built packages to workspace for sync back to runner.
# Runs unconditionally so partial progress is cached for the next run.
sudo -E sh "$SCRIPT_DIR/collect-packages.sh" \
    || echo "collect-packages.sh failed (exit $?)"
