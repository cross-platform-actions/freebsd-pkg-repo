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

# Step 4: Build the packages, in cumulative chunks.
#
# poudriere publishes packages only at the atomic commit that ends a bulk
# run. A run killed mid-bulk cleans up and commits nothing, so every package
# it built is lost -- which is how a 5h25m run that reported "Built: 48"
# still handed an empty packages/ to the deploy. To keep progress inside the
# GitHub Actions job limit, walk the pkglist in cumulative chunks (the first
# port, then the first two, and so on), running a separate bulk for each.
# Every chunk that finishes commits, so a kill costs only the chunk in
# flight rather than the whole run.
#
# The chunks are cumulative rather than disjoint because a bulk run only
# guarantees the packages in its own build set; a disjoint chunk risks
# dropping what an earlier chunk committed. Re-listing ports that are
# already built is cheap -- poudriere validates the existing packages and
# skips them.
#
# Each chunk is wrapped in timeout(1) so we stop *before* the GitHub Actions
# step timeout (340 min), leaving ~15 min for collect + rsync-back + VM
# shutdown. Without this, a step timeout kills the VM mid-bulk and collect
# never runs at all.
#
# Each chunk gets everything left in the budget rather than an equal share:
# chunks run in order, so letting the current one use all remaining time
# maximises how many reach their commit. Splitting the budget evenly would
# risk killing every chunk just short of committing, losing everything.
#
# -k 60: escalate to SIGKILL if poudriere doesn't honor SIGTERM within 60s.
# `|| echo` prevents `set -e` from aborting on a timeout or a port failure,
# so we always fall through to the next chunk and to collect-packages.sh.
BUILD_BUDGET_SECONDS="${BUILD_BUDGET_SECONDS:-19500}"
# Don't start a chunk that cannot plausibly reach a commit.
MIN_CHUNK_SECONDS="${MIN_CHUNK_SECONDS:-600}"

deadline=$(( $(date +%s) + BUILD_BUDGET_SECONDS ))

ORIGINS="$(mktemp)"
CHUNK="$(mktemp)"
trap 'rm -f "$ORIGINS" "$CHUNK"' EXIT

# Strip trailing comments, whole-line comments and blank lines.
sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' \
    "$REPO_ROOT/config/pkglist" > "$ORIGINS"
total="$(wc -l < "$ORIGINS" | tr -d ' ')"

chunk=0
while IFS= read -r origin || [ -n "$origin" ]; do
    chunk=$(( chunk + 1 ))
    echo "$origin" >> "$CHUNK"

    remaining=$(( deadline - $(date +%s) ))
    if [ "$remaining" -lt "$MIN_CHUNK_SECONDS" ]; then
        echo "Time budget exhausted (${remaining}s left);" \
             "skipping chunks $chunk-$total"
        break
    fi

    echo "=== Chunk $chunk/$total: through $origin (${remaining}s left) ==="
    sudo timeout -k 60 "$remaining" \
        poudriere bulk -j "$JAIL_NAME" -p default -f "$CHUNK" \
        || echo "chunk $chunk did not complete normally (exit $?)"
done < "$ORIGINS"

# Step 5: Copy built packages to workspace for sync back to runner.
#
# The exit status is deliberately not swallowed. collect-packages.sh fails
# when poudriere committed nothing, and that failure has to fail this step:
# a failed build skips the artifact upload, which skips the deploy job, so
# the published repository is left untouched. Swallowing it would let an
# empty packages/ deploy as a success and wipe the live repository.
sudo -E sh "$SCRIPT_DIR/collect-packages.sh"
