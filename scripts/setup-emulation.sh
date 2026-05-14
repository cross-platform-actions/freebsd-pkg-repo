#!/bin/sh
# Set up QEMU user-mode emulation for a target architecture.
#
# Required environment variables:
#   BINMISCCTL_NAME - name for the binmiscctl entry (e.g. riscv64)
#   QEMU_BINARY     - qemu-user-static binary name (e.g. qemu-riscv64-static)
#   ELF_MAGIC       - ELF magic bytes in hex (no \x prefix, e.g. 7f454c46...)
#   ELF_MASK        - ELF mask bytes in hex (no \x prefix, e.g. ffffffffffff...)
#
# Optional:
#   QEMU_ARGS       - extra arguments appended to the interpreter
#                     (e.g. "-cpu power9"). The kernel splits the
#                     --interpreter string on spaces at exec time.

set -eux

# Load the kernel module for binary format miscellaneous
kldload imgact_binmisc || true

# Install QEMU user-mode static binaries
pkg install -y qemu-user-static

# Convert hex strings to \x-escaped form for binmiscctl
hex_to_escaped() {
    echo "$1" | sed 's/\(..\)/\\x\1/g'
}

magic=$(hex_to_escaped "$ELF_MAGIC")
mask=$(hex_to_escaped "$ELF_MASK")
size=$((${#ELF_MAGIC} / 2))

# Register the binary format. QEMU_ARGS (if set) is appended to the
# interpreter path; the kernel splits the resulting string on spaces.
binmiscctl add "$BINMISCCTL_NAME" \
    --interpreter "/usr/local/bin/$QEMU_BINARY${QEMU_ARGS:+ $QEMU_ARGS}" \
    --magic "$magic" \
    --mask "$mask" \
    --size "$size" \
    --set-enabled

# Verify
binmiscctl list
