#!/bin/sh
# Diagnostic dump for QEMU user-mode emulation failures. Runs after the
# poudriere jail base is unpacked but before `poudriere bulk`, so the
# target-arch binaries are available on disk for inspection.
#
# Required environment variables:
#   BINMISCCTL_NAME - e.g. powerpc64
#   QEMU_BINARY     - e.g. qemu-ppc64-static
#   JAIL_NAME       - e.g. powerpc64-150
#
# Optional:
#   QEMU_ARGS       - e.g. "-cpu power9"

# Intentionally no `set -e`: we want every probe to run even if one fails.
: "${QEMU_ARGS:=}"

JAIL_DIR="/usr/local/poudriere/jails/${JAIL_NAME}"
TARGET_BIN="${JAIL_DIR}/usr/bin/id"

echo "==== binmiscctl list ===="
binmiscctl list
echo

echo "==== binmiscctl lookup ${BINMISCCTL_NAME} ===="
binmiscctl lookup "${BINMISCCTL_NAME}"
echo

echo "==== qemu-user-static package contents (ppc/powerpc) ===="
pkg info -l qemu-user-static 2>/dev/null | grep -Ei 'ppc|powerpc'
echo

echo "==== /usr/local/bin/${QEMU_BINARY} ===="
ls -l "/usr/local/bin/${QEMU_BINARY}"
file "/usr/local/bin/${QEMU_BINARY}"
echo

echo "==== file ${TARGET_BIN} ===="
file "${TARGET_BIN}"
echo

echo "==== first 64 bytes of ${TARGET_BIN} ===="
hexdump -C -n 64 "${TARGET_BIN}"
echo

echo "==== direct invocation: qemu ${QEMU_ARGS} ${TARGET_BIN} ===="
# shellcheck disable=SC2086
"/usr/local/bin/${QEMU_BINARY}" ${QEMU_ARGS} "${TARGET_BIN}"
echo "qemu exit: $?"
echo

echo "==== invocation via binmiscctl (chroot to jail base) ===="
chroot "${JAIL_DIR}" /usr/bin/id
echo "chroot+id exit: $?"
